defmodule Air.Memory do
  @moduledoc """
  What the operator remembers about a tenant across calls: `data/memory/<tenant>/memory.md`.

  - A call reads it once when it starts (`read/1`) and keeps that snapshot to the end, in its system prompt.
  - When a call ends, `call_ended/2` queues a rewrite: the memory model (Opus 5.5) gets the current memory
    plus the call, rendered as a dialogue, and returns the whole new memory. One GenServer per tenant runs
    the rewrites one at a time, so each starts from the result of the one before.
  - The old version is kept in `history/<UTC>.md` before the new one replaces it (temp + rename).
  - A call in which the user said nothing is skipped.
  """
  use GenServer, restart: :transient
  require Logger

  alias Air.Config

  def dir(tenant), do: Path.join([Config.data(), "memory", tenant])
  def path(tenant), do: Path.join(dir(tenant), "memory.md")

  def read(tenant) do
    case File.read(path(tenant)) do
      {:ok, s} -> String.trim(s)
      _ -> ""
    end
  end

  def call_ended(t, log) do
    pid =
      case DynamicSupervisor.start_child(Air.Sup, {__MODULE__, t["name"]}) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    GenServer.cast(pid, {:rewrite, t, log})
  end

  def child_spec(name), do: %{id: {__MODULE__, name}, start: {__MODULE__, :start_link, [name]}, restart: :transient}
  def start_link(name), do: GenServer.start_link(__MODULE__, name, name: {:via, Registry, {Air.Registry, {:memory, name}}})

  @impl true
  def init(name), do: {:ok, %{name: name, queue: :queue.new(), task: nil}}

  @impl true
  def handle_cast({:rewrite, t, log}, s), do: {:noreply, next(%{s | queue: :queue.in({t, log}, s.queue)})}

  @impl true
  def handle_info({ref, result}, %{task: ref} = s) do
    Process.demonitor(ref, [:flush])
    with {:error, e} <- result, do: Logger.error("memory #{s.name}: #{e}")
    {:noreply, next(%{s | task: nil})}
  end

  def handle_info({:DOWN, ref, _, _, why}, %{task: ref} = s) do
    Logger.error("memory #{s.name}: rewrite crashed #{inspect(why)}")
    {:noreply, next(%{s | task: nil})}
  end

  def handle_info(_, s), do: {:noreply, s}

  defp next(%{task: nil} = s) do
    case :queue.out(s.queue) do
      {{:value, {t, log}}, q} ->
        task = Task.Supervisor.async_nolink(Air.Tasks, fn -> rewrite(t, log) end)
        %{s | queue: q, task: task.ref}

      {:empty, _} ->
        s
    end
  end

  defp next(s), do: s

  # ── one rewrite ──

  def rewrite(t, log) do
    events = log |> File.stream!() |> Enum.map(&Jason.decode!/1)

    if Enum.any?(events, &(&1["type"] == "heard")) do
      old = read(t["name"])
      dialogue = render(events)

      body = %{
        system: [%{text: prompt(t)}],
        messages: [%{role: "user", content: [%{text: "<memory>\n#{old}\n</memory>\n\n<call>\n#{dialogue}\n</call>"}]}],
        inferenceConfig: %{maxTokens: 16_000}
      }

      with {:ok, r} <- Air.Bedrock.converse(body, "memory", model: Config.get(:memory_model), timeout: 300_000),
           text when text != "" <- text(r) do
        save(t["name"], old, text)
        Logger.info("memory #{t["name"]}: rewritten from #{Path.basename(log)} (#{String.length(text)} chars)")
        :ok
      else
        "" -> {:error, "empty memory from the model"}
        e -> e
      end
    else
      :ok
    end
  end

  defp text(%{"output" => %{"message" => %{"content" => content}}}) do
    content |> Enum.map_join("", &(&1["text"] || "")) |> String.trim()
  end

  defp save(name, old, new) do
    File.mkdir_p!(Path.join(dir(name), "history"))
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d-%H%M%S")
    if old != "", do: File.write!(Path.join([dir(name), "history", stamp <> ".md"]), old <> "\n")
    tmp = path(name) <> ".tmp"
    File.write!(tmp, new <> "\n")
    File.rename!(tmp, path(name))
  end

  defp prompt(t) do
    """
    You keep the memory of a phone operator: a voice assistant that #{t["user"] || "the user"} calls to chat \
    and to hand work to their Loom (a web UI where coding agents work in sessions). The operator reads this \
    memory at the start of every call; it is all it knows about earlier calls.

    You get the current memory and one call that just ended. Write the whole new memory.

    Keep: who they are (name, how they like to be addressed, family and people they mention), their \
    preferences about how the operator talks and works, what they often talk about, and which Loom sessions \
    do what (title and id, what it is for: only the ones the user talks about or that work went to, not \
    the whole list), so the operator knows where to send things. Facts they stated \
    outrank guesses; drop what the new call contradicts.

    Leave out: the dialogue itself, one-off small talk, results of tasks, and anything about session \
    status or pending work (that is live state and comes from Loom).

    Write it in English (names, titles and Chinese phrases as they are), as short markdown sections with \
    bullets, at most about 1500 characters: merge and drop the least useful when it grows. If the call adds \
    nothing, return the memory unchanged. Output only the memory, no preamble.
    """
  end

  # The call as a dialogue, with the session list it started with; other turn inputs and cues are left out.
  defp render(events) do
    events
    |> Enum.flat_map(fn
      %{"type" => "call_start", "at" => at} -> ["[call at #{DateTime.from_unix!(at, :millisecond) |> DateTime.to_iso8601()}]"]
      %{"type" => "turn_in", "text" => x} ->
        case Regex.run(~r{<sessions>.*</sessions>}s, x) do
          [list] -> ["[their Loom sessions when the call started]\n" <> list]
          _ -> []
        end

      %{"type" => "heard", "text" => x} -> ["User: " <> x]
      %{"type" => "say", "text" => x, "spoken" => sp} -> ["Operator: " <> x <> if(sp, do: "", else: " (not spoken)")]
      %{"type" => "clip_log", "name" => n, "text" => x} -> ["Operator (clip #{n}): " <> x]
      %{"type" => "tool", "name" => n, "input" => i, "result" => r} ->
        ["[#{n} #{Jason.encode!(i)} → #{String.slice(to_string(r), 0, 300)}]"]
      %{"type" => "loom_reply", "title" => ti, "session" => id, "text" => x} ->
        ["[Loom reply from 「#{ti}」 #{id}: #{String.slice(x, 0, 1500)}]"]
      _ -> []
    end)
    |> Enum.join("\n")
  end
end
