defmodule Conjure.Daemon do
  use Agent

  @port 4200

  def start_link(opts) do
    Agent.start_link(fn -> @port end, opts)
  end

  def next_port(agent \\ __MODULE__) do
    Agent.get_and_update(agent, fn state -> { state, state + 1 } end)
  end
end
