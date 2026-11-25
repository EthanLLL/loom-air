defmodule Air.Gw do
  @moduledoc """
  infer-gw: `warm/0`, `status/0` and `speak/4`, which streams `/v1/audio/speech` as raw PCM (24 kHz s16le
  mono) into a callback. The gateway holds a request while a worker boots; callers check `status/0` first.
  """
  @sample_rate 24_000
  def sample_rate, do: @sample_rate

  defp url(path), do: Air.Config.get(:gw_url) <> path
  defp model, do: Air.Config.get(:gw_model)

  defp headers do
    key = :persistent_term.get({__MODULE__, :key}, nil) ||
      (k = Air.Config.get(:gw_key_file) |> File.read!() |> String.trim(); :persistent_term.put({__MODULE__, :key}, k); k)

    [{"authorization", "Bearer " <> key}, {"content-type", "application/json"}]
  end

  def warm do
    Finch.build(:post, url("/gw/warm"), headers(), Jason.encode!(%{model: model()}))
    |> Finch.request(Air.Finch, receive_timeout: 10_000)
    |> case do
      {:ok, %{status: 200}} -> :ok
      other -> {:error, inspect(other)}
    end
  end

  @doc "`%{state: :ready | :warming | :booting | :launching | :off, up_s: n}` or `{:error, _}`."
  def status do
    case Finch.build(:get, url("/gw/status?model=" <> model()), headers()) |> Finch.request(Air.Finch, receive_timeout: 5_000) do
      {:ok, %{status: 200, body: b}} -> {:ok, summarize(Jason.decode!(b))}
      other -> {:error, inspect(other)}
    end
  end

  defp summarize(%{"workers" => ws} = s) do
    states = Enum.map(ws, & &1["state"])
    up = ws |> Enum.map(&(&1["up_s"] || 0)) |> Enum.max(fn -> 0 end)

    state =
      cond do
        "ready" in states -> :ready
        "warming" in states -> :warming
        states != [] -> :booting
        (s["launching"] || 0) > 0 or s["launching"] == true -> :launching
        true -> :off
      end

    %{state: state, up_s: up}
  end

  @doc "Streams speech for `text`; `sink.(pcm_binary)` per chunk. Returns :ok or {:error, _}."
  def speak(text, voice, temperature, sink) do
    body = %{
      model: model(), input: text, voice: voice, response_format: "pcm", stream: true, stream_format: "audio",
      extra_params: %{temperature: temperature}
    }

    req = Finch.build(:post, url("/v1/audio/speech"), headers(), Jason.encode!(body))

    Finch.stream(req, Air.Finch, {nil, ""}, fn
      {:status, s}, {_, rest} -> {s, rest}
      {:headers, _}, acc -> acc
      {:data, d}, {200, rest} ->
        # Keep chunks on whole samples.
        bin = rest <> d
        n = byte_size(bin) - rem(byte_size(bin), 2)
        if n > 0, do: sink.(binary_part(bin, 0, n))
        {200, binary_part(bin, n, byte_size(bin) - n)}
      {:data, d}, {s, rest} -> {s, rest <> d}
      _, acc -> acc
    end, receive_timeout: 120_000)
    |> case do
      {:ok, {200, _}} -> :ok
      {:ok, {s, err}} -> {:error, "gw #{s}: #{String.slice(err, 0, 200)}"}
      {:error, e, _} -> {:error, inspect(e)}
      {:error, e} -> {:error, inspect(e)}
    end
  end
end
