defmodule Air.Loom do
  @moduledoc "A tenant's Loom over HTTP: create and submit. The list and the results come through `Air.LoomSocket`."

  defp req(t, method, path, body) do
    headers = [{"authorization", "Bearer " <> t["loom_token"]}, {"content-type", "application/json"}]
    body = body && Jason.encode!(body)

    case Finch.build(method, t["loom_url"] <> path, headers, body) |> Finch.request(Air.Finch, receive_timeout: 15_000) do
      {:ok, %{status: s, body: b}} when s in 200..299 -> {:ok, Jason.decode!(b)}
      {:ok, %{status: s, body: b}} -> {:error, "loom #{s}: #{String.slice(b, 0, 200)}"}
      {:error, e} -> {:error, "loom: #{inspect(e)}"}
    end
  end

  def create(t, title), do: req(t, :post, "/api/agents", %{backend: t["backend"] || "claude_code", title: title})

  def submit(t, id, text, client_msg_id),
    do: req(t, :post, "/api/agents/#{id}/submit", %{text: text, device: "loom-air", client_msg_id: client_msg_id})
end
