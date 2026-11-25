defmodule Air.LoomSocket do
  @moduledoc """
  One Phoenix socket per tenant to its Loom's `/socket` (v2 JSON frames: `[join_ref, ref, topic, event,
  payload]`), over Mint.WebSocket.

  - `subscribe/4` follows a session for a call: it joins `agent:<id>` (from a seq taken before a submit, so the
    reply cannot slip past), and every `turn_done` after that sends `{:loom_reply, id, last_assistant_text}`
    to the subscriber, once per turn, whoever started it. Subscribing again is a no-op, so a call follows a
    session at most once. Subscribers are monitored: a call that ends drops its subscriptions.
  - `read/3` joins from an earlier seq and returns the snapshot's events.
  - `sessions/1` is the session list, kept current from the lobby channel (`agents`: the whole list in the
    join reply, then `session` / `removed` pushes), so nobody has to ask Loom for it.

  A topic stays joined while it has subscribers. Events are deduplicated by seq per topic, so a re-join (Phoenix
  replaces a duplicate join) or a reconnect never delivers twice. On a dropped connection it reconnects and
  re-joins from the last seq it saw.
  """
  use GenServer
  require Logger

  @heartbeat 30_000

  def start(tenant) do
    case DynamicSupervisor.start_child(Air.Sup, {__MODULE__, tenant}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      e -> e
    end
  end

  def child_spec(t), do: %{id: {__MODULE__, t["name"]}, start: {__MODULE__, :start_link, [t]}, restart: :transient}
  def start_link(t), do: GenServer.start_link(__MODULE__, t, name: {:via, Registry, {Air.Registry, {:loom, t["name"]}}})

  def subscribe(t, session, since_seq, pid) do
    {:ok, s} = start(t)
    GenServer.call(s, {:subscribe, session, since_seq, pid}, 20_000)
  end

  def sessions(t) do
    {:ok, s} = start(t)
    GenServer.call(s, :sessions, 20_000)
  end

  def read(t, session, since_seq) do
    {:ok, s} = start(t)
    GenServer.call(s, {:read, session, since_seq}, 20_000)
  end

  # ── server ──

  @impl true
  def init(t) do
    send(self(), :connect)
    {:ok, %{t: t, conn: nil, ws: nil, ref: nil, open: false, n: 0, topics: %{}, subs: %{}, waiting: %{}, later: [],
      lobby: nil, sessions: %{}}}
  end

  @impl true
  def handle_call(op, from, %{open: false} = s), do: {:noreply, %{s | later: s.later ++ [{op, from}]}}

  # Until the lobby's join reply is in, the list is not known yet.
  def handle_call(:sessions, from, %{lobby: {:joining, _}} = s), do: {:noreply, %{s | later: s.later ++ [{:sessions, from}]}}
  def handle_call(:sessions, _from, s), do: {:reply, {:ok, Map.values(s.sessions)}, s}

  # subs: topic => %{pids: MapSet, text: the last assistant_text of the turn running}
  def handle_call({:subscribe, id, since, pid}, from, s) do
    topic = "agent:" <> id
    sub = Map.get(s.subs, topic, %{pids: MapSet.new(), text: nil})

    if MapSet.member?(sub.pids, pid) do
      {:reply, :ok, s}
    else
      if not Enum.any?(s.subs, fn {_, x} -> MapSet.member?(x.pids, pid) end), do: Process.monitor(pid)
      s = put_in(s.subs[topic], %{sub | pids: MapSet.put(sub.pids, pid)})

      if Map.has_key?(s.topics, topic),
        do: {:reply, :ok, s},
        else: {:noreply, join(s, topic, since, {:subscribe, from})}
    end
  end

  def handle_call({:read, id, since}, from, s), do: {:noreply, join(s, "agent:" <> id, since, {:read, from})}

  @impl true
  def handle_info(:connect, s) do
    uri = URI.parse(s.t["loom_url"])
    {http, ws} = if uri.scheme == "https", do: {:https, :wss}, else: {:http, :ws}
    path = "/socket/websocket?" <> URI.encode_query(%{token: s.t["loom_token"], vsn: "2.0.0"})

    with {:ok, conn} <- Mint.HTTP.connect(http, uri.host, uri.port, protocols: [:http1]),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(ws, conn, path, []) do
      {:noreply, %{s | conn: conn, ref: ref}}
    else
      e ->
        Logger.warning("loom socket #{s.t["name"]}: connect failed #{inspect(e)}")
        Process.send_after(self(), :connect, 5_000)
        {:noreply, s}
    end
  end

  def handle_info(:heartbeat, %{open: true} = s) do
    Process.send_after(self(), :heartbeat, @heartbeat)
    {:noreply, push(s, [nil, ref(s), "phoenix", "heartbeat", %{}]) |> bump()}
  end

  def handle_info(:heartbeat, s), do: {:noreply, s}

  # A call ended: drop its subscriptions, and leave the topics nobody follows any more.
  def handle_info({:DOWN, _, :process, pid, _}, s) do
    s =
      Enum.reduce(s.subs, s, fn {topic, sub}, s ->
        pids = MapSet.delete(sub.pids, pid)

        if MapSet.size(pids) == 0,
          do: leave(%{s | subs: Map.delete(s.subs, topic)}, topic),
          else: put_in(s.subs[topic].pids, pids)
      end)

    {:noreply, s}
  end

  def handle_info(msg, %{conn: conn} = s) when conn != nil do
    case Mint.WebSocket.stream(conn, msg) do
      {:ok, conn, responses} -> {:noreply, Enum.reduce(responses, %{s | conn: conn}, &response/2)}
      {:error, _conn, e, _} -> {:noreply, dropped(s, e)}
      :unknown -> {:noreply, s}
    end
  end

  def handle_info(_msg, s), do: {:noreply, s}

  defp response({:status, _, status}, s), do: Map.put(s, :status, status)
  defp response({:headers, _, headers}, s), do: Map.put(s, :headers, headers)

  defp response({:done, _}, %{ws: nil} = s) do
    case Mint.WebSocket.new(s.conn, s.ref, s.status, s.headers) do
      {:ok, conn, ws} ->
        Process.send_after(self(), :heartbeat, @heartbeat)
        s = %{s | conn: conn, ws: ws, open: true}
        r = ref(s)
        s = push(s, [r, r, "agents", "phx_join", %{}]) |> bump() |> Map.put(:lobby, {:joining, r})
        # Re-join what was joined before the drop, then run what waited for the connection.
        s = Enum.reduce(s.topics, %{s | topics: %{}}, fn {topic, %{last: last}}, s -> join(s, topic, last, nil) end)
        Enum.reduce(s.later, %{s | later: []}, fn {op, from}, s -> {:noreply, s} = handle_call(op, from, s); s end)

      {:error, _conn, e} ->
        dropped(s, e)
    end
  end

  defp response({:data, _, data}, %{ws: ws} = s) when ws != nil do
    case Mint.WebSocket.decode(ws, data) do
      {:ok, ws, frames} -> Enum.reduce(frames, %{s | ws: ws}, &frame/2)
      {:error, _ws, e} -> dropped(s, e)
    end
  end

  defp response(_, s), do: s

  defp frame({:text, json}, s), do: message(Jason.decode!(json), s)
  defp frame({:ping, d}, s), do: send_frame(s, {:pong, d})
  defp frame({:close, _, _}, s), do: dropped(s, :closed)
  defp frame(_, s), do: s

  defp message([_, ref, "agents", "phx_reply", %{"status" => "ok", "response" => resp}], %{lobby: {:joining, ref}} = s) do
    s = %{s | lobby: ref, sessions: Map.new(resp["sessions"] || [], &{&1["id"], &1})}
    {later, rest} = Enum.split_with(s.later, &match?({:sessions, _}, &1))
    for {:sessions, from} <- later, do: GenServer.reply(from, {:ok, Map.values(s.sessions)})
    %{s | later: rest}
  end

  # Keep whichever copy has the higher seq: a push can arrive after a newer join reply.
  defp message([jref, _, "agents", "session", %{"id" => id} = sum], %{lobby: jref} = s) do
    if (get_in(s.sessions, [id, "seq"]) || -1) <= (sum["seq"] || 0),
      do: put_in(s.sessions[id], sum),
      else: s
  end

  defp message([jref, _, "agents", "removed", %{"id" => id}], %{lobby: jref} = s),
    do: %{s | sessions: Map.delete(s.sessions, id)}

  defp message([_jref, ref, topic, "phx_reply", %{"status" => st, "response" => resp}], s) do
    case Map.pop(s.waiting, ref) do
      {nil, _} ->
        s

      {{^topic, why}, waiting} ->
        s = %{s | waiting: waiting}
        events = if st == "ok", do: resp["events"] || [], else: []
        s = Enum.reduce(events, s, &event(topic, &1, &2))

        case why do
          {:subscribe, from} -> GenServer.reply(from, if(st == "ok", do: :ok, else: {:error, resp}))
          {:read, from} -> GenServer.reply(from, if(st == "ok", do: {:ok, resp}, else: {:error, resp}))
          nil -> :ok
        end

        # A read of a topic nobody follows leaves it again.
        if st == "ok" and not Map.has_key?(s.subs, topic), do: leave(s, topic), else: s
    end
  end

  defp message([jref, _ref, topic, "event", ev], s) do
    if get_in(s.topics, [topic, :jref]) == jref, do: event(topic, ev, s), else: s
  end

  defp message(_, s), do: s

  defp event(topic, %{"seq" => seq} = ev, s) do
    last = get_in(s.topics, [topic, :last]) || 0

    if seq <= last do
      s
    else
      s = if Map.has_key?(s.topics, topic), do: put_in(s.topics[topic].last, seq), else: s

      case s.subs[topic] do
        nil -> s
        sub -> put_in(s.subs[topic], advance(sub, topic, ev))
      end
    end
  end

  defp event(_topic, _ev, s), do: s

  defp advance(sub, _topic, %{"kind" => "assistant_text", "payload" => %{"text" => t}}), do: %{sub | text: t}

  defp advance(sub, "agent:" <> id, %{"kind" => "turn_done"}) do
    for pid <- sub.pids, do: send(pid, {:loom_reply, id, sub.text || ""})
    %{sub | text: nil}
  end

  defp advance(sub, "agent:" <> id, %{"kind" => "error", "payload" => p}) do
    for pid <- sub.pids, do: send(pid, {:loom_error, id, p["message"] || inspect(p)})
    %{sub | text: nil}
  end

  defp advance(sub, _, _), do: sub

  defp join(s, topic, since, why) do
    r = ref(s)
    s = push(s, [r, r, topic, "phx_join", %{since_seq: since, device: "loom-air"}]) |> bump()
    last = max(since, get_in(s.topics, [topic, :last]) || 0)
    s = put_in(s.topics[topic], %{jref: r, last: last})
    %{s | waiting: Map.put(s.waiting, r, {topic, why})}
  end

  defp leave(s, topic) do
    case Map.pop(s.topics, topic) do
      {nil, _} -> s
      {%{jref: j}, topics} -> push(%{s | topics: topics}, [j, ref(s), topic, "phx_leave", %{}]) |> bump()
    end
  end

  defp ref(s), do: Integer.to_string(s.n + 1)
  defp bump(s), do: %{s | n: s.n + 1}
  defp push(s, msg), do: send_frame(s, {:text, Jason.encode!(msg)})

  defp send_frame(%{ws: ws, conn: conn} = s, frame) when ws != nil do
    with {:ok, ws, data} <- Mint.WebSocket.encode(ws, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(conn, s.ref, data) do
      %{s | ws: ws, conn: conn}
    else
      {:error, _, e} -> dropped(s, e)
    end
  end

  defp dropped(s, why) do
    Logger.warning("loom socket #{s.t["name"]}: dropped #{inspect(why)}")
    if s.conn, do: Mint.HTTP.close(s.conn)
    for {_, {_, {_, from}}} <- s.waiting, do: GenServer.reply(from, {:error, :disconnected})
    Process.send_after(self(), :connect, 2_000)
    %{s | conn: nil, ws: nil, ref: nil, open: false, waiting: %{}, lobby: nil}
  end
end
