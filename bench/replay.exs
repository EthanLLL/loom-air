# Written for the two-phase operator (cold clips, then warm TTS), replaced by ringing on 2026-11-27: run it
# from commit 102b734.
# Replays a recorded call against several operator models: the same system prompt (with the memory snapshot the
# call had), the same tools and the same turn inputs, in order. Each model keeps its own history.
#
#   mix run --no-start bench/replay.exs <call.jsonl> <memory snapshot.md> <out dir>
#
# Tools are not real: play_clip / end_call answer as in production, send_to_session / new_session answer
# "accepted" without touching Loom, read_sessions returns the sessions as they were when the call ended (real data,
# fetched once and shared by all models). Then every spoken line is synthesized through infer-gw.

for app <- [:finch, :jason, :aws_signature, :mint_web_socket], do: Application.ensure_all_started(app)
{:ok, _} = Finch.start_link(name: Air.Finch, pools: %{default: [size: 20, conn_max_idle_time: 60_000]})
{:ok, _} = Registry.start_link(keys: :unique, name: Air.Registry)
{:ok, _} = DynamicSupervisor.start_link(name: Air.Sup, strategy: :one_for_one)

[log, memory_file, out] = System.argv()
File.mkdir_p!(Path.join(out, "audio"))

{:ok, t} = Air.Config.tenant(System.get_env("TENANT") || Air.Config.default_tenant())
clips = Air.Config.clips(t["voice"])
memory = File.read!(memory_file) |> String.trim()
phases = Map.new([:cold, :warm], &{&1, {Air.Operator.system(t, memory, &1), Air.Operator.tools(clips, &1)}})
events = log |> File.stream!() |> Enum.map(&Jason.decode!/1)
inputs = for %{"type" => "turn_in", "text" => x} <- events, do: x

# COLD=n: the first n turns as if TTS were still warming up (the recorded call may have been warm throughout).
inputs =
  case System.get_env("COLD") do
    nil -> inputs
    n ->
      {cold, rest} = Enum.split(inputs, String.to_integer(n))
      Enum.map(cold, &String.replace(&1, ~r/tts="[^"]*"/, ~s(tts="warming, up 20s"))) ++ rest
  end

phase_of = fn input -> if input =~ ~s(tts="ready"), do: :warm, else: :cold end
ended = Enum.find_value(events, &(&1["type"] == "call_end" && &1["at"]))

models = [
  %{key: "haiku", name: "Claude Haiku 5.5", id: "us.anthropic.claude-haiku-5-5", extra: %{thinking: %{type: "disabled"}}, cache: true},
  %{key: "sonnet", name: "Claude Sonnet 5.5", id: "us.anthropic.claude-sonnet-5-5", extra: %{thinking: %{type: "between_tools"}}, cache: true},
  %{key: "sol", name: "GPT-6.2 Sol", id: "us.openai.gpt-6.2-sol", extra: %{reasoning: %{effort: "low"}}, cache: false},
  %{key: "luna", name: "GPT-6 Luna", id: "us.openai.gpt-6-luna", extra: %{reasoning: %{effort: "none"}}, cache: false},
  %{key: "grok", name: "Grok 4.7", id: "us.xai.grok-4.7", extra: %{reasoning_effort: "low"}, cache: false}
]

# EXTRA='{"thinking": …}' overrides the request fields of the models picked by ONLY.
models =
  case System.get_env("EXTRA") do
    nil -> models
    x -> Enum.map(models, &%{&1 | extra: Jason.decode!(x)})
  end

models =
  case System.get_env("ONLY") do
    nil -> models
    k -> Enum.filter(models, &(&1.key in String.split(k, ",")))
  end

final = ~w(play_clip end_call send_to_session new_session)

# read_sessions, as of the end of the call; cached so every model sees the same thing.
read_session = fn id, detail ->
  key = {:read, id, detail}

  case Process.get(key) do
    nil ->
      r =
        with {:ok, list} <- Air.LoomSocket.sessions(t),
             s when s != nil <- Enum.find(list, &(&1["id"] == id)) || {:error, "no session #{id}"},
             {:ok, snap} <- Air.LoomSocket.read(t, id, max((s["seq"] || 0) - 400, 0)) do
          evs = Enum.filter(snap["events"], fn e -> (e["at"] || e["ts"] || 0) <= ended end)

          {:ok, Map.merge(%{session_id: id, title: s["title"], status: "idle"}, Air.Operator.view(evs, detail))}
        else
          {:error, e} -> {:error, to_string(e)}
          e -> {:error, inspect(e)}
        end

      Process.put(key, r)
      r

    r ->
      r
  end
end

tool = fn
  "play_clip", %{"kind" => k} ->
    case Enum.filter(clips, &(Air.Operator.kind(&1) == k)) do
      [] -> {:error, "no clip of kind #{k}"}
      some -> c = Enum.random(some); {:ok, "played 「#{c["text"]}」", c["name"]}
    end
  "end_call", _ -> {:ok, "hanging up"}
  "read_sessions", %{"session_ids" => [_ | _] = ids} ->
    views = for id <- ids, do: (case read_session.(id, length(ids) == 1) do {:ok, v} -> v; {:error, e} -> %{session_id: id, error: e} end)
    {:ok, if(length(ids) == 1, do: hd(views), else: views)}
  "send_to_session", %{"session_id" => id} -> {:ok, %{session_id: id, status: "accepted"}}
  "new_session", _ -> {:ok, %{session_id: "a_benchNEW0001", status: "accepted"}}
  name, _ -> {:error, "unknown tool #{name}"}
end

clean = fn
  %{"reasoningContent" => _} -> nil
  %{"text" => x} -> %{text: x}
  %{"toolUse" => u} -> %{toolUse: %{toolUseId: u["toolUseId"], name: u["name"], input: u["input"] || %{}}}
  other -> other
end

append_user = fn messages, block ->
  case List.last(messages) do
    %{role: "user", content: c} -> List.replace_at(messages, -1, %{role: "user", content: c ++ [block]})
    _ -> messages ++ [%{role: "user", content: [block]}]
  end
end

# One turn: rounds until the model stops asking for tools (same rules as Air.Operator.round).
round = fn round, m, {system, tools}, messages, n, acc ->
  cp = if m.cache, do: [%{cachePoint: %{type: "default"}}], else: []

  body = %{
    system: [%{text: system}] ++ cp,
    messages: messages,
    toolConfig: %{tools: tools ++ cp},
    inferenceConfig: %{maxTokens: 600},
    additionalModelRequestFields: m.extra
  }

  t0 = System.monotonic_time(:millisecond)
  r = Air.Bedrock.converse(body, "bench", model: m.id, timeout: 60_000)
  ms = System.monotonic_time(:millisecond) - t0

  case r do
    {:ok, %{"output" => %{"message" => %{"content" => content}}, "stopReason" => stop} = resp} ->
      reasoning = Enum.any?(content, &Map.has_key?(&1, "reasoningContent"))
      content = content |> Enum.map(clean) |> Enum.reject(&is_nil/1)
      messages = messages ++ [%{role: "assistant", content: content}]
      says = for %{text: x} <- content, String.trim(x) != "", do: String.trim(x)

      calls =
        for %{toolUse: u} <- content do
          # play_clip also says which clip it picked, for the report.
          # As in production: a tool not offered in this phase is refused.
          case if(Enum.any?(tools, &(&1.toolSpec.name == u.name)), do: tool.(u.name, u.input), else: {:error, "#{u.name} is not available now"}) do
            {:ok, d, clip} -> {Map.put(u, :clip, clip), {:ok, d}}
            res -> {u, res}
          end
        end

      results =
        for {u, res} <- calls do
          case res do
            {:ok, d} -> %{toolResult: %{toolUseId: u.toolUseId, content: [%{json: %{result: d}}]}}
            {:error, e} -> %{toolResult: %{toolUseId: u.toolUseId, content: [%{text: e}], status: "error"}}
          end
        end

      rec = %{
        n: n, ms: ms, server_ms: get_in(resp, ["metrics", "latencyMs"]), stop: stop, usage: resp["usage"],
        reasoning: reasoning, says: says,
        tools: for({u, res} <- calls, do: %{name: u.name, input: u.input, clip: u[:clip], ok: match?({:ok, _}, res),
          result: case res do
            {:ok, d} when is_binary(d) -> d
            {:ok, d} -> Jason.encode!(d) |> String.slice(0, 300)
            {:error, e} -> "error: " <> e
          end})
      }

      acc = acc ++ [rec]
      names = for {u, _} <- calls, do: u.name
      failed = Enum.any?(calls, &match?({_, {:error, _}}, &1))

      cond do
        results != [] and not failed and Enum.all?(names, &(&1 in final)) ->
          {messages ++ [%{role: "user", content: results}], acc}

        stop == "tool_use" and results != [] and n < 6 ->
          round.(round, m, {system, tools}, messages ++ [%{role: "user", content: results}], n + 1, acc)

        results != [] ->
          {messages ++ [%{role: "user", content: results ++ [%{text: "<note>tool rounds exhausted</note>"}]}], acc}

        true ->
          {messages, acc}
      end

    {:error, e} ->
      {messages, acc ++ [%{n: n, ms: ms, error: to_string(e)}]}
  end
end

# Warm the gateway now, so TTS is ready by the time the replays are done.
Air.Gw.warm()

runs =
  for m <- models do
    IO.puts("== #{m.name}")

    {_, turns} =
      Enum.reduce(inputs, {[], []}, fn input, {messages, turns} ->
        # As in production: warm, the clips played so far become plain text (NOSPOKEN=1 to skip).
        first_warm = phase_of.(input) == :warm and Enum.all?(turns, &(&1.phase == :cold))
        messages = if(first_warm and !System.get_env("NOSPOKEN"), do: Air.Operator.spoken(messages), else: messages)
        messages = append_user.(messages, %{text: input})
        {messages, rounds} = round.(round, m, phases[phase_of.(input)], messages, 1, [])
        for r <- rounds, do: IO.puts("  #{r.ms} ms  #{inspect(r[:says] || r[:error])} #{inspect(for x <- r[:tools] || [], do: x.name)}")
        {messages, turns ++ [%{input: input, phase: phase_of.(input), rounds: rounds}]}
      end)

    %{key: m.key, name: m.name, id: m.id, settings: m.extra, turns: turns}
  end

# ── TTS for every spoken line ──

wait_ready = fn wait, n ->
  case Air.Gw.status() do
    {:ok, %{state: :ready}} -> :ok
    _ when n > 60 -> :timeout
    _ -> Process.sleep(3_000); wait.(wait, n + 1)
  end
end

IO.puts("tts: #{inspect(wait_ready.(wait_ready, 0))}")

tts = fn key, i, text ->
  file = "#{key}-#{i}"
  t0 = System.monotonic_time(:millisecond)
  {:ok, agent} = Agent.start_link(fn -> {[], nil} end)
  sink = fn chunk -> Agent.update(agent, fn {cs, first} -> {[chunk | cs], first || System.monotonic_time(:millisecond) - t0} end) end
  r = Air.Gw.speak(text, t["voice"], t["temperature"] || 0.85, sink)
  total = System.monotonic_time(:millisecond) - t0
  {chunks, first} = Agent.get(agent, & &1)
  pcm = chunks |> Enum.reverse() |> IO.iodata_to_binary()
  raw = Path.join(out, "audio/#{file}.pcm")
  File.write!(raw, pcm)
  {_, 0} = System.cmd("ffmpeg", ~w(-y -loglevel error -f s16le -ar 24000 -ac 1 -i #{raw} -b:a 64k #{Path.join(out, "audio/#{file}.mp3")}))
  File.rm!(raw)
  %{file: "audio/#{file}.mp3", first_ms: first, total_ms: total, audio_s: Float.round(byte_size(pcm) / 48_000, 2), ok: r == :ok}
end

runs =
  for run <- runs do
    {turns, _} =
      Enum.map_reduce(run.turns, 0, fn turn, i ->
        {rounds, i} =
          Enum.map_reduce(turn.rounds, i, fn r, i ->
            {audio, i} = Enum.map_reduce(r[:says] || [], i, fn text, i -> {tts.(run.key, i + 1, text), i + 1} end)
            {Map.put(r, :audio, audio), i}
          end)

        {%{turn | rounds: rounds}, i}
      end)

    IO.puts("tts done: #{run.name}")
    %{run | turns: turns}
  end

original =
  for e <- events, e["type"] in ~w(heard say clip_log tool turn_in), do: Map.drop(e, ["at"])

File.write!(Path.join(out, "results#{if k = System.get_env("ONLY"), do: "-" <> k}.json"), Jason.encode!(%{call: Path.basename(log), memory: File.read!(memory_file), inputs: inputs, original: original, runs: runs}, pretty: true))
IO.puts("written #{out}/results.json")
