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
      speaking: nil, tts: %{state: :off, up_s: 0}, tasks: %{}, polls: nil, ending: false, n: 0,
      ctx: %{t: t, clips: clips, call: self(), system: Operator.system(t, clips), tools: Operator.tools(clips)}
    }

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

    state(s)
    Process.send_after(self(), :poll, 3_000)
    {:noreply, s |> event("<call_started/>") |> flush()}
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

  def handle_info({:task, id, title}, s) do
    s = put_in(s.tasks[id], title)
    state(s)
    {:noreply, s}
  end

  def handle_info({:log, entry}, s), do: (out(s, entry); {:noreply, s})

  # ── from Loom ──

  def handle_info({:loom_reply, id, text}, s) do
    title = Map.get(s.tasks, id, "")
    out(s, %{type: "loom_reply", session: id, title: title, text: text})
    s = %{s | tasks: Map.delete(s.tasks, id)}
    state(s)
    reply = String.slice(text, 0, 4000)
    {:noreply, s |> event(~s(<loom_reply session="#{id}" title="#{title}">#{reply}</loom_reply>)) |> flush()}
  end

  def handle_info({:loom_error, id, msg}, s) do
    out(s, %{type: "error", text: "Loom #{id}: #{msg}"})
    s = %{s | tasks: Map.delete(s.tasks, id)}
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
      {:ok, st} -> %{s | tts: st}
      _ -> s
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
    text = Enum.join([state_tag(s) | s.pending], "\n")
    messages = append_user(s.messages, %{text: text})
    ctx = s.ctx
    task = Task.Supervisor.async_nolink(Air.Tasks, fn -> Operator.turn(ctx, messages) end)
    %{s | turn: task.ref, pending: []}
  end

  defp flush(s), do: s

  # Converse wants roles to alternate; a turn that ran out of tool rounds ends on a user message.
  defp append_user(messages, block) do
    case List.last(messages) do
      %{role: "user", content: c} -> List.replace_at(messages, -1, %{role: "user", content: c ++ [block]})
      _ -> messages ++ [%{role: "user", content: [block]}]
    end
  end

  defp state_tag(s) do
    tts =
      case s.tts do
        %{state: :ready} -> "ready"
        %{state: :warming, up_s: up} -> "warming, up #{up}s"
        %{state: st} -> to_string(st)
      end

    tasks = s.tasks |> Map.values() |> Enum.map_join("; ", & &1)
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
    send(s.socket, {:send, msg})
  end

  defp out(s, msg), do: send(s.socket, {:send, msg})

  defp state(s) do
    out(s, %{type: "state", tts: s.tts.state, up_s: s.tts.up_s, tasks: s.tasks |> Map.values()})
  end
end
