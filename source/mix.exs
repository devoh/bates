defmodule Bates.MixProject do
  use Mix.Project

  def project do
    [
      app: :bates,
      version: "0.1.0",
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: [main_module: Bates.CLI, name: "bates", app: nil],
      releases: releases()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :inets],
      mod: {Bates.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:bandit, "~> 1.0"},
      {:erlexec, "~> 2.3"},
      {:jason, "~> 1.2"},
      {:phoenix, "~> 1.7"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_pubsub, "~> 2.1"},
      {:toml, "~> 0.6"},
      {:bypass, "~> 2.1", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  defp releases do
    [
      batesd: [
        version: "0.1.0",
        applications: [bates: :permanent],
        include_executables_for: [:unix],
        # `mix release` generates `bin/batesd` as a multi-subcommand
        # dispatcher (`start`, `daemon`, `remote`, `eval`, ...). The
        # `&install_launcher/1` step renames it to `bin/batesd-orig`
        # and writes a thin wrapper at `bin/batesd` that always invokes
        # the foreground `start` subcommand. The user-facing surface is
        # `batesd [--config <path>]` — no subcommand.
        #
        # The wrapper is written directly here (rather than via a
        # `rel/overlays/` file) so we don't fight the overlay/launcher
        # ordering during `:assemble`.
        steps: [:assemble, &install_launcher/1]
      ]
    ]
  end

  defp install_launcher(release) do
    bin = Path.join(release.path, "bin")
    generated = Path.join(bin, "batesd")
    renamed = Path.join(bin, "batesd-orig")
    File.rename!(generated, renamed)

    wrapper = """
    #!/bin/sh
    # Thin wrapper installed by Bates' release `:steps` callback.
    # Always invokes the foreground `start` subcommand of the generated
    # mix-release launcher (`batesd-orig`). Users see a single command:
    # `batesd [--config <path>]`.
    exec "$(dirname "$0")/batesd-orig" start "$@"
    """

    File.write!(generated, wrapper)
    File.chmod!(generated, 0o755)

    release
  end
end
