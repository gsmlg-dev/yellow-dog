defmodule YellowDog.Resolved.Test.FakeUpstream do
  @moduledoc """
  A fake UDP DNS upstream server for integration testing.

  Listens on an ephemeral port and responds to DNS queries with valid
  DNS response binaries. Supports configurable response behavior:
  - `:echo` — return a valid DNS response for any query (NOERROR, with A record)
  - `:nxdomain` — return NXDOMAIN for any query
  - `:servfail` — return SERVFAIL for any query
  - `:timeout` — silently drop packets (simulates unreachable upstream)
  - `{:edns_yellowdog, ws_port, ws_path}` — respond with EDNS 65321 + SRV for discovery
  """

  use GenServer

  defstruct [:socket, :port, :mode]

  @doc "Start a fake upstream on an ephemeral port. Returns `{:ok, pid, port}`."
  def start(mode \\ :echo) do
    {:ok, pid} = GenServer.start(__MODULE__, mode)
    port = GenServer.call(pid, :get_port)
    {:ok, pid, port}
  end

  @doc "Stop the fake upstream."
  def stop(pid), do: GenServer.stop(pid)

  # GenServer callbacks

  @impl true
  def init(mode) do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: true, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    {:ok, %__MODULE__{socket: socket, port: port, mode: mode}}
  end

  @impl true
  def handle_call(:get_port, _from, state) do
    {:reply, state.port, state}
  end

  @impl true
  def handle_info({:udp, _socket, _client_ip, _client_port, _data}, %{mode: :timeout} = state) do
    # Silently drop the packet — simulates an unreachable upstream
    {:noreply, state}
  end

  def handle_info({:udp, _socket, client_ip, client_port, data}, state) do
    response = build_response(data, state.mode)
    :gen_udp.send(state.socket, client_ip, client_port, response)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :gen_udp.close(state.socket)
    :ok
  end

  # Build a DNS response based on the mode

  defp build_response(query_binary, :echo) do
    # Parse query to get txn_id and question
    query = DNS.Message.from_iodata(query_binary)
    question = List.first(query.qdlist)

    response =
      query
      |> DNS.Message.update_header_attr(:qr, 1)
      |> DNS.Message.update_header_attr(:aa, 0)
      |> DNS.Message.update_header_attr(:rd, 1)
      |> DNS.Message.update_header_attr(:ra, 1)
      |> DNS.Message.update_header_attr(:rcode, DNS.Message.RCode.new(0))

    response =
      if question do
        # Add a fake A record answer with 60s TTL
        record = DNS.Message.Record.new(to_string(question.name), 1, 1, 60, {93, 184, 216, 34})

        response
        |> Map.put(:anlist, [record])
        |> DNS.Message.update_header_attr(:ancount, 1)
      else
        response
      end

    DNS.to_iodata(response) |> IO.iodata_to_binary()
  end

  defp build_response(query_binary, :nxdomain) do
    query = DNS.Message.from_iodata(query_binary)

    response =
      query
      |> DNS.Message.update_header_attr(:qr, 1)
      |> DNS.Message.update_header_attr(:aa, 0)
      |> DNS.Message.update_header_attr(:rd, 1)
      |> DNS.Message.update_header_attr(:ra, 1)
      |> DNS.Message.update_header_attr(:rcode, DNS.Message.RCode.nx_domain())
      |> Map.put(:anlist, [])
      |> DNS.Message.update_header_attr(:ancount, 0)

    DNS.to_iodata(response) |> IO.iodata_to_binary()
  end

  defp build_response(query_binary, :servfail) do
    query = DNS.Message.from_iodata(query_binary)

    response =
      query
      |> DNS.Message.update_header_attr(:qr, 1)
      |> DNS.Message.update_header_attr(:aa, 0)
      |> DNS.Message.update_header_attr(:rd, 1)
      |> DNS.Message.update_header_attr(:ra, 1)
      |> DNS.Message.update_header_attr(:rcode, DNS.Message.RCode.new(2))
      |> Map.put(:anlist, [])
      |> DNS.Message.update_header_attr(:ancount, 0)

    DNS.to_iodata(response) |> IO.iodata_to_binary()
  end

  defp build_response(query_binary, {:edns_yellowdog, ws_port, ws_path}) do
    query = DNS.Message.from_iodata(query_binary)

    response =
      query
      |> DNS.Message.update_header_attr(:qr, 1)
      |> DNS.Message.update_header_attr(:aa, 1)
      |> DNS.Message.update_header_attr(:rd, 1)
      |> DNS.Message.update_header_attr(:ra, 1)
      |> DNS.Message.update_header_attr(:rcode, DNS.Message.RCode.new(0))

    # SRV record: {priority, weight, port, target}
    srv_record =
      DNS.Message.Record.new(
        "_yellowdog._tcp.local",
        33,
        1,
        60,
        {10, 0, ws_port, "127.0.0.1"}
      )

    # OPT record with EDNS option 65321 (version 1 + ws_path)
    edns_data = <<1::8, ws_path::binary>>
    opt_record = DNS.Message.Record.new(".", 41, 4096, 0, edns_data)

    response =
      response
      |> Map.put(:anlist, [srv_record])
      |> DNS.Message.update_header_attr(:ancount, 1)
      |> Map.update(:arlist, [opt_record], &[opt_record | &1])
      |> DNS.Message.update_header_attr(:arcount, 1)

    DNS.to_iodata(response) |> IO.iodata_to_binary()
  end
end
