defmodule Conjure.DaemonTest do
  use ExUnit.Case, async: true

  setup do
    daemon = start_supervised!(Conjure.Daemon)
    %{daemon: daemon}
  end

  test "next port", %{daemon: daemon} do
    assert Conjure.Daemon.next_port(daemon) == 4200
    assert Conjure.Daemon.next_port(daemon) == 4201
    assert Conjure.Daemon.next_port(daemon) == 4202
  end
end
