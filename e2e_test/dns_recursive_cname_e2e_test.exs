defmodule E2ETest.DnsRecursiveCnameE2ETest do
  @moduledoc """
  End-to-end tests for recursive completion of authoritative CNAME answers.
  """

  use ExUnit.Case, async: false

  alias E2ETest.DnsClient
  alias E2ETest.ServiceHelper
  alias YellowDog.Dns.{View, ViewManager, Zone, ZoneController}

  alias DNS.Message
  alias DNS.Message.Record
  alias DNS.Message.RCode

  @moduletag :e2e
  @moduletag :dns

  @host {127, 0, 0, 1}
  @target_name "target.external.test"
  @target_ip {203, 0, 113, 55}

  setup do
    {:ok, upstream_socket} = Abyss.Transport.UDP.listen(0, ip: @host, active: false)
    {:ok, {_bound_ip, upstream_port}} = Abyss.Transport.UDP.sockname(upstream_socket)

    views = [
      %{
        name: "recursive-cname",
        priority: 1,
        acl: :any,
        zones: [],
        rpz_zones: [],
        recursion_enabled: false,
        fallback_forwarders: [{@host, upstream_port}],
        fallback_timeout: 500,
        fallback_retries: 1,
        ecs_enabled: false
      }
    ]

    case ServiceHelper.start_dns_system(listen: @host, views: views) do
      {:ok, ctx} ->
        on_exit(fn ->
          Abyss.Transport.UDP.close(upstream_socket)
          ServiceHelper.stop_dns_system(ctx)
        end)

        {:ok, view_pid} = ViewManager.get_view("recursive-cname")

        {:ok, zone_pid} =
          ZoneController.start_zone(:auth, "recursive-cname.test", view_name: "recursive-cname")

        :ok = View.register_zone(view_pid, :auth, "recursive-cname.test")

        :ok =
          Zone.Auth.add_record(
            zone_pid,
            Record.new("disabled.recursive-cname.test", :cname, :in, 300, @target_name)
          )

        :ok =
          Zone.Auth.add_record(
            zone_pid,
            Record.new("enabled.recursive-cname.test", :cname, :in, 300, @target_name)
          )

        {:ok, Map.merge(ctx, %{upstream_socket: upstream_socket, view_pid: view_pid})}

      {:error, reason} ->
        Abyss.Transport.UDP.close(upstream_socket)
        raise "Failed to start DNS system: #{inspect(reason)}"
    end
  end

  test "recursive view setting controls whether auth-zone CNAME answers include target records",
       ctx do
    assert {:ok, disabled_response} =
             DnsClient.query_a(
               ctx.host,
               ctx.port,
               "disabled.recursive-cname.test",
               timeout: 3_000
             )

    assert DnsClient.get_rcode(disabled_response) == :NOERROR

    assert [{"CNAME", "disabled.recursive-cname.test", @target_name}] =
             answer_summary(disabled_response)

    assert disabled_response.header.ra == 0

    upstream_task = Task.async(fn -> answer_one_upstream_query(ctx.upstream_socket) end)

    :ok = View.reload(ctx.view_pid, %{recursion_enabled: true})

    assert {:ok, enabled_response} =
             DnsClient.query_a(
               ctx.host,
               ctx.port,
               "enabled.recursive-cname.test",
               timeout: 3_000
             )

    assert %{name: @target_name, type: "A"} = Task.await(upstream_task, 1_000)
    assert DnsClient.get_rcode(enabled_response) == :NOERROR
    assert enabled_response.header.ra == 1

    enabled_answers = answer_summary(enabled_response)
    assert length(enabled_answers) == 2
    assert {"CNAME", "enabled.recursive-cname.test", @target_name} in enabled_answers
    assert {"A", @target_name, @target_ip} in enabled_answers
  end

  defp answer_one_upstream_query(socket) do
    assert {:ok, {client_ip, client_port, data}} = Abyss.Transport.UDP.recv(socket, 0, 1_000)

    query = Message.from_iodata(data)
    query_name = query_name(query)
    query_type = query_type(query)

    response =
      build_response(query, [
        Record.new(query_name, :a, :in, 60, @target_ip)
      ])

    :ok = Abyss.Transport.UDP.send(socket, client_ip, client_port, DNS.to_iodata(response))

    %{name: query_name, type: query_type}
  end

  defp build_response(query, answers) do
    %{
      query
      | header: %{
          query.header
          | qr: 1,
            aa: 0,
            ra: 1,
            rcode: RCode.new(0),
            ancount: length(answers),
            nscount: 0,
            arcount: 0
        },
        anlist: answers,
        nslist: [],
        arlist: []
    }
  end

  defp answer_summary(response) do
    response
    |> DnsClient.get_answers()
    |> Enum.map(fn record ->
      {record_type(record), normalize_name(record.name), normalize_data(record.data)}
    end)
  end

  defp query_name(%Message{qdlist: [question | _]}), do: normalize_name(question.name)
  defp query_type(%Message{qdlist: [question | _]}), do: record_type(question)

  defp record_type(%{type: type}), do: type |> to_string() |> String.upcase()

  defp normalize_data(data) when is_tuple(data), do: data

  defp normalize_data(data) do
    value = to_string(data)

    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, ip} -> ip
      {:error, _reason} -> normalize_name(value)
    end
  end

  defp normalize_name(name) do
    name
    |> to_string()
    |> String.downcase()
    |> String.trim_trailing(".")
  end
end
