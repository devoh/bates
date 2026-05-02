defmodule Bates.PrerequisitesTest do
  use ExUnit.Case, async: false

  alias Bates.Prerequisites

  describe "verify/0" do
    test "fails with a caddy-not-found message when `caddy` is not in $PATH" do
      original_path = System.get_env("PATH")
      System.put_env("PATH", "")

      try do
        assert {:error, message} = Prerequisites.verify()
        assert message =~ "`caddy` not found"
      after
        if original_path do
          System.put_env("PATH", original_path)
        else
          System.delete_env("PATH")
        end
      end
    end

    test "returns :ok when both checks pass on a normally-configured system" do
      # Skip when caddy is not actually installed locally, since we
      # can't fake `System.find_executable`.
      cond do
        System.find_executable("caddy") == nil ->
          # Run the negative path instead.
          assert {:error, message} = Prerequisites.verify()
          assert message =~ "`caddy` not found"

        not File.exists?("/etc/resolver/test") ->
          assert Prerequisites.verify() ==
                   {:error,
                    "/etc/resolver/test not found. Run `bates setup` to create it."}

        true ->
          assert Prerequisites.verify() == :ok
      end
    end
  end
end
