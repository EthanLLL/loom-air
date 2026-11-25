# Replaying a tool-use turn with its thinking blocks dropped: accepted? And after a tool-list change?
for app <- [:finch, :jason, :aws_signature], do: Application.ensure_all_started(app)
{:ok, _} = Finch.start_link(name: Air.Finch)
tool = fn name -> %{toolSpec: %{name: name, description: "Report a number.", inputSchema: %{json: %{type: "object", properties: %{n: %{type: "integer"}}, required: ["n"]}}}} end
body = fn tools, msgs -> %{system: [%{text: "Test."}], messages: msgs, toolConfig: %{tools: tools}, inferenceConfig: %{maxTokens: 8000},
  additionalModelRequestFields: %{thinking: %{type: "adaptive"}, output_config: %{effort: "max"}}} end
m1 = [%{role: "user", content: [%{text: "Count the primes between 1000 and 1100, then call report with that number."}]}]
{:ok, r} = Air.Bedrock.converse(body.([tool.("report"), tool.("other")], m1), "probe", model: "us.anthropic.claude-sonnet-5-5", timeout: 120_000)
c = r["output"]["message"]["content"]
IO.puts("first: #{inspect(Enum.map(c, &Map.keys/1))} stop=#{r["stopReason"]}")
use = Enum.find_value(c, & &1["toolUse"])
dropped = Enum.reject(c, &Map.has_key?(&1, "reasoningContent"))
m2 = m1 ++ [%{role: "assistant", content: dropped}, %{role: "user", content: [%{toolResult: %{toolUseId: use["toolUseId"], content: [%{text: "ok"}]}}]}]
m3 = m2 ++ [%{role: "assistant", content: [%{text: "Done."}]}, %{role: "user", content: [%{text: "Now say bye."}]}]
for {label, tools, m} <- [{"tool result, thinking dropped", [tool.("report"), tool.("other")], m2},
                          {"later turn, thinking dropped, tools changed", [tool.("report")], m3}] do
  IO.puts("#{label}: " <> case Air.Bedrock.converse(body.(tools, m), "probe", model: "us.anthropic.claude-sonnet-5-5", timeout: 120_000) do
    {:ok, r} -> "ok #{inspect(Enum.map(r["output"]["message"]["content"], &Map.keys/1))}"
    {:error, e} -> "ERROR " <> String.slice(e, 0, 400)
  end)
end
