for app <- [:finch, :jason, :aws_signature], do: Application.ensure_all_started(app)
{:ok, _} = Finch.start_link(name: Air.Finch)
tool = fn name, strict -> %{toolSpec: Map.merge(%{name: name, description: "Report a number.", inputSchema: %{json: %{type: "object", properties: %{n: %{type: "integer"}}, required: ["n"], additionalProperties: false}}}, if(strict, do: %{strict: true}, else: %{}))} end
m = [%{role: "user", content: [%{text: "Call report with 7."}]}]
for strict <- [false, true] do
  b = %{system: [%{text: "Test."}], messages: m, toolConfig: %{tools: [tool.("report", strict)]}, inferenceConfig: %{maxTokens: 500},
    additionalModelRequestFields: %{thinking: %{type: "adaptive"}, output_config: %{effort: "low"}}}
  IO.puts("strict=#{strict}: " <> case Air.Bedrock.converse(b, "probe", model: "us.anthropic.claude-sonnet-5-5", timeout: 60_000) do
    {:ok, r} -> "ok #{inspect(r["output"]["message"]["content"])}"
    {:error, e} -> "ERROR " <> String.slice(to_string(e), 0, 400)
  end)
end
