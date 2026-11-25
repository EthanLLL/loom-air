# Does Converse accept a history with a toolUse for a tool no longer in toolConfig? (Sonnet 5.5, adaptive low)
for app <- [:finch, :jason, :aws_signature], do: Application.ensure_all_started(app)
{:ok, _} = Finch.start_link(name: Air.Finch)
tool = fn name -> %{toolSpec: %{name: name, description: name, inputSchema: %{json: %{type: "object", properties: %{}}}}} end
msgs = [
  %{role: "user", content: [%{text: "Call play_clip now."}]},
  %{role: "assistant", content: [%{toolUse: %{toolUseId: "t1", name: "play_clip", input: %{}}}]},
  %{role: "user", content: [%{toolResult: %{toolUseId: "t1", content: [%{text: "played"}]}}, %{text: "Now just say hi in one word."}]}
]
for {label, tools} <- [{"with play_clip", [tool.("play_clip"), tool.("end_call")]}, {"without play_clip", [tool.("end_call")]}] do
  body = %{system: [%{text: "Test."}], messages: msgs, toolConfig: %{tools: tools}, inferenceConfig: %{maxTokens: 2000},
    additionalModelRequestFields: %{thinking: %{type: "adaptive"}, output_config: %{effort: "low"}}}
  r = Air.Bedrock.converse(body, "probe", model: "us.anthropic.claude-sonnet-5-5")
  IO.puts("#{label}: " <> case r do
    {:ok, %{"output" => %{"message" => %{"content" => c}}}} -> "ok " <> inspect(Enum.map(c, &Map.keys/1))
    {:error, e} -> "ERROR " <> String.slice(e, 0, 300)
  end)
end

# A thinking block produced under one tool list, replayed under another.
base = fn tools -> %{system: [%{text: "Test."}], toolConfig: %{tools: tools}, inferenceConfig: %{maxTokens: 2000},
  additionalModelRequestFields: %{thinking: %{type: "adaptive"}, output_config: %{effort: "max"}}} end
m1 = [%{role: "user", content: [%{text: "How many primes are there between 1000 and 1100? Answer with the number only."}]}]
{:ok, r} = Air.Bedrock.converse(Map.put(base.([tool.("play_clip"), tool.("end_call")]), :messages, m1), "probe", model: "us.anthropic.claude-sonnet-5-5")
c = r["output"]["message"]["content"]
IO.puts("first: " <> inspect(Enum.map(c, &Map.keys/1)))
m2 = m1 ++ [%{role: "assistant", content: c}, %{role: "user", content: [%{text: "And 12*12?"}]}]
for {label, tools} <- [{"same tools", [tool.("play_clip"), tool.("end_call")]}, {"tools changed", [tool.("end_call")]}] do
  IO.puts("#{label}: " <> case Air.Bedrock.converse(Map.put(base.(tools), :messages, m2), "probe", model: "us.anthropic.claude-sonnet-5-5") do
    {:ok, _} -> "ok"
    {:error, e} -> "ERROR " <> String.slice(e, 0, 400)
  end)
end
