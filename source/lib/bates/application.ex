defmodule Bates.Application do
  use Application

  def start(_type, _args) do
    opts = [strategy: :one_for_one, name: Bates.Supervisor]
    Supervisor.start_link(children(), opts)
  end

  defp children do
    [
      {Registry, keys: :unique, name: Bates.ProcessRegistry},
      {Phoenix.PubSub, name: Bates.PubSub},
      Bates.ProcessSupervisor,
      BatesWeb.Endpoint,
      Bates.Caddy
    ]
  end
end
