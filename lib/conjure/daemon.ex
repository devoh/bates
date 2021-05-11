defmodule Conjure.Daemon do
  use GenServer

  @port 4200

  # public API

  def start_link(_) do
    GenServer.start_link(__MODULE__, @port, name: __MODULE__)
  end

  def next_port(server \\ __MODULE__) do
    GenServer.call(server, :next_port)
  end

  # callbacks

  @impl GenServer
  def init(port) do
    {:ok, %{port: port}}
  end

  @impl GenServer
  def handle_call(:next_port, _from, %{port: port} = state) do
    {:reply, port, %{state | port: port + 1}}
  end
end
