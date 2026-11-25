defmodule Air.Bedrock do
  @moduledoc "Bedrock Converse, non-streaming. Returns the decoded response or `{:error, reason}`."

  require Logger

  # One retry on a transport error: a call costs ~1 s, a dead connection should not cost the turn.
  # `opts`: `model` (default the operator's), `timeout` in ms (default 20 s).
  def converse(body, purpose, opts \\ []) do
    case call(body, purpose, opts) do
      {:error, {:transport, e}} ->
        Logger.warning("bedrock transport error, retrying: #{e}")
        call(body, purpose, opts) |> unwrap()

      r ->
        unwrap(r)
    end
  end

  defp unwrap({:error, {:transport, e}}), do: {:error, "bedrock: #{e}"}
  defp unwrap(r), do: r

  defp call(body, purpose, opts) do
    region = Air.Config.get(:region)
    model = Keyword.get(opts, :model, Air.Config.get(:model))
    url = "https://bedrock-runtime.#{region}.amazonaws.com/model/#{URI.encode(model, &URI.char_unreserved?/1)}/converse"
    json = Jason.encode!(body)
    headers = Air.AWS.sign("bedrock", region, "post", url, [{"content-type", "application/json"}], json)
    t0 = System.monotonic_time(:millisecond)

    case Finch.build(:post, url, headers, json) |> Finch.request(Air.Finch, receive_timeout: Keyword.get(opts, :timeout, 20_000)) do
      {:ok, %{status: 200, body: b}} ->
        r = Jason.decode!(b)
        Air.Config.log_usage(%{model: model, for: purpose, ms: System.monotonic_time(:millisecond) - t0, usage: r["usage"]})
        {:ok, r}

      {:ok, %{status: s, body: b}} ->
        {:error, "bedrock #{s}: #{String.slice(b, 0, 300)}"}

      {:error, e} ->
        {:error, {:transport, inspect(e)}}
    end
  end
end
