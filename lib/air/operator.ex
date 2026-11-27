defmodule Air.Operator do
  @moduledoc """
  The operator's prompt, tools and one turn. A turn runs in a Task owned by `Air.Call`: it calls the model,
  sends every piece of output to the call as it appears (`{:say, text}`, `:end_call`,
  `{:task, …}`, `{:log, …}`) and loops while the model asks for tools. It returns the new messages.
  """
  @max_rounds 6
  @final ~w(end_call send_to_session new_session)

  @doc """
  The system prompt. Everything the operator writes is spoken: the call is answered only once TTS is ready
  and the greeting is synthesized (`Air.Call`), so there is no phase in which it can't be heard.
  """
  def system(t, memory) do
    keywords = Enum.join(t["keywords"] || [], "、")

    """
    You are the operator on a phone call with #{t["user"] || "the user"}. You sit in front of their Loom, a \
    self-hosted web UI where coding agents (Claude Code, Codex, Kiro) work in sessions, with a shell, files, \
    their machines and their skills.

    The phone transcribes what they say; it arrives as <heard>. Expect ASR mistakes and fix them silently from \
    context. Words it often gets wrong: #{keywords}.

    Your voice, in this persona:
    #{t["persona"]}

    Everything you write as text is spoken aloud at once by TTS. How to speak:
    - Simplified Chinese, spoken, one or two short sentences. No markdown, lists, emoji, code, URLs, session ids \
    or file paths. Say numbers the way people say them.
    - Never read out a long answer. A Loom reply is the written answer and stays in its session; give the gist \
    in a sentence or two and say the details are in the session.
    - Text after a tool result is spoken too, so never narrate what you did ("submitted", "checked"): after a \
    tool, write only what you would say to them, or nothing.

    What to do:
    - When they ask for Loom or a session by name, do exactly that, even if you could answer yourself.
    - Small talk and questions you can answer from general knowledge: answer yourself.
    - Anything that needs real work (their files, machines, code, data, the web, anything you would have to \
    guess): hand it to Loom. Use send_to_session when it clearly continues an existing session, otherwise \
    new_session. Write the prompt for an agent: full sentences in Chinese, self-contained, with what they asked \
    and any detail they gave. In the same reply, before the tool call, tell them briefly that you're handing it \
    over: nothing is said after it. The reply comes later as <loom_reply>; then tell them the gist.
    - Their sessions are listed in <sessions> when the call starts; <sessions_changed> brings what changed since. \
    Answer questions about which sessions exist or run from that, without a tool.
    - Asked about progress: read_sessions (all the sessions asked about in one call), never invent what a \
    session did. Never submit the same thing twice, never send chit-chat to Loom.
    - The sessions you read, send to or start are followed for the rest of the call: each time one finishes \
    a turn, its reply arrives as <loom_reply>, also for turns you did not start.

    <call_started/>: they just dialled and the phone is ringing; greet them, short: it is the first thing \
    they hear when you pick up.
    When they say goodbye: say goodbye, then end_call.

    What you remember about them from earlier calls (use it naturally, never recite it):
    <memory>
    #{if memory == "", do: "(nothing yet: this is the first call)", else: memory}
    </memory>
    """
  end

  @doc "The operator's tools."
  def tools do
    [
      tool("read_sessions", "Sessions' status and latest messages: the last few for one session, the last reply in short for several. Reading a session also follows it for the rest of the call.",
        %{session_ids: %{type: "array", items: %{type: "string"}}}, ["session_ids"]),
      tool("send_to_session", "Send a message to an existing session. Returns at once; the reply comes later as <loom_reply>.",
        %{session_id: %{type: "string"}, text: %{type: "string"}}, ["session_id", "text"]),
      tool("new_session", "Start a new Loom session (Claude Code) with this prompt. Returns at once; the reply comes later as <loom_reply>.",
        %{title: %{type: "string", description: "a short title in Chinese"}, prompt: %{type: "string"}}, ["title", "prompt"]),
      tool("end_call", "Hang up. Only after saying goodbye.", %{}, [])
    ]
  end

  defp tool(name, desc, props, required) do
    %{toolSpec: %{name: name, description: desc, strict: true,
      inputSchema: %{json: %{type: "object", properties: props, required: required, additionalProperties: false}}}}
  end

  @doc "Runs one turn on `messages` (ending with a user message). Returns `{:ok, messages}` or `{:error, reason, messages}`."
  def turn(ctx, messages), do: round(ctx, messages, 1)

  defp round(ctx, messages, n) do
    body = %{
      system: [%{text: ctx.system}, %{cachePoint: %{type: "default"}}],
      messages: messages,
      toolConfig: %{tools: ctx.tools ++ [%{cachePoint: %{type: "default"}}]},
      inferenceConfig: %{maxTokens: 2000}
    }

    # Adaptive thinking at the lowest effort: easy turns don't think at all, and thinking is never spoken.
    # Not "between_tools" (Sonnet 5.5's thinking-off): with it the model wrote notes to itself before
    # tool calls as plain text ("用户想看…，我先读一下"), and those were spoken.
    fields =
      %{thinking: %{type: Air.Config.get(:thinking)}}
      |> then(&if(e = Air.Config.get(:effort), do: Map.put(&1, :output_config, %{effort: e}), else: &1))

    body = Map.put(body, :additionalModelRequestFields, fields)

    case Air.Bedrock.converse(body, "operator") do
      {:ok, %{"output" => %{"message" => %{"content" => content}}, "stopReason" => stop}} ->
        # Thinking blocks never go into the history (each is bound to the exact prompt and tools it was made
        # under), and are never spoken.
        content = content |> Enum.map(&clean/1) |> Enum.reject(&is_nil/1)
        messages = messages ++ [%{role: "assistant", content: content}]

        results =
          Enum.flat_map(content, fn
            %{text: text} ->
              if String.trim(text) != "", do: send(ctx.call, {:say, String.trim(text)})
              []
            %{toolUse: use} -> [run(ctx, use)]
            _ -> []
          end)

        names = for %{toolUse: %{name: name}} <- content, do: name
        failed = Enum.any?(results, &match?(%{toolResult: %{status: "error"}}, &1))

        cond do
          # These tools need no follow-up from the model: what to say was said before them, and asking
          # anyway costs a round and made it narrate ("Submitted."). A failure goes back to it, so it
          # can tell the user. The results stay in the history, merged with the next events.
          results != [] and not failed and Enum.all?(names, &(&1 in @final)) ->
            {:ok, messages ++ [%{role: "user", content: results}]}

          stop == "tool_use" and results != [] and n < @max_rounds ->
            round(ctx, messages ++ [%{role: "user", content: results}], n + 1)

          results != [] ->
            # Out of rounds: answer the tools so the history stays valid, and stop.
            {:ok, messages ++ [%{role: "user", content: results ++ [%{text: "<note>tool rounds exhausted</note>"}]}]}

          true ->
            {:ok, messages}
        end

      {:error, e} ->
        {:error, e, messages}
    end
  end

  defp clean(%{"text" => t}), do: %{text: t}
  defp clean(%{"toolUse" => u}), do: %{toolUse: %{toolUseId: u["toolUseId"], name: u["name"], input: u["input"] || %{}}}
  defp clean(%{"reasoningContent" => _}), do: nil
  defp clean(other), do: other

  defp run(ctx, %{toolUseId: id, name: name, input: input}) do
    result =
      try do
        tool_call(ctx, name, input)
      rescue
        e -> {:error, Exception.message(e)}
      end

    send(ctx.call, {:log, %{type: "tool", name: name, input: input, result: summary(result)}})

    case result do
      {:ok, data} -> %{toolResult: %{toolUseId: id, content: [%{json: %{result: data}}]}}
      {:error, e} -> %{toolResult: %{toolUseId: id, content: [%{text: to_string(e)}], status: "error"}}
    end
  end

  defp summary({:ok, d}) when is_binary(d), do: d
  defp summary({:ok, d}), do: Jason.encode!(d) |> String.slice(0, 400)
  defp summary({:error, e}), do: "error: " <> to_string(e)

  defp tool_call(ctx, "end_call", _) do
    send(ctx.call, :end_call)
    {:ok, "hanging up"}
  end

  defp tool_call(ctx, "read_sessions", %{"session_ids" => [_ | _] = ids}) do
    {:ok, list} = Air.LoomSocket.sessions(ctx.t)
    detail = length(ids) == 1

    views =
      ids
      |> Task.async_stream(&read(ctx, list, &1, detail), timeout: 25_000, on_timeout: :kill_task)
      |> Enum.zip_with(ids, fn
        {:ok, view}, _ -> view
        _, id -> %{session_id: id, error: "timed out"}
      end)

    {:ok, if(detail, do: hd(views), else: views)}
  end

  defp tool_call(ctx, "send_to_session", %{"session_id" => id, "text" => text}) do
    with {:ok, s} <- session(ctx, id) do
      submit(ctx, id, s["seq"] || 0, text)
    end
  end

  defp tool_call(ctx, "new_session", %{"title" => title, "prompt" => prompt}) do
    with {:ok, s} <- Air.Loom.create(ctx.t, title) do
      submit(ctx, s["id"], s["seq"] || 0, prompt)
    end
  end

  defp tool_call(_ctx, name, _), do: {:error, "unknown tool #{name}"}

  # One session, read and followed. Followed first, from its current seq, so the read's older events are not
  # taken for new ones. One session gets its last few messages; several get the last reply each, in short.
  defp read(ctx, list, id, detail) do
    with s when s != nil <- Enum.find(list, &(&1["id"] == id)) || {:error, "no session #{id}"},
         :ok <- follow(ctx, id, s["seq"] || 0),
         {:ok, snap} <- Air.LoomSocket.read(ctx.t, id, max((s["seq"] || 0) - 80, 0)) do
      Map.merge(%{session_id: id, title: s["title"], status: s["status"]}, view(snap["events"], detail))
    else
      {:error, e} -> %{session_id: id, error: to_string(e)}
      e -> %{session_id: id, error: inspect(e)}
    end
  end

  defp follow(ctx, id, seq) do
    with :ok <- Air.LoomSocket.subscribe(ctx.t, id, seq, ctx.call) do
      send(ctx.call, {:following, id})
      :ok
    end
  end

  @doc "What read_sessions shows of a session's events."
  def view(events, true) do
    msgs =
      for %{"kind" => k, "payload" => p} <- events, k in ["user", "assistant_text"], (p["text"] || "") != "" do
        %{from: if(k == "user", do: "user", else: "agent"), text: String.slice(p["text"], 0, 1200)}
      end

    %{messages: Enum.take(msgs, -6)}
  end

  def view(events, false) do
    last = for(%{"kind" => "assistant_text", "payload" => %{"text" => t}} <- events, t != "", do: t) |> List.last()
    %{last_reply: if(last, do: String.slice(last, 0, 300), else: nil)}
  end

  defp session(ctx, id) do
    with {:ok, list} <- Air.LoomSocket.sessions(ctx.t) do
      case Enum.find(list, &(&1["id"] == id)) do
        nil -> {:error, "no session #{id}"}
        s -> {:ok, s}
      end
    end
  end

  # Follow first, from the seq before the submit, so the reply cannot slip past.
  defp submit(ctx, id, seq, text) do
    cmid = "air_" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

    with :ok <- follow(ctx, id, seq),
         {:ok, %{"status" => disposition}} <- Air.Loom.submit(ctx.t, id, text, cmid) do
      {:ok, %{session_id: id, status: disposition}}
    end
  end
end
