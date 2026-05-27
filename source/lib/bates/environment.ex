defmodule Bates.Environment do
  @moduledoc """
  User-supplied environment variables: substitution against an existing
  env map and a final merge that does not override existing keys.

  Substitution recognises `$NAME` and `${NAME}`. The escape `$$` becomes a
  literal `$`. Unknown references raise.
  """

  @type env :: %{String.t() => String.t()}
  @type token :: {:literal, String.t()} | {:ref, String.t()}

  @doc """
  Returns `env` with `user_env`'s values substituted against `env` and
  merged in. Existing keys win on conflict.

  Raises `ArgumentError` if a value references an unknown variable.
  """
  @spec apply(env, env, String.t()) :: env
  def apply(env, user_env, service_name)
      when is_map(env) and is_map(user_env) and is_binary(service_name) do
    Enum.reduce(user_env, env, fn {key, raw}, acc ->
      tokens = tokenize!(raw, service_name, key)
      resolved = render(tokens, env, service_name, key)
      Map.put_new(acc, key, resolved)
    end)
  end

  @doc """
  Validates that `value` parses as a well-formed substitution string.
  Returns `:ok` or `{:error, :malformed}`.
  """
  @spec validate(String.t()) :: :ok | {:error, :malformed}
  def validate(value) when is_binary(value) do
    case tokenize(value) do
      {:ok, _tokens} -> :ok
      :error -> {:error, :malformed}
    end
  end

  defp tokenize!(value, service, key) do
    case tokenize(value) do
      {:ok, tokens} ->
        tokens

      :error ->
        raise ArgumentError,
              ~s|service "#{service}" environment variable "#{key}" has a malformed reference|
    end
  end

  defp tokenize(value), do: tokenize(value, [])

  defp tokenize("", acc), do: {:ok, Enum.reverse(acc)}

  defp tokenize("$$" <> rest, acc) do
    tokenize(rest, [{:literal, "$"} | acc])
  end

  defp tokenize("${" <> rest, acc) do
    case split_braced(rest) do
      {:ok, name, tail} -> tokenize(tail, [{:ref, name} | acc])
      :error -> :error
    end
  end

  defp tokenize("$" <> rest, acc) do
    case split_bare(rest) do
      {:ok, name, tail} -> tokenize(tail, [{:ref, name} | acc])
      :error -> :error
    end
  end

  defp tokenize(<<char::utf8, rest::binary>>, acc) do
    tokenize(rest, [{:literal, <<char::utf8>>} | acc])
  end

  defp split_braced(rest) do
    case Regex.run(~r/^([A-Za-z_][A-Za-z0-9_]*)\}(.*)$/s, rest,
           capture: :all_but_first
         ) do
      [name, tail] -> {:ok, name, tail}
      _ -> :error
    end
  end

  defp split_bare(rest) do
    case Regex.run(~r/^([A-Za-z_][A-Za-z0-9_]*)(.*)$/s, rest,
           capture: :all_but_first
         ) do
      [name, tail] -> {:ok, name, tail}
      _ -> :error
    end
  end

  defp render(tokens, env, service, key) do
    tokens
    |> Enum.map(fn
      {:literal, chunk} -> chunk
      {:ref, name} -> lookup!(env, name, service, key)
    end)
    |> IO.iodata_to_binary()
  end

  defp lookup!(env, name, service, key) do
    case Map.fetch(env, name) do
      {:ok, value} ->
        value

      :error ->
        raise ArgumentError,
              ~s|service "#{service}" environment variable "#{key}" references unknown variable "#{name}"|
    end
  end
end
