defmodule Air.AWS do
  @moduledoc "SigV4 with the instance role's credentials from IMDS (the same code as infer-gw's Gw.EC2)."
  @imds "http://169.254.169.254"

  def sign(service, region, method, url, headers, body) do
    %{"AccessKeyId" => ak, "SecretAccessKey" => sk, "Token" => token} = creds()
    headers = [{"host", URI.parse(url).host}, {"x-amz-security-token", token} | headers]
    :aws_signature.sign_v4(ak, sk, region, service, :calendar.universal_time(), method, url, headers, body)
  end

  # Cached until 5 minutes before they expire.
  defp creds do
    now = System.system_time(:second)

    case :persistent_term.get({__MODULE__, :creds}, nil) do
      {exp, c} when exp - 300 > now -> c
      _ ->
        t = imds(:put, "/latest/api/token", [{"x-aws-ec2-metadata-token-ttl-seconds", "300"}])
        h = [{"x-aws-ec2-metadata-token", t}]
        role = imds(:get, "/latest/meta-data/iam/security-credentials/", h) |> String.trim()
        c = imds(:get, "/latest/meta-data/iam/security-credentials/" <> role, h) |> Jason.decode!()
        {:ok, exp, _} = DateTime.from_iso8601(c["Expiration"])
        :persistent_term.put({__MODULE__, :creds}, {DateTime.to_unix(exp), c})
        c
    end
  end

  defp imds(method, path, headers) do
    {:ok, %{status: 200, body: b}} = Finch.build(method, @imds <> path, headers) |> Finch.request(Air.Finch, receive_timeout: 2_000)
    b
  end
end
