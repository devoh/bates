defmodule Conjure.DNSServer do
  use GenServer

  @port 42_000

  # public API

  def start_link(_, opts \\ [name: __MODULE__]) do
    GenServer.start_link(__MODULE__, @port, opts)
  end

  # callbacks

  @impl GenServer
  def init(port) do
    case :gen_udp.open(port, [:binary, active: false]) do
      {:ok, socket} ->
        {:ok, socket, {:continue, :receive}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_continue(:receive, socket) do
    :inet.setopts(socket, active: :once)
    {:noreply, socket}
  end

  @impl GenServer
  def handle_info({:udp, socket, ip, port, data}, _socket) do
    response = handle(data)
    :gen_udp.send(socket, ip, port, DNS.Record.encode(response))
    {:noreply, socket, {:continue, :receive}}
  end

  defp handle(data) do
    with {:ok, record} <- :inet_dns.decode(data),
         %DNS.Record{} = record <- DNS.Record.from_record(record),
         %DNS.Query{} = query <- hd(record.qdlist) do
      result =
        case query.type do
          :a ->
            if known?(query.domain), do: {127, 0, 0, 1}

          _ ->
            nil
        end

      if result do
        resource = %DNS.Resource{
          domain: query.domain,
          class: query.class,
          type: query.type,
          ttl: 0,
          data: result
        }

        %{record | anlist: [resource], header: %{record.header | qr: true}}
      else
        %{record | header: %{record.header | qr: true}}
      end
    end
  end

  def known?(domain) do
    Conjure.ProcessSupervisor.hostnames()
    |> Enum.member?(to_string(domain))
  end
end
