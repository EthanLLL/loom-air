defmodule Air.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # The NAT drops a connection idle for 350 s without telling us; a reused dead one hangs until the
      # receive timeout. Close idle ones well before that.
      {Finch, name: Air.Finch, pools: %{default: [size: 20, conn_max_idle_time: 60_000]}},
      {Registry, keys: :unique, name: Air.Registry},
      {DynamicSupervisor, name: Air.Sup, strategy: :one_for_one},
      {Task.Supervisor, name: Air.Tasks},
      {Bandit, plug: Air.Web.Router, ip: {127, 0, 0, 1}, port: Application.fetch_env!(:air, :port)}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Air.Supervisor)
  end
end
