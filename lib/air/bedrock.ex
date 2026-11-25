defmodule Air.Bedrock do
  @moduledoc "Bedrock Converse, non-streaming. Returns the decoded response or `{:error, reason}`."

  def converse(body, purpose) do
    region = Air.Config.get(:region)
    model = Air.Config.get(:model)
    url = "https://bedrock-runtime.#{region}.amazonaws.com/model/#{URI.encode(model, &URI.char_unreserved?/1)}/converse"
    json = Jason.encode!(body)
    headers = Air.AWS.sign("bedrock", region, "post", url, [{"content-type", "application/json"}], json)
    t0 = System.monotonic_time(:millisecond)

    case Finch.build(:post, url, headers, json) |> Finch.request(Air.Finch, receive_timeout: 60_000) do
      {:ok, %{status: 200, body: b}} ->
        r = Jason.decode!(b)
        Air.Config.log_usage(%{model: model, for: purpose, ms: System.monotonic_time(:millisecond) - t0, usage: r["usage"]})
        {:ok, r}

      {:ok, %{status: s, body: b}} ->
        {:error, "bedrock #{s}: #{String.slice(b, 0, 300)}"}

      {:error, e} ->
        {:error, "bedrock: #{inspect(e)}"}
    end
  end
end
