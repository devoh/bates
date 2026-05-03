defmodule Bates.CLI.Setup do
  @moduledoc """
  One-time system setup for `batesd`.

  Two steps, both idempotent:

    1. Create `/etc/resolver/test` with `nameserver 127.0.0.1` (sudo
       prompted).
    2. Run `caddy trust` to install Caddy's local CA root certificate.
  """

  @resolver_path "/etc/resolver/test"
  @resolver_content "nameserver 127.0.0.1"

  def run do
    with :ok <- ensure_resolver(),
         :ok <- ensure_trust() do
      IO.puts("bates setup: ready")
      :ok
    else
      {:error, exit_code} when is_integer(exit_code) -> exit_code
    end
  end

  @doc """
  Decides what action the resolver step should take given file contents.

  - `:missing` — file does not exist; should be created.
  - `String.trim(contents) == "nameserver 127.0.0.1"` — already
    configured; skip.
  - anything else — drift; surface a diagnostic.
  """
  def evaluate_resolver(:missing), do: {:create, :missing}

  def evaluate_resolver(contents) when is_binary(contents) do
    case String.trim(contents) do
      @resolver_content -> :ok
      other -> {:error, {:drift, other}}
    end
  end

  defp ensure_resolver do
    contents =
      case File.read(@resolver_path) do
        {:ok, body} -> body
        {:error, :enoent} -> :missing
      end

    case evaluate_resolver(contents) do
      :ok ->
        IO.puts("resolver: already configured")
        :ok

      {:create, :missing} ->
        create_resolver()

      {:error, {:drift, other}} ->
        IO.write(:stderr, """
        bates setup: #{@resolver_path} exists but does not match the
        expected content. Found:

          #{inspect(other)}

        Expected:

          #{@resolver_content}

        Edit the file by hand and re-run `bates setup`.
        """)

        {:error, 1}
    end
  end

  defp create_resolver do
    case System.cmd("sudo", ["tee", @resolver_path],
           input: @resolver_content <> "\n",
           stderr_to_stdout: false
         ) do
      {_output, 0} ->
        IO.puts("resolver: configured")
        :ok

      {_output, _code} ->
        print_manual_instructions()
        {:error, 2}
    end
  end

  defp ensure_trust do
    case System.cmd("caddy", ["trust"], stderr_to_stdout: false) do
      {_output, 0} ->
        IO.puts("trust: configured")
        :ok

      {output, _code} ->
        IO.write(:stderr, output)
        print_manual_instructions()
        {:error, 1}
    end
  rescue
    ErlangError ->
      IO.write(:stderr, "bates setup: `caddy` not found in $PATH\n")
      print_manual_instructions()
      {:error, 2}
  end

  defp print_manual_instructions do
    IO.write(:stderr, """

    Could not complete setup non-interactively. Run these manually:

      echo 'nameserver 127.0.0.1' | sudo tee /etc/resolver/test
      caddy trust

    """)
  end
end
