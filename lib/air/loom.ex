defmodule Air.Loom do
  @moduledoc "A tenant's Loom over HTTP: list, create and submit. Results come back through `Air.LoomSocket`."

  defp req(t, method, path, body \\ nil) do
    headers = [{"authorization", "Bearer " <> t["loom_token"]}, {"content-type", "application/json"}]
    body = body && Jason.encode!(body)

    case Finch.build(method, t["loom_url"] <> path, headers, body) |> Finch.request(Air.Finch, receive_timeout: 15_000) do
      {:ok, %{status: s, body: b}} when s in 200..299 -> {:ok, Jason.decode!(b)}
      {:ok, %{status: s, body: b}} -> {:error, "loom #{s}: #{String.slice(b, 0, 200)}"}
      {:error, e} -> {:error, "loom: #{inspect(e)}"}
    end
  end

  def sessions(t) do
    with {:ok, %{"sessions" => list}} <- req(t, :get, "/api/agents") do
      {:ok, Enum.sort_by(list, &(&1["last_active_at"] || 0), :desc)}
    end
  end

  def session(t, id) do
    with {:ok, list} <- sessions(t) do
      case Enum.find(list, &(&1["id"] == id)) do
        nil -> {:error, "no session #{id}"}
        s -> {:ok, s}
      end
    end
  end

  def create(t, title), do: req(t, :post, "/api/agents", %{backend: t["backend"] || "claude_code", title: title})

  def submit(t, id, text, client_msg_id),
    do: req(t, :post, "/api/agents/#{id}/submit", %{text: text, device: "loom-air", client_msg_id: client_msg_id})
end
