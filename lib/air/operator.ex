defmodule Air.Operator do
  @moduledoc """
  The operator's prompt, tools and one turn. A turn runs in a Task owned by `Air.Call`: it calls the model,
  sends every piece of output to the call as it appears (`{:say, text}`, `{:clip, name}`, `:end_call`,
  `{:task, …}`, `{:log, …}`) and loops while the model asks for tools. It returns the new messages.
  """
  @max_rounds 6
  @final ~w(play_clip end_call send_to_session new_session)

  def system(t, clips, memory) do
    keywords = Enum.join(t["keywords"] || [], "、")

    """
    You are the operator on a phone call with #{t["user"] || "the user"}. You sit in front of their Loom, a \
    self-hosted web UI where coding agents (Claude Code, Codex, Kiro) work in sessions, with a shell, files, \
    their machines and their skills.

    The phone transcribes what they say; it arrives as <heard>. Expect ASR mistakes and fix them silently from \
    context. Words it often gets wrong: #{keywords}.

    Everything you write as text is spoken aloud at once by TTS, in this persona:
    #{t["persona"]}

    How to speak:
    - Simplified Chinese, spoken, one or two short sentences. No markdown, lists, emoji, code, URLs, session \
    ids or file paths. Say numbers the way people say them.
    - Never read out a long answer. A Loom reply is the written answer and stays in its session; give the gist \
    in a sentence or two and say the details are in the session.

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
    - Asked about progress: read_session, never invent what a session did. Never submit the same thing twice, \
    never send chit-chat to Loom.

    <state tts=…> tells you whether your text can be spoken. When tts is not "ready", text is NOT spoken: \
    answer with play_clip only (pick the one that fits, vary them) and write no text. When it is ready, speak \
    with text and use a clip only when one fits exactly.

    Text after a tool result is spoken too, so never narrate what you did ("submitted", "checked"): after a \
    tool, write only what you would say to them, or nothing.

    <call_started/>: they just dialled; greet them with a greeting clip.
    When they say goodbye: say goodbye (a clip or text), then end_call.

    Clips (name: words):
    #{Enum.map_join(clips, "\n", &"- #{&1["name"]}: #{&1["text"]}")}

    What you remember about them from earlier calls (use it naturally, never recite it):
    <memory>
    #{if memory == "", do: "(nothing yet: this is the first call)", else: memory}
    </memory>
    """
  end

  def tools(clips) do
    names = Enum.map(clips, & &1["name"])

    [
      tool("play_clip", "Play a pre-recorded clip in the persona's voice. Instant, works while TTS is cold.",
        %{name: %{type: "string", enum: names}}, ["name"]),
      tool("read_session", "A session's status and its last few user and assistant messages.",
        %{session_id: %{type: "string"}}, ["session_id"]),
      tool("send_to_session", "Send a message to an existing session. Returns at once; the reply comes later as <loom_reply>.",
        %{session_id: %{type: "string"}, text: %{type: "string"}}, ["session_id", "text"]),
      tool("new_session", "Start a new Loom session (Claude Code) with this prompt. Returns at once; the reply comes later as <loom_reply>.",
        %{title: %{type: "string", description: "a short title in Chinese"}, prompt: %{type: "string"}}, ["title", "prompt"]),
      tool("end_call", "Hang up. Only after saying goodbye.", %{}, [])
    ]
  end

  defp tool(name, desc, props, required) do
    %{toolSpec: %{name: name, description: desc,
      inputSchema: %{json: %{type: "object", properties: props, required: required}}}}
  end

  @doc "Runs one turn on `messages` (ending with a user message). Returns `{:ok, messages}` or `{:error, reason, messages}`."
  def turn(ctx, messages), do: round(ctx, messages, 1)

  defp round(ctx, messages, n) do
    body = %{
      system: [%{text: ctx.system}, %{cachePoint: %{type: "default"}}],
      messages: messages,
      toolConfig: %{tools: ctx.tools ++ [%{cachePoint: %{type: "default"}}]},
      inferenceConfig: %{maxTokens: 600}
    }

    # Haiku 5.5 thinks adaptively; on a phone line the second it costs matters more (AIR_THINKING=adaptive).
    body =
      if Air.Config.get(:thinking) == "disabled",
        do: Map.put(body, :additionalModelRequestFields, %{thinking: %{type: "disabled"}}),
        else: body

    case Air.Bedrock.converse(body, "operator") do
      {:ok, %{"output" => %{"message" => %{"content" => content}}, "stopReason" => stop}} ->
        content = Enum.map(content, &clean/1)
        messages = messages ++ [%{role: "assistant", content: content}]

        results =
          Enum.flat_map(content, fn
            %{text: text} ->
              if String.trim(text) != "", do: send(ctx.call, {:say, String.trim(text)})
              []
            %{toolUse: use} -> [run(ctx, use)]
            # reasoningContent and the like stay in the history as they came, and are not spoken.
            _ -> []
          end)

        names = for %{toolUse: %{name: name}} <- content, do: name
        failed = Enum.any?(results, &match?(%{toolResult: %{status: "error"}}, &1))

        cond do
          # These tools need no follow-up from the model: what to say was said before them, and asking
          # anyway costs a round and made it narrate ("Greeting played."). A failure goes back to it, so it
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

  defp tool_call(ctx, "play_clip", %{"name" => name}) do
    if Enum.any?(ctx.clips, &(&1["name"] == name)) do
      send(ctx.call, {:clip, name})
      {:ok, "played"}
    else
      {:error, "no clip #{name}"}
    end
  end

  defp tool_call(ctx, "end_call", _) do
    send(ctx.call, :end_call)
    {:ok, "hanging up"}
  end

  defp tool_call(ctx, "read_session", %{"session_id" => id}) do
    with {:ok, s} <- session(ctx, id),
         {:ok, snap} <- Air.LoomSocket.read(ctx.t, id, max((s["seq"] || 0) - 80, 0)) do
      msgs =
        for %{"kind" => k, "payload" => p} <- snap["events"], k in ["user", "assistant_text"], (p["text"] || "") != "" do
          %{from: if(k == "user", do: "user", else: "agent"), text: String.slice(p["text"], 0, 1200)}
        end

      {:ok, %{title: s["title"], status: s["status"], messages: Enum.take(msgs, -6)}}
    end
  end

  defp tool_call(ctx, "send_to_session", %{"session_id" => id, "text" => text}) do
    with {:ok, s} <- session(ctx, id) do
      submit(ctx, id, s["title"], s["seq"] || 0, text)
    end
  end

  defp tool_call(ctx, "new_session", %{"title" => title, "prompt" => prompt}) do
    with {:ok, s} <- Air.Loom.create(ctx.t, title) do
      submit(ctx, s["id"], title, s["seq"] || 0, prompt)
    end
  end

  defp tool_call(_ctx, name, _), do: {:error, "unknown tool #{name}"}

  defp session(ctx, id) do
    with {:ok, list} <- Air.LoomSocket.sessions(ctx.t) do
      case Enum.find(list, &(&1["id"] == id)) do
        nil -> {:error, "no session #{id}"}
        s -> {:ok, s}
      end
    end
  end

  # Watch first, from the seq before the submit, so the reply cannot slip past.
  defp submit(ctx, id, title, seq, text) do
    cmid = "air_" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

    with :ok <- Air.LoomSocket.watch(ctx.t, id, seq, cmid, ctx.call),
         {:ok, %{"status" => disposition}} <- Air.Loom.submit(ctx.t, id, text, cmid) do
      send(ctx.call, {:task, id, title})
      {:ok, %{session_id: id, status: disposition}}
    end
  end
end
