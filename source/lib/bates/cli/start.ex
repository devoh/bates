defmodule Bates.CLI.Start do
  @moduledoc false

  alias Bates.CLI.Client

  @usage "Usage: bates start [--config <path>]\n"

  def run(argv) when is_list(argv) do
    case parse(argv) do
      {:ok, opts} ->
        do_run(opts)

      {:error, message} ->
        IO.write(:stderr, message <> "\n" <> @usage)
        2
    end
  end

  defp parse(argv) do
    case OptionParser.parse(argv, strict: [config: :string]) do
      {opts, [], []} ->
        {:ok, opts}

      {_opts, [extra | _], _} ->
        {:error, "bates start: unexpected argument: #{extra}"}

      {_opts, _argv, [{switch, _} | _]} ->
        {:error, "bates start: unknown option: #{switch}"}
    end
  end

  defp do_run(opts) do
    if path = opts[:config] do
      Application.put_env(:bates, :config_path, Path.expand(path))
    end

    with :ok <- check_prerequisites(),
         :ok <- check_not_running(),
         :ok <- start_application() do
      block_forever()
    end
  end

  defp check_prerequisites do
    case Bates.Prerequisites.verify() do
      :ok ->
        :ok

      {:error, reason} ->
        IO.write(:stderr, """
        bates: prerequisite not met: #{reason}
        Run `bates setup` to configure system prerequisites.
        """)

        2
    end
  end

  defp check_not_running do
    case Client.get("/status", timeout: 500) do
      {:ok, status, _body} when status in 200..299 ->
        IO.write(:stderr, "Bates is already running.\n")
        1

      _ ->
        :ok
    end
  end

  defp start_application do
    case Application.ensure_all_started(:bates) do
      {:ok, _started} ->
        :ok

      {:error, {app, reason}} ->
        IO.write(
          :stderr,
          "bates: failed to start #{app}: #{inspect(reason)}\n"
        )

        1
    end
  end

  defp block_forever do
    Process.sleep(:infinity)
  end
end
