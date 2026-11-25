defmodule Air.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Finch, name: Air.Finch, pools: %{default: [size: 20]}},
      {Registry, keys: :unique, name: Air.Registry},
      {DynamicSupervisor, name: Air.Sup, strategy: :one_for_one},
      {Task.Supervisor, name: Air.Tasks},
      {Bandit, plug: Air.Web.Router, ip: {127, 0, 0, 1}, port: Application.fetch_env!(:air, :port)}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Air.Supervisor)
  end
end
