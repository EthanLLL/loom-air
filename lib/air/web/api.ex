defmodule Air.Web.Api do
  @moduledoc """
  The door from outside (the Cloudflare tunnel, its own port): what an app needs for a call and nothing else,
  and only with a Loom login. No page, no cookie; anything else is 404.
  """
  use Plug.Router
  alias Air.Web.Serve

  plug :match
  plug :dispatch

  get "/me" do
    with {:ok, t, conn} <- Serve.app(conn), do: Serve.me(conn, t)
  end

  get "/ringback.wav" do
    with {:ok, _t, conn} <- Serve.app(conn), do: Serve.ringback(conn)
  end

  get "/clips/:voice/:file" do
    with {:ok, t, conn} <- Serve.app(conn), do: Serve.clip(conn, t, voice, file)
  end

  get "/ws" do
    with {:ok, t, conn} <- Serve.app(conn), do: Serve.ws(conn, t)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
