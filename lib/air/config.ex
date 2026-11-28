defmodule Air.Config do
  @moduledoc """
  Files under the data directory, read on every use (they are tiny), so an edit needs no restart.

    tenants/<host>.json   one per Loom (0600): %{loom_url, loom_token, voice, temperature, persona, keywords,
                          user, operator_name}. The file's name is the address its users sign in to their Loom
                          at (`loom.example.com`, or `host:port` off the default port), and the tenant's id:
                          its calls and memory go under that name too.
    ringback.wav   what the phone plays while it rings (24 kHz s16le mono); its length is the ring timeout
    clips/<voice>/no_answer.wav   the "nobody answers" announcement, in the voice
    usage.jsonl    one line per model call
  """
  def data, do: Application.fetch_env!(:air, :data)
  def get(key), do: Application.fetch_env!(:air, key)

  @doc "The tenants' ids."
  def tenants do
    case File.ls(Path.join(data(), "tenants")) do
      {:ok, files} -> for f <- Enum.sort(files), String.ends_with?(f, ".json"), do: String.trim_trailing(f, ".json")
      _ -> []
    end
  end

  @doc "`{:ok, tenant}` (with its id as `\"name\"`) or `:error`."
  def tenant(id) when is_binary(id) do
    with true <- Regex.match?(~r/^[a-z0-9][a-z0-9.-]*(:\d+)?$/, id),
         {:ok, s} <- File.read(Path.join([data(), "tenants", id <> ".json"])) do
      {:ok, s |> Jason.decode!() |> Map.put("name", id)}
    else
      _ -> :error
    end
  end

  def tenant(_), do: :error

  def default_tenant, do: List.first(tenants())

  def ringback_path, do: Path.join(data(), "ringback.wav")

  @doc """
  The ringback's version, which apps keep it on disk by (in `/me`, and the file's ETag): the start of its SHA-256,
  hashed again only when the file's size or time changes. nil without a ringback.
  """
  def ringback_version do
    path = ringback_path()

    with {:ok, %{size: size, mtime: mtime}} <- File.stat(path, time: :posix) do
      key = {__MODULE__, :ringback_version}

      case :persistent_term.get(key, nil) do
        {^size, ^mtime, version} ->
          version

        _ ->
          hash =
            File.stream!(path, 65_536)
            |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))

          version = :crypto.hash_final(hash) |> Base.encode16(case: :lower) |> binary_part(0, 16)
          :persistent_term.put(key, {size, mtime, version})
          version
      end
    else
      _ -> nil
    end
  end

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
