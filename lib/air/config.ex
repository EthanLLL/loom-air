defmodule Air.Config do
  @moduledoc """
  Files under the data directory, read on every use (they are tiny), so an edit needs no restart.

    tenants.json   name → %{loom_url, loom_token, voice, temperature, persona, keywords, user}
    ringback.wav   what the phone plays while it rings (24 kHz s16le mono); its length is the ring timeout
    clips/<voice>/no_answer.wav   the "nobody answers" announcement, in the voice
    usage.jsonl    one line per model call
  """
  def data, do: Application.fetch_env!(:air, :data)
  def get(key), do: Application.fetch_env!(:air, key)

  def tenants, do: data() |> Path.join("tenants.json") |> File.read!() |> Jason.decode!()

  def tenant(name) do
    case tenants() do
      %{^name => t} -> {:ok, Map.put(t, "name", name)}
      _ -> :error
    end
  end

  def default_tenant, do: tenants() |> Map.keys() |> Enum.sort() |> hd()

  def ringback_path, do: Path.join(data(), "ringback.wav")

  @doc "How long the ringback lasts, in ms: 24 kHz s16le mono after a 44-byte header."
  def ringback_ms do
    case File.stat(ringback_path()) do
      {:ok, %{size: size}} -> div((size - 44) * 1000, 48_000)
      _ -> 60_000
    end
  end

  def clip_path(voice, name), do: Path.join([data(), "clips", voice, name <> ".wav"])

  def log_usage(entry) do
    line = Jason.encode!(Map.put(entry, :at, DateTime.utc_now() |> DateTime.to_iso8601())) <> "\n"
    File.write!(Path.join(data(), "usage.jsonl"), line, [:append])
  end
end
