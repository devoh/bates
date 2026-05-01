defmodule Bates.CLI.EnvTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Bates.CLI.Env

  describe "format_export/2" do
    test "wraps a string value in single quotes" do
      assert Env.format_export("PGHOST", "127.0.0.1") ==
               "export PGHOST='127.0.0.1'"
    end

    test "escapes embedded single quotes with the POSIX dance" do
      assert Env.format_export("MSG", "it's") ==
               "export MSG='it'\\''s'"
    end

    test "stringifies non-string values" do
      assert Env.format_export("PGPORT", 52345) ==
               "export PGPORT='52345'"
    end
  end

  describe "escape/1" do
    test "leaves values without single quotes alone" do
      assert Env.escape("plain value") == "plain value"
    end

    test "escapes single quotes with the close-escape-open dance" do
      assert Env.escape("it's") == "it'\\''s"
    end

    test "escapes multiple single quotes" do
      assert Env.escape("a'b'c") == "a'\\''b'\\''c"
    end
  end

  describe "emit_exports/1" do
    test "writes one export line per key in sorted order" do
      output =
        capture_io(fn ->
          Env.emit_exports(%{"PGPORT" => "52345", "PGHOST" => "127.0.0.1"})
        end)

      assert output ==
               "export PGHOST='127.0.0.1'\nexport PGPORT='52345'\n"
    end

    test "writes nothing for an empty map" do
      output = capture_io(fn -> Env.emit_exports(%{}) end)
      assert output == ""
    end
  end
end
