defmodule Air.MixProject do
  use Mix.Project

  def project do
    [
      app: :air,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [air: [include_executables_for: [:unix]]]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto], mod: {Air.Application, []}]
  end

  defp deps do
    [
      {:bandit, "~> 1.6"},
      {:plug, "~> 1.16"},
      {:websock_adapter, "~> 0.5"},
      {:finch, "~> 0.19"},
      {:mint_web_socket, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:aws_signature, "~> 0.3"}
    ]
  end
end
