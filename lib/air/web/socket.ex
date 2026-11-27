defmodule Air.Web.Socket do
  @moduledoc """
  The client's socket (WebSock). Client → server JSON: `dial`, `heard {text}`, `hangup`. Server → client: JSON
  log and state messages from `Air.Call`, and PCM as binary frames between `speech` and `speech_end`.
  """
  @behaviour WebSock

  @impl true
  def init(t) do
    hello = %{type: "hello", tenant: t["name"], user: t["user"], voice: t["voice"], operator: t["operator_name"]}
    {:push, {:text, Jason.encode!(hello)}, %{t: t, call: nil}}
  end

  @impl true
  def handle_in({json, opcode: :text}, s) do
    case Jason.decode(json) do
      {:ok, %{"type" => "dial"}} when s.call == nil ->
        {:ok, pid} = Air.Call.start(s.t, self())
        Process.monitor(pid)
        {:push, {:text, Jason.encode!(%{type: "dialled"})}, %{s | call: pid}}

      {:ok, %{"type" => "heard", "text" => text}} when s.call != nil and is_binary(text) ->
        Air.Call.heard(s.call, String.slice(text, 0, 2000))
        {:ok, s}

      {:ok, %{"type" => "hangup"}} when s.call != nil ->
        Air.Call.hangup(s.call)
        {:ok, s}

      _ ->
        {:ok, s}
    end
  end

  def handle_in(_, s), do: {:ok, s}

  @impl true
  def handle_info({:send, msg}, s), do: {:push, {:text, Jason.encode!(msg)}, s}
  def handle_info({:pcm, bin}, s), do: {:push, {:binary, bin}, s}

  def handle_info({:DOWN, _, :process, pid, _}, %{call: pid} = s),
    do: {:push, {:text, Jason.encode!(%{type: "ended"})}, %{s | call: nil}}

  def handle_info(_, s), do: {:ok, s}

  @impl true
  def terminate(_, _), do: :ok
end
