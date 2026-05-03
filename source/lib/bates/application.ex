defmodule Bates.Application do
  use Application

  alias Bates.Daemon

  def start(_type, _args) do
    boot_daemon()

    opts = [strategy: :one_for_one, name: Bates.Supervisor]
    Supervisor.start_link(children(), opts)
  end

  # When `:bates, :skip_prereq_check` is `true` (the default in
  # `config/test.exs`) skip both argv parsing and the prereq check.
  # `mix test` invokes `start/2` with `System.argv() == ["test"]`, which
  # the daemon parser would reject as a stray positional argument.
  defp boot_daemon do
    if Application.get_env(:bates, :skip_prereq_check, false) do
      :ok
    else
      with {:ok, opts} <- Daemon.parse_argv(System.argv()),
           :ok <- Daemon.apply_options(opts),
           :ok <- Daemon.apply_env(),
           :ok <- Daemon.verify_prerequisites() do
        :ok
      else
        {:error, message} ->
          IO.write(:stderr, message)
          System.halt(2)
      end
    end
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
