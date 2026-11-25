defmodule Air.Config do
  @moduledoc """
  Files under the data directory, read on every use (they are tiny), so an edit needs no restart.

    tenants.json   name → %{loom_url, loom_token, voice, temperature, persona, keywords, user}
    clips/<voice>/clips.json   [%{name, text}], next to <name>.wav
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

  def clips(voice) do
    case File.read(Path.join([data(), "clips", voice, "clips.json"])) do
      {:ok, s} -> Jason.decode!(s)
      _ -> []
    end
  end

  def clip_path(voice, name), do: Path.join([data(), "clips", voice, name <> ".wav"])

  def log_usage(entry) do
    line = Jason.encode!(Map.put(entry, :at, DateTime.utc_now() |> DateTime.to_iso8601())) <> "\n"
    File.write!(Path.join(data(), "usage.jsonl"), line, [:append])
  end
end
