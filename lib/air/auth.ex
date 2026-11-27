defmodule Air.Auth do
  @moduledoc """
  Which tenant a client is. The web page has the shared app login cookie (`Air.Web.Router`) and names its
  tenant. An app has its Loom's login token instead: `Authorization: Bearer <token>` and `?loom=<the address it
  signed in to>` (user, 2026-11-27). The address picks the tenant, by its `public_url`; that tenant's Loom, at
  its own `loom_url`, is asked whether the token is one of its logins (`GET /api/layout`, which needs one and
  changes nothing). So the app signs in once, to its Loom, and a login revoked there is shut out here too.

  A token is only ever sent to a Loom in tenants.json, never to an address the client gives. Answers are kept
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

  defp tenant(address) do
    want = origin(address)

    Air.Config.tenants()
    |> Enum.find_value(:error, fn {name, t} ->
      if t["public_url"] && origin(t["public_url"]) == want, do: {:ok, Map.put(t, "name", name)}
    end)
  end

  # Scheme, host and port: "https://loom.example.com/" and "https://loom.example.com" are one Loom.
  defp origin(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: s, host: h, port: p} when is_binary(s) and is_binary(h) -> {String.downcase(s), String.downcase(h), p}
      _ -> nil
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
