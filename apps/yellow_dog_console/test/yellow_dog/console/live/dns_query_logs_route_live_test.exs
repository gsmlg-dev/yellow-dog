defmodule YellowDog.Console.DnsQueryLogsRouteLiveTest do
  use YellowDog.Console.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias YellowDog.Dns.QueryLogger

  setup do
    {logger_pid, stop_logger?} =
      case Process.whereis(QueryLogger) do
        nil ->
          {:ok, pid} = QueryLogger.start_link(name: QueryLogger, buffer_size: 10)
          {pid, true}

        pid ->
          QueryLogger.clear_buffer()
          {pid, false}
      end

    on_exit(fn ->
      if stop_logger? do
        if Process.alive?(logger_pid), do: GenServer.stop(logger_pid)
      else
        QueryLogger.clear_buffer()
      end
    end)

    :ok
  end

  test "shows DNS query route type and matched zone on the system logs route", %{conn: conn} do
    QueryLogger.log_query(%{
      client_ip: {10, 0, 0, 10},
      view: "default",
      qname: "www.example.com",
      qtype: :a,
      protocol: :udp,
      response_code: :noerror,
      resolution_type: :auth,
      zone_used: "example.com"
    })

    QueryLogger.log_query(%{
      client_ip: {10, 0, 0, 11},
      view: "default",
      qname: "www.external.test",
      qtype: :aaaa,
      protocol: :udp,
      response_code: :noerror,
      resolution_type: :recursive,
      zone_used: "."
    })

    Process.sleep(20)

    {:ok, _view, html} = live(conn, "/system/logs/dns-query")

    assert html =~ "QType"
    assert html =~ "Type"
    assert html =~ "Zone"
    assert html =~ "Auth"
    assert html =~ "Recursive"
    assert html =~ "example.com"
    assert html =~ "www.external.test"
  end
end
