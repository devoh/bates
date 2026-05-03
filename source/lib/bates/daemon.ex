defmodule Bates.Daemon do
  @moduledoc """
  Boot helpers for the `batesd` Mix release.

  `Bates.Application.start/2` calls these helpers to parse the daemon's
  inputs and verify system prerequisites before bringing up the
  supervision tree. Each helper is pure (returns a tagged tuple) so it
  can be unit-tested without trapping `System.halt/1`.

  Two input paths feed `:bates, :config_path`:

    * `mix phx.server` (and any other dev/release entry point that
      exposes argv) goes through `parse_argv/1` + `apply_options/1`.
    * The `bin/batesd` Mix-release wrapper parses argv in shell and
      sets the `BATES_CONFIG_PATH` environment variable, which
      `apply_env/1` picks up. (The mix-release `start` subcommand
      discards extra argv, so the wrapper translates the only flag we
      accept into env.)

  When both are set the env var wins (the wrapper sets it
  deliberately).
  """

  @env_config_path "BATES_CONFIG_PATH"
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
  Applies daemon options sourced from the environment.

  Reads `BATES_CONFIG_PATH` (set by the `bin/batesd` wrapper) and
  stores it under `:bates, :config_path`, overriding anything
  `apply_options/1` previously set. The argv path stays useful for
  `mix phx.server`; the env path covers the Mix release.
  """
  def apply_env(env \\ System.get_env()) when is_map(env) do
    case Map.get(env, @env_config_path) do
      nil ->
        :ok

      "" ->
        :ok

      path ->
        Application.put_env(:bates, :config_path, Path.expand(path))
        :ok
    end
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
