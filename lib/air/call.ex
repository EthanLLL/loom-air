defmodule Air.Call do
  @moduledoc """
  One phone call: the operator's conversation, the events waiting for the next turn, the speech queue and the
  gateway's state. It lives as long as its client socket, and ends on hang-up.

  Everything slow runs in Tasks (a model turn, a TTS stream, a gateway poll) whose results come back here, so
  the call always takes new events. One turn at a time: events that arrive meanwhile go into the next one.
  One speech item at a time, in order; the client plays them on one timeline.
  """
  use GenServer, restart: :temporary
  require Logger

  alias Air.{Config, Gw, Operator}

  def start(tenant, socket), do: DynamicSupervisor.start_child(Air.Sup, {__MODULE__, {tenant, socket}})
  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)
  def heard(call, text), do: send(call, {:heard, text})
  def hangup(call), do: send(call, :hangup)

  @impl true
  def init({t, socket}) do
    Process.monitor(socket)
    clips = Config.clips(t["voice"])

    s = %{
      t: t, socket: socket, clips: clips, messages: [], pending: [], turn: nil, speech: :queue.new(),
      speaking: nil, tts: %{state: :off, up_s: 0}, following: MapSet.new(), polls: nil, warm: false, ending: false, n: 0, told: %{}, log: log_path(t),
      ctx: %{t: t, clips: clips, call: self()}, phases: phases(t, clips)
    }

    record(s, %{type: "call_start", tenant: t["name"], voice: t["voice"], temperature: t["temperature"],
      model: Config.get(:model)})
    {:ok, s, {:continue, :dial}}
  end

  @impl true
  def handle_continue(:dial, s) do
    # Warm first and look once, so the greeting turn already knows TTS is cold.
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
    {:noreply, s |> event("<call_started/>") |> sessions_list() |> flush()}
  end

  @impl true
  def handle_info({:heard, text}, s) do
    out(s, %{type: "heard", text: text})
    {:noreply, s |> event("<heard>#{text}</heard>") |> flush()}
  end

  def handle_info(:hangup, s), do: {:stop, :normal, s}

  # ── from the turn ──

  def handle_info({:say, text}, s) do
    if s.tts.state == :ready do
      out(s, %{type: "say", text: text, spoken: true})
      {:noreply, speak(s, {:tts, text})}
    else
      out(s, %{type: "say", text: text, spoken: false})
      {:noreply, s}
    end
  end

  def handle_info({:clip, name}, s) do
    text = Enum.find_value(s.clips, "", &(&1["name"] == name && &1["text"]))
    out(s, %{type: "clip_log", name: name, text: text})
    {:noreply, speak(s, {:clip, name})}
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

    {:noreply, flush(s)}
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
    {:noreply, %{s | polls: nil}}
  end

  def handle_info({:DOWN, ref, _, _, why}, %{turn: ref} = s) do
    out(s, %{type: "error", text: "operator crashed: #{inspect(why)}"})
    {:noreply, flush(%{s | turn: nil})}
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
    phase = if s.tts.state == :ready, do: :warm, else: :cold
    record(s, %{type: "turn_in", phase: phase, text: text})
    # On the first warm turn the history becomes what the user heard (see Operator.spoken/1); left as it was,
    # the model kept calling play_clip after the tool was gone, and spoke like its unheard cold-phase notes.
    {messages, s} = if(phase == :warm and not s.warm, do: {Operator.spoken(s.messages), %{s | warm: true}}, else: {s.messages, s})
    messages = append_user(messages, %{text: text})
    ctx = Map.merge(s.ctx, s.phases[phase])
    task = Task.Supervisor.async_nolink(Air.Tasks, fn -> Operator.turn(ctx, messages) end)
    %{s | turn: task.ref, pending: []}
  end

  defp flush(s), do: s

  # The prompt and tools per phase, from the memory as it is when the call starts. A turn takes the phase TTS
  # is in when it starts: cold until it is ready, then warm for the rest of the call.
  defp phases(t, clips) do
    memory = Air.Memory.read(t["name"])
    Map.new([:cold, :warm], &{&1, %{system: Operator.system(t, memory, &1), tools: Operator.tools(clips, &1)}})
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

  defp state_tag(s) do
    tts =
      case s.tts do
        %{state: :ready} -> "ready"
        %{state: :warming, up_s: up} -> "warming, up #{up}s"
        %{state: st} -> to_string(st)
      end

    tasks = Enum.join(running(s), "; ")
    ~s(<state tts="#{tts}" loom_tasks_running="#{tasks}"/>)
  end

  # ── speech ──

  defp speak(s, item), do: next_speech(%{s | speech: :queue.in(item, s.speech)})

  defp next_speech(%{speaking: nil} = s) do
    case :queue.out(s.speech) do
      {:empty, _} ->
        s

      {{:value, {:clip, name}}, q} ->
        out(s, %{type: "clip", name: name})
        next_speech(%{s | speech: q})

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
    if type not in ~w(state speech speech_end clip), do: record(s, msg)
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
