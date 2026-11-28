defmodule Air.Web.Serve do
  @moduledoc """
  What both doors serve once they know the tenant: the ringback, the tenant's voice's clips, `/me` and `/ws`.
  `Air.Web.Router` (the Loom app, page and cookie) and `Air.Web.Api` (the tunnel, Loom login only) each say who
  is asking; `app/1` is the Loom login (`Air.Auth`).
  """
  import Plug.Conn

  @doc "`{:ok, tenant, conn}` from `Authorization: Bearer <Loom token>` and `?loom=`, or the conn answered 401."
  def app(conn) do
    conn = fetch_query_params(conn)

    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, t} <- Air.Auth.app(conn.query_params["loom"], token) do
      {:ok, t, conn}
    else
      _ -> conn |> send_resp(401, "unauthorized") |> halt()
    end
  end

  def ringback(conn) do
    conn
    |> put_resp_content_type("audio/wav")
    |> put_resp_header("etag", ~s("#{Air.Config.ringback_version()}"))
    |> send_file(200, Air.Config.ringback_path())
  end

  # Only the tenant's own voice: one family's clips are not another's.
  def clip(conn, t, voice, file) do
    with true <- voice == t["voice"] and Regex.match?(~r/^[\w-]+\.wav$/, file),
         path = Air.Config.clip_path(voice, Path.rootname(file)),
         true <- File.exists?(path) do
      conn |> put_resp_content_type("audio/wav") |> send_file(200, path)
    else
      _ -> send_resp(conn, 404, "not found")
    end
  end

  @doc """
  Whether this Loom has Air, and who answers: an app asks before it shows a call button. With the ringback's
  version, so an app that keeps the ringback downloads it again only when it changed.
  """
  def me(conn, t) do
    body = Jason.encode!(%{operator: t["operator_name"], voice: t["voice"], ringback: Air.Config.ringback_version()})
    conn |> put_resp_content_type("application/json") |> send_resp(200, body)
  end

  def ws(conn, t), do: conn |> WebSockAdapter.upgrade(Air.Web.Socket, t, timeout: 120_000) |> halt()
end
