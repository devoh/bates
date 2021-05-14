defmodule Conjure.Application do
  use Application

  def start(_type, _args) do
    opts = [strategy: :one_for_one, name: Conjure.Supervisor]
    Supervisor.start_link(children(), opts)
  end

  defp children do
    [
      {Registry, keys: :unique, name: Conjure.ProcessRegistry},
      {Conjure.PortNumber, name: Conjure.PortNumber},
      Conjure.IPCServer,
      Conjure.ProcessSupervisor,
      Conjure.Proxy
    ]
  end
end
