defmodule Conjure.ProcessReadinessTest do
  use ExUnit.Case

  setup do
    Phoenix.PubSub.subscribe(Conjure.PubSub, "process:testapp")
    :ok
  end

  test "status is 'starting' immediately after up/1" do
    process = %Conjure.Process{
      name: "testapp",
      command: "sleep 999",
      root: ".",
      port: 19876
    }

    start_supervised!({Conjure.Process, process})
    :ok = Conjure.Process.up("testapp")

    assert Conjure.Process.status("testapp") == "starting"
    assert_received {:status, "starting"}
  end

  test "transitions to 'up' when port is listening" do
    process = %Conjure.Process{
      name: "testapp",
      command: "elixir test/support/test_server.ex",
      root: "."
    }

    start_supervised!({Conjure.Process, process})
    :ok = Conjure.Process.up("testapp")

    assert_received {:status, "starting"}
    assert_receive {:status, "up"}, 10_000

    assert Conjure.Process.status("testapp") == "up"
  end

  test "transitions to 'crashed' on readiness timeout" do
    # Use a port that nothing will listen on
    process = %Conjure.Process{
      name: "testapp",
      command: "sleep 999",
      root: ".",
      port: 19877
    }

    start_supervised!({Conjure.Process, process})
    :ok = Conjure.Process.up("testapp")

    assert_received {:status, "starting"}

    # Test config sets readiness_timeout to 2_000ms
    assert_receive {:status, "crashed", message}, 5_000
    assert message =~ "Timed out waiting for port"
  end

  test "down works while in 'starting' state" do
    process = %Conjure.Process{
      name: "testapp",
      command: "sleep 999",
      root: ".",
      port: 19878
    }

    start_supervised!({Conjure.Process, process})
    :ok = Conjure.Process.up("testapp")

    assert Conjure.Process.status("testapp") == "starting"

    :ok = Conjure.Process.down("testapp")

    assert_received {:status, "starting"}
    assert_received {:status, "down"}
    assert Conjure.Process.status("testapp") == "down"
  end

  test "PubSub broadcasts fire for each transition" do
    process = %Conjure.Process{
      name: "testapp",
      command: "elixir test/support/test_server.ex",
      root: "."
    }

    start_supervised!({Conjure.Process, process})
    :ok = Conjure.Process.up("testapp")

    assert_receive {:status, "starting"}, 1_000
    assert_receive {:status, "up"}, 10_000
  end
end
