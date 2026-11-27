defmodule Air.Call do
  @moduledoc """
  One phone call: the operator's conversation, the events waiting for the next turn, the speech queue and the
  gateway's state. It lives as long as its client socket, and ends on hang-up.

  Everything slow runs in Tasks (a model turn, a TTS stream, a gateway poll) whose results come back here, so
  the call always takes new events. One turn at a time: events that arrive meanwhile go into the next one.
  One speech item at a time, in order; the client plays them on one timeline.

  **Ringing (user, 2026-11-27):** a dialled call rings (the client plays the ringback) while the greeting turn
  runs and TTS warms up. It is answered once the greeting is synthesized whole, so the first words come the
  moment the ringing stops (after `@pick_up_pause_ms`), and not before it has rung `@min_ring_ms`; if that takes longer than the ringback
  lasts, nobody answers (`no_answer`), as on a phone. What the user says while it rings is not heard.
  """
  use GenServer, restart: :temporary
  require Logger

  alias Air.{Config, Gw, Operator}

  # A ring, not a click, even when everything is warm.
  @min_ring_ms 5_000
  # From picking up to the first word: the music stops, a beat, then 「喂」 (user, 2026-11-27).
  @pick_up_pause_ms 800

  def start(tenant, socket), do: DynamicSupervisor.start_child(Air.Sup, {__MODULE__, {tenant, socket}})
  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)
  @doc "What the phone heard; `timing` is the client's measure of the turn (speech, ASR, wait), kept in the record."
  def heard(call, text, timing \\ nil), do: send(call, {:heard, text, timing})
  def hangup(call), do: send(call, :hangup)

  @impl true
  def init({t, socket}) do
    Process.monitor(socket)
    # The memory as it is when the call starts.
    system = Operator.system(t, Air.Memory.read(t["name"]))

    s = %{
      t: t, socket: socket, messages: [], pending: [], turn: nil, speech: :queue.new(), speaking: nil,
      tts: %{state: :off, up_s: 0}, following: MapSet.new(), polls: nil, ending: false, n: 0, told: %{},
      log: log_path(t), ctx: %{t: t, call: self(), system: system, tools: Operator.tools()},
      answered: false, rang_at: System.monotonic_time(:millisecond), greeting: [], greeting_task: nil
    }

    record(s, %{type: "call_start", tenant: t["name"], voice: t["voice"], temperature: t["temperature"],
      model: Config.get(:model)})
    {:ok, s, {:continue, :dial}}
  end

  @impl true
  def handle_continue(:dial, s) do
    ring = Config.ringback_ms()
    out(s, %{type: "ringing", ms: ring})
    Process.send_after(self(), :no_answer, ring)

    case Gw.warm() do
      :ok -> :ok
      {:error, e} -> out(s, %{type: "error", text: "warm: #{e}"})
    end

    s = case Gw.status() do
      {:ok, st} -> %{s | tts: st}
      _ -> s
    end

    record(s, %{type: "tts", state: s.tts.state, up_s: s.tts.up_s})
    state(s)
    Process.send_after(self(), :poll, 3_000)
    {:noreply, s |> event("<call_started/>") |> sessions_list() |> flush() |> pick_up()}
  end

  @impl true
  def handle_info({:heard, _, _}, %{answered: false} = s), do: {:noreply, s}

  def handle_info({:heard, text, timing}, s) do
    out(s, if(timing, do: %{type: "heard", text: text, timing: timing}, else: %{type: "heard", text: text}))
    {:noreply, s |> event("<heard>#{text}</heard>") |> flush()}
  end

  def handle_info(:hangup, s), do: {:stop, :normal, s}

  # ── from the turn ──

  # While it rings, what the greeting turn says is kept for pick_up/1.
  def handle_info({:say, text}, %{answered: false} = s), do: {:noreply, %{s | greeting: s.greeting ++ [text]}}

  def handle_info({:say, text}, s) do
    if s.tts.state == :ready do
      out(s, %{type: "say", text: text, spoken: true})
      {:noreply, speak(s, {:tts, text})}
    else
      out(s, %{type: "say", text: text, spoken: false})
      {:noreply, s}
    end
  end

  def handle_info(:end_call, s), do: {:noreply, speak(%{s | ending: true}, :end)}

  def handle_info({:following, id}, s) do
    s = %{s | following: MapSet.put(s.following, id)}
    state(s)
    {:noreply, s}
  end

  def handle_info({:log, entry}, s), do: (out(s, entry); {:noreply, s})

  # ── from Loom ──

  def handle_info({:loom_reply, id, text}, s) do
    title = with({:ok, list} <- Air.LoomSocket.sessions(s.t), %{"title" => t} <- Enum.find(list, &(&1["id"] == id)), do: t, else: (_ -> ""))
    out(s, %{type: "loom_reply", session: id, title: title, text: text})
    state(s)
    reply = String.slice(text, 0, 4000)
    {:noreply, s |> event(~s(<loom_reply session="#{id}" title="#{title}">#{reply}</loom_reply>)) |> flush()}
  end

  def handle_info({:loom_error, id, msg}, s) do
    out(s, %{type: "error", text: "Loom #{id}: #{msg}"})
    {:noreply, s |> event(~s(<loom_error session="#{id}">#{msg}</loom_error>)) |> flush()}
  end

  # ── ringing ──

  def handle_info({:answer, pcm}, %{answered: false, ending: false} = s) do
    out(s, %{type: "answered"})
    Process.send_after(self(), {:greet, pcm}, @pick_up_pause_ms)
    {:noreply, s}
  end

  def handle_info({:greet, pcm}, %{answered: false, ending: false} = s) do
    for text <- s.greeting, do: out(s, %{type: "say", text: text, spoken: true})

    s =
      if pcm == "" do
        s
      else
        id = s.n + 1
        out(s, %{type: "speech", id: id, rate: Gw.sample_rate()})
        for <<chunk::binary-size(9600) <- pcm>>, do: send(s.socket, {:pcm, chunk})
        tail = rem(byte_size(pcm), 9600)
        if tail > 0, do: send(s.socket, {:pcm, binary_part(pcm, byte_size(pcm) - tail, tail)})
        send(s.socket, {:send, %{type: "speech_end", id: id}})
        %{s | n: id}
      end

    {:noreply, %{s | answered: true, greeting: []} |> next_speech() |> flush()}
  end

  def handle_info({:answer, _}, s), do: {:noreply, s}
  def handle_info({:greet, _}, s), do: {:noreply, s}

  def handle_info(:no_answer, %{answered: false, ending: false} = s) do
    out(s, %{type: "no_answer"})
    # The client hangs up after the announcement; this is in case it doesn't.
    Process.send_after(self(), :hangup, 30_000)
    {:noreply, %{s | ending: true}}
  end

  def handle_info(:no_answer, s), do: {:noreply, s}

  # ── the gateway ──

  def handle_info(:poll, s) do
    t = Task.Supervisor.async_nolink(Air.Tasks, &Gw.status/0)
    {:noreply, %{s | polls: t.ref}}
  end

  # ── task results ──

  def handle_info({ref, result}, %{turn: ref} = s) do
    Process.demonitor(ref, [:flush])

    s =
      case result do
        {:ok, messages} ->
          %{s | messages: messages, turn: nil}

        {:error, e, _} ->
          out(s, %{type: "error", text: "operator: #{e}"})
          %{s | turn: nil}
      end

    {:noreply, s |> flush() |> pick_up()}
  end

  def handle_info({ref, result}, %{greeting_task: ref} = s) do
    Process.demonitor(ref, [:flush])

    pcm =
      case result do
        {:ok, pcm} -> pcm
        {:error, e} -> out(s, %{type: "error", text: "tts: #{e}"}); ""
      end

    rung = System.monotonic_time(:millisecond) - s.rang_at
    Process.send_after(self(), {:answer, pcm}, max(@min_ring_ms - rung, 0))
    {:noreply, s}
  end

  def handle_info({ref, result}, %{speaking: ref} = s) do
    Process.demonitor(ref, [:flush])
    with {:error, e} <- result, do: out(s, %{type: "error", text: "tts: #{e}"})
    {:noreply, next_speech(%{s | speaking: nil})}
  end

  def handle_info({ref, result}, %{polls: ref} = s) do
    Process.demonitor(ref, [:flush])

    s = case result do
      {:ok, st} ->
        if st.state != s.tts.state, do: record(s, %{type: "tts", state: st.state, up_s: st.up_s})
        %{s | tts: st}

      _ ->
        s
    end

    state(s)
    Process.send_after(self(), :poll, if(s.tts.state == :ready, do: 15_000, else: 3_000))
    {:noreply, pick_up(%{s | polls: nil})}
  end

  def handle_info({:DOWN, ref, _, _, why}, %{turn: ref} = s) do
    out(s, %{type: "error", text: "operator crashed: #{inspect(why)}"})
    {:noreply, %{s | turn: nil} |> flush() |> pick_up()}
  end

  def handle_info({:DOWN, ref, _, _, why}, %{greeting_task: ref} = s) do
    out(s, %{type: "error", text: "tts crashed: #{inspect(why)}"})
    send(self(), {:answer, ""})
    {:noreply, s}
  end

  def handle_info({:DOWN, ref, _, _, why}, %{speaking: ref} = s) do
    out(s, %{type: "error", text: "tts crashed: #{inspect(why)}"})
    {:noreply, next_speech(%{s | speaking: nil})}
  end

  def handle_info({:DOWN, ref, _, _, _}, %{polls: ref} = s) do
    Process.send_after(self(), :poll, 3_000)
    {:noreply, %{s | polls: nil}}
  end

  def handle_info({:DOWN, _, :process, pid, _}, %{socket: pid} = s), do: {:stop, :normal, s}
  def handle_info(_, s), do: {:noreply, s}

  # ── turns ──

  defp event(s, text), do: %{s | pending: s.pending ++ [text]}

  defp flush(%{turn: nil, pending: [_ | _], ending: false} = s) do
    {changed, s} = sessions_changed(s)
    text = Enum.join([state_tag(s) | changed] ++ s.pending, "\n")
    record(s, %{type: "turn_in", text: text})
    messages = append_user(s.messages, %{text: text})
    ctx = s.ctx
    task = Task.Supervisor.async_nolink(Air.Tasks, fn -> Operator.turn(ctx, messages) end)
    %{s | turn: task.ref, pending: []}
  end

  defp flush(s), do: s

  # Picks up once the greeting turn is done and TTS is ready: the greeting is synthesized whole while it still
  # rings, then answered (`{:answer, pcm}`), no sooner than @min_ring_ms after dialling.
  defp pick_up(%{answered: false, ending: false, turn: nil, pending: [], greeting_task: nil, tts: %{state: :ready}} = s) do
    text = Enum.join(s.greeting)
    t = s.t
    task = Task.Supervisor.async_nolink(Air.Tasks, fn -> if text == "", do: {:ok, ""}, else: synthesize(text, t) end)
    %{s | greeting_task: task.ref}
  end

  defp pick_up(s), do: s

  defp synthesize(text, t) do
    key = make_ref()
    Process.put(key, [])

    with :ok <- Gw.speak(text, t["voice"], t["temperature"] || 0.85, &Process.put(key, [&1 | Process.get(key)])) do
      {:ok, key |> Process.get() |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end

  # Converse wants roles to alternate; a turn that ran out of tool rounds ends on a user message.
  defp append_user(messages, block) do
    case List.last(messages) do
      %{role: "user", content: c} -> List.replace_at(messages, -1, %{role: "user", content: c ++ [block]})
      _ -> messages ++ [%{role: "user", content: [block]}]
    end
  end

  # ── the session list: whole at the start, then only what changed, so the prefix stays cached ──

  @list_max 30

  defp sessions_list(s) do
    case Air.LoomSocket.sessions(s.t) do
      {:ok, list} ->
        now = System.system_time(:millisecond)
        list = Enum.sort_by(list, &(&1["last_active_at"] || 0), :desc)
        {shown, rest} = Enum.split(list, @list_max)

        lines =
          Enum.map(shown, &"- #{&1["id"]} 「#{&1["title"]}」 #{status(&1)}, #{ago(now - (&1["last_active_at"] || now))}")

        more = if rest == [], do: [], else: ["(#{length(rest)} older not listed)"]
        event(%{s | told: told(list)}, Enum.join(["<sessions>" | lines] ++ more ++ ["</sessions>"], "\n"))

      {:error, e} ->
        out(s, %{type: "error", text: "session list: #{inspect(e)}"})
        s
    end
  end

  defp sessions_changed(s) do
    case Air.LoomSocket.sessions(s.t) do
      {:ok, list} ->
        now = told(list)

        diff =
          Enum.flat_map(now, fn {id, {title, st}} ->
            case s.told[id] do
              nil -> ["new #{id} 「#{title}」 #{st}"]
              {^title, ^st} -> []
              {^title, _} -> ["#{id} 「#{title}」 now #{st}"]
              {old, _} -> ["#{id} 「#{old}」 renamed 「#{title}」, #{st}"]
            end
          end) ++ for({id, {title, _}} <- s.told, not Map.has_key?(now, id), do: "removed #{id} 「#{title}」")

        tag = if diff == [], do: [], else: ["<sessions_changed>" <> Enum.join(diff, "; ") <> "</sessions_changed>"]
        {tag, %{s | told: now}}

      _ ->
        {[], s}
    end
  end

  defp told(list), do: Map.new(list, &{&1["id"], {&1["title"], status(&1)}})

  # starting/running are one thing to the operator; fewer flips, fewer diffs.
  defp status(%{"status" => st}) when st in ["starting", "running"], do: "running"
  defp status(%{"status" => st}), do: to_string(st)

  defp ago(ms) when ms < 60_000, do: "just now"
  defp ago(ms) when ms < 3_600_000, do: "#{div(ms, 60_000)} min ago"
  defp ago(ms) when ms < 86_400_000, do: "#{div(ms, 3_600_000)} h ago"
  defp ago(ms), do: "#{div(ms, 86_400_000)} d ago"

  defp state_tag(s), do: ~s(<state loom_tasks_running="#{Enum.join(running(s), "; ")}"/>)

  # ── speech ──

  defp speak(s, item), do: next_speech(%{s | speech: :queue.in(item, s.speech)})

  # Nothing is spoken before the call is answered; the greeting goes first (handle_info {:answer, pcm}).
  defp next_speech(%{speaking: nil, answered: true} = s) do
    case :queue.out(s.speech) do
      {:empty, _} ->
        s

      {{:value, :end}, q} ->
        out(s, %{type: "end"})
        next_speech(%{s | speech: q})

      {{:value, {:tts, text}}, q} ->
        id = s.n + 1
        out(s, %{type: "speech", id: id, rate: Gw.sample_rate()})
        sock = s.socket
        t = s.t

        task = Task.Supervisor.async_nolink(Air.Tasks, fn ->
          r = Gw.speak(text, t["voice"], t["temperature"] || 0.85, &send(sock, {:pcm, &1}))
          send(sock, {:send, %{type: "speech_end", id: id}})
          r
        end)

        %{s | speech: q, speaking: task.ref, n: id}
    end
  end

  defp next_speech(s), do: s

  defp out(s, %{type: "error", text: t} = msg) do
    Logger.error("call #{s.t["name"]}: #{t}")
    record(s, msg)
    send(s.socket, {:send, msg})
  end

  # Cues and state ticks are not worth keeping; TTS changes are recorded where they happen.
  defp out(s, %{type: type} = msg) do
    if type not in ~w(state speech speech_end), do: record(s, msg)
    send(s.socket, {:send, msg})
  end

  # ── the call's record: data/calls/<tenant>/<UTC start>.jsonl, one event per line, appended as it happens ──

  defp log_path(t) do
    dir = Path.join([Config.data(), "calls", t["name"]])
    File.mkdir_p!(dir)
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d-%H%M%S")
    Path.join(dir, stamp <> ".jsonl")
  end

  defp record(s, event) do
    line = Jason.encode!(Map.put(event, :at, System.system_time(:millisecond))) <> "\n"
    File.write(s.log, line, [:append])
  end

  @impl true
  def terminate(reason, s) do
    record(s, %{type: "call_end", reason: inspect(reason)})
    Air.Memory.call_ended(s.t, s.log)
  end

  # The followed sessions that are running now, by title, from the lobby's list.
  defp running(s) do
    case Air.LoomSocket.sessions(s.t) do
      {:ok, list} -> for x <- list, x["id"] in s.following, status(x) == "running", do: x["title"]
      _ -> []
    end
  end

  defp state(s) do
    out(s, %{type: "state", tts: s.tts.state, up_s: s.tts.up_s, tasks: running(s)})
  end
end
