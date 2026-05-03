defmodule Bates.Daemon do
  @moduledoc """
  Boot helpers for the `batesd` Mix release.

  `Bates.Application.start/2` calls these helpers to parse `System.argv()`
  and verify system prerequisites before bringing up the supervision tree.
  Each helper is pure (returns a tagged tuple) so it can be unit-tested
  without trapping `System.halt/1`.
  """

  @usage "Usage: batesd [--config <path>]\n"

  @doc """
  Parses `argv` and returns the parsed options.

  Recognizes `--config <path>`. On any unknown switch or unexpected
  positional argument, returns `{:error, message}` where `message` is a
  diagnostic followed by the usage banner.
  """
  def parse_argv(argv) when is_list(argv) do
    case OptionParser.parse(argv, strict: [config: :string]) do
      {opts, [], []} ->
        {:ok, opts}

      {_opts, [extra | _], _} ->
        {:error, "batesd: unexpected argument: #{extra}\n" <> @usage}

      {_opts, _argv, [{switch, _} | _]} ->
        {:error, "batesd: unknown option: #{switch}\n" <> @usage}
    end
  end

  @doc """
  Applies parsed daemon options to the application environment.

  Today only `--config` is honored; the parsed value is expanded and
  stored under `:bates, :config_path` so `Bates.Config.path/0` picks
  it up.
  """
  def apply_options(opts) when is_list(opts) do
    if path = opts[:config] do
      Application.put_env(:bates, :config_path, Path.expand(path))
    end

    :ok
  end

  @doc """
  Runs `Bates.Prerequisites.verify/0` and formats any failure for stderr.

  Returns `:ok` if every prereq passes. Returns `{:error, message}` with
  the same diagnostic the old `bates start` emitted when a check fails.
  """
  def verify_prerequisites do
    case Bates.Prerequisites.verify() do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         """
         bates: prerequisite not met: #{reason}
         Run `bates setup` to configure system prerequisites.
         """}
    end
  end
end
