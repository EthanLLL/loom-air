defmodule Air.Auth do
  @moduledoc """
  Which tenant a client is. The web page has the shared app login cookie (`Air.Web.Router`) and names its
  tenant. An app has its Loom's login token instead: `Authorization: Bearer <token>` and `?loom=<the address it
  signed in to>` (user, 2026-11-27). The address is the tenant (`tenants/<host>.json`); that tenant's Loom, at
  its own `loom_url`, is asked whether the token is one of its logins (`GET /api/layout`, which needs one and
  changes nothing). So the app signs in once, to its Loom, and a login revoked there is shut out here too.

  A token is only ever sent to a Loom in `tenants/`, never to an address the client gives. Answers are kept
  for a minute, by the token's hash, so a call's ringback, clips and socket ask once; a no is not kept, so a
  Loom that was briefly out of reach doesn't keep anyone out.
  """
  @table __MODULE__
  @keep_ms 60_000

  def init, do: :ets.new(@table, [:named_table, :public, read_concurrency: true])

  @doc "`{:ok, tenant}` or `:error`."
  def app(address, token) when is_binary(address) and is_binary(token) and token != "" do
    with {:ok, t} <- tenant(address) do
      key = {t["name"], :crypto.hash(:sha256, token)}
      now = System.monotonic_time(:millisecond)

      case :ets.lookup(@table, key) do
        [{_, until}] when now < until ->
          {:ok, t}

        _ ->
          if login?(t, token) do
            :ets.insert(@table, {key, now + @keep_ms})
            {:ok, t}
          else
            :error
          end
      end
    end
  end

  def app(_, _), do: :error

  # The Loom's host, and its port off the default one: "https://loom.example.com/" is `loom.example.com`.
  defp tenant(address) do
    case URI.parse(String.trim(address)) do
      %URI{scheme: scheme, host: host, port: port} when scheme in ["https", "http"] and is_binary(host) ->
        default = if scheme == "https", do: 443, else: 80
        id = if port in [nil, default], do: String.downcase(host), else: "#{String.downcase(host)}:#{port}"
        Air.Config.tenant(id)

      _ ->
        :error
    end
  end

  defp login?(t, token) do
    Finch.build(:get, t["loom_url"] <> "/api/layout", [{"authorization", "Bearer " <> token}])
    |> Finch.request(Air.Finch, receive_timeout: 10_000)
    |> case do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  end
end
