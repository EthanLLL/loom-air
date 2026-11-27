defmodule Air.Web.Router do
  @moduledoc """
  The test client: the page, the ringback, the voice's clips and `/ws`. Served as the Loom app `loom-air` (proxy all), so paths may
  carry the `/apps/loom-air` prefix. The page is behind the shared app login cookie (`~/app-kit/auth.ts`'s
  `app_session`); the ringback, the clips and `/ws` also take an app's Loom login (`Air.Auth`).
  """
  use Plug.Router

  plug :strip_prefix
  plug :match
  plug :dispatch

  @public ~w(favicon.svg)

  defp strip_prefix(conn, _) do
    case conn.path_info do
      ["apps", _app | rest] -> %{conn | path_info: rest}
      _ -> conn
    end
  end

  get "/" do
    with :ok <- authed(conn) do
      conn |> put_resp_content_type("text/html") |> send_file(200, static("index.html"))
    end
  end

  get "/ringback.wav" do
    with {:ok, _t, conn} <- client(conn) do
      conn |> put_resp_content_type("audio/wav") |> send_file(200, Air.Config.ringback_path())
    end
  end

  get "/clips/:voice/:file" do
    with {:ok, _t, conn} <- client(conn),
         true <- Regex.match?(~r/^[\w-]+$/, voice) and Regex.match?(~r/^[\w-]+\.wav$/, file),
         path = Air.Config.clip_path(voice, Path.rootname(file)),
         true <- File.exists?(path) do
      conn |> put_resp_content_type("audio/wav") |> send_file(200, path)
    else
      %Plug.Conn{} = c -> c
      _ -> send_resp(conn, 404, "not found")
    end
  end

  get "/ws" do
    with {:ok, t, conn} <- client(conn) do
      conn |> WebSockAdapter.upgrade(Air.Web.Socket, t, timeout: 120_000) |> halt()
    end
  end

  get "/:file" when file in @public do
    send_file(conn, 200, static(file))
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp static(file), do: Path.join(:code.priv_dir(:air), "static/" <> file)

  # The tenant: an app's by its Loom login, or, with the app cookie, the one the page names (else the first).
  defp client(conn) do
    conn = fetch_query_params(conn)

    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        case Air.Auth.app(conn.query_params["loom"], token) do
          {:ok, t} -> {:ok, t, conn}
          :error -> conn |> send_resp(401, "unauthorized") |> halt()
        end

      _ ->
        with :ok <- authed(conn) do
          case Air.Config.tenant(conn.query_params["tenant"] || Air.Config.default_tenant()) do
            {:ok, t} -> {:ok, t, conn}
            :error -> conn |> send_resp(404, "no tenant") |> halt()
          end
        end
    end
  end

  defp authed(conn) do
    conn = fetch_cookies(conn)

    if valid?(conn.cookies["app_session"]) do
      :ok
    else
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(401, ~s(<meta name="viewport" content="width=device-width"><p style="font:16px system-ui;padding:2em">先登录：<a href="/apps/voice-lab/login">登录</a>（所有 app 共用一个登录），再回到这一页。</p>))
      |> halt()
    end
  end

  defp valid?(nil), do: false

  defp valid?(token) do
    with [mac | rev] when rev != [] <- token |> String.split(".") |> Enum.reverse(),
         body = rev |> Enum.reverse() |> Enum.join("."),
         {:ok, key} <- Air.Config.get(:app_secret_file) |> File.read!() |> String.trim() |> Base.decode16(case: :lower),
         want = :crypto.mac(:hmac, :sha256, key, body) |> Base.url_encode64(padding: false),
         true <- Plug.Crypto.secure_compare(mac, want),
         {exp, _} <- Integer.parse(body) do
      exp > System.system_time(:second)
    else
      _ -> false
    end
  end
end
