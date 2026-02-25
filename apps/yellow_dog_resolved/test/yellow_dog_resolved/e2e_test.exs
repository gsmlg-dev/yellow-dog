defmodule YellowDog.Resolved.E2ETest do
  @moduledoc """
  End-to-end test for the full resolved DNS pipeline via Abyss UDP listener.

  Starts the Listener (via Abyss) on an ephemeral port, sends real DNS
  queries over UDP, and verifies the responses. Tests the full path:
  UDP packet → Listener.handle_data → Router → Intercept/Cache/Forward → response.
  """
  use ExUnit.Case, async: false

  alias YellowDog.Resolved.{Cache, Config, Forwarder, Metrics}
  alias YellowDog.Resolved.Test.FakeUpstream

  @cache_config %{
    enabled: true,
    max_entries: 1000,
    min_ttl_s: 5,
    max_ttl_s: 3600,
    negative_ttl_s: 60,
    sweep_interval_s: 3600
  }

  describe "full UDP intercept path" do
    setup do
      config = %{
        listen: {127, 0, 0, 1},
        port: 0,
        upstreams: [{198, 51, 100, 1}],
        upstream_timeout_ms: 200,
        upstream_failure_threshold: 3,
        intercept_rules: [
          %{match: {:suffix, "local.dev"}, type: :a, value: "127.0.0.1", ttl: 300},
          %{match: {:exact, "myapp.test"}, type: :aaaa, value: "::1", ttl: 60}
        ],
        cache: @cache_config,
        discovery: %{
          enabled: false,
          websocket: %{heartbeat_interval_s: 30, reconnect_base_s: 5, reconnect_max_s: 60}
        },
        config_path: ""
      }

      start_supervised!({Config, config})
      start_supervised!({Cache, @cache_config})
      start_supervised!(Metrics)

      # Start the actual Abyss listener
      sup_pid = start_supervised!(YellowDog.Resolved.Listener.listener_spec(config))

      # Find the listener port by walking the supervision tree
      listener_port = find_abyss_listener_port(sup_pid)

      {:ok, client} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      on_exit(fn -> :gen_udp.close(client) end)

      {:ok, port: listener_port, client: client}
    end

    test "intercept responds to A query over UDP", ctx do
      query = build_query("app.local.dev", 1, 1001)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      :ok = :gen_udp.send(ctx.client, {127, 0, 0, 1}, ctx.port, raw)

      assert {:ok, {_ip, _port, response_binary}} =
               :gen_udp.recv(ctx.client, 0, 2000)

      response = DNS.Message.from_iodata(response_binary)
      assert response.header.qr == 1
      assert response.header.id == 1001
      assert response.header.aa == 1
      assert length(response.anlist) == 1
    end

    test "intercept responds to AAAA query over UDP", ctx do
      query = build_query("myapp.test", 28, 2002)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      :ok = :gen_udp.send(ctx.client, {127, 0, 0, 1}, ctx.port, raw)

      assert {:ok, {_ip, _port, response_binary}} =
               :gen_udp.recv(ctx.client, 0, 2000)

      response = DNS.Message.from_iodata(response_binary)
      assert response.header.qr == 1
      assert response.header.id == 2002
      assert length(response.anlist) == 1
    end

    test "FORMERR for garbage packet", ctx do
      # Send a short packet that's still at least 2 bytes for txn_id extraction
      :ok = :gen_udp.send(ctx.client, {127, 0, 0, 1}, ctx.port, <<0, 42, 0, 0>>)

      assert {:ok, {_ip, _port, response_binary}} =
               :gen_udp.recv(ctx.client, 0, 2000)

      response = DNS.Message.from_iodata(response_binary)
      assert response.header.qr == 1
      assert response.header.rcode == DNS.Message.RCode.form_err()
    end

    test "metrics counters increment from UDP queries", ctx do
      before = Metrics.get_query_counts()

      query = build_query("metrics.local.dev", 1, 3003)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      :ok = :gen_udp.send(ctx.client, {127, 0, 0, 1}, ctx.port, raw)
      assert {:ok, _} = :gen_udp.recv(ctx.client, 0, 2000)

      Process.sleep(50)

      after_counts = Metrics.get_query_counts()
      assert after_counts.total == before.total + 1
      assert after_counts.intercepted == before.intercepted + 1
    end
  end

  describe "full UDP forward path" do
    setup do
      {:ok, upstream_pid, upstream_port} = FakeUpstream.start(:echo)
      on_exit(fn -> FakeUpstream.stop(upstream_pid) end)

      config = %{
        listen: {127, 0, 0, 1},
        port: 0,
        upstreams: [{{127, 0, 0, 1}, upstream_port}],
        upstream_timeout_ms: 2000,
        upstream_failure_threshold: 3,
        intercept_rules: [
          %{match: {:suffix, "local.dev"}, type: :a, value: "127.0.0.1", ttl: 300}
        ],
        cache: @cache_config,
        discovery: %{
          enabled: false,
          websocket: %{heartbeat_interval_s: 30, reconnect_base_s: 5, reconnect_max_s: 60}
        },
        config_path: ""
      }

      start_supervised!({Config, config})
      start_supervised!({Cache, @cache_config})
      start_supervised!(Metrics)

      forwarder_config = %{
        upstreams: config.upstreams,
        upstream_timeout_ms: config.upstream_timeout_ms,
        upstream_failure_threshold: config.upstream_failure_threshold
      }

      start_supervised!({Forwarder, forwarder_config})
      sup_pid = start_supervised!(YellowDog.Resolved.Listener.listener_spec(config))
      listener_port = find_abyss_listener_port(sup_pid)

      {:ok, client} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      on_exit(fn -> :gen_udp.close(client) end)

      {:ok, port: listener_port, client: client}
    end

    test "non-intercepted query is forwarded via UDP", ctx do
      query = build_query("forward-e2e.test", 1, 4004)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      :ok = :gen_udp.send(ctx.client, {127, 0, 0, 1}, ctx.port, raw)

      assert {:ok, {_ip, _port, response_binary}} =
               :gen_udp.recv(ctx.client, 0, 5000)

      response = DNS.Message.from_iodata(response_binary)
      assert response.header.qr == 1
      assert response.header.id == 4004
    end

    test "forwarded response is cached on second UDP query", ctx do
      query1 = build_query("cache-e2e.test", 1, 5005)
      raw1 = DNS.to_iodata(query1) |> IO.iodata_to_binary()

      :ok = :gen_udp.send(ctx.client, {127, 0, 0, 1}, ctx.port, raw1)
      assert {:ok, _} = :gen_udp.recv(ctx.client, 0, 5000)

      Process.sleep(50)

      # Second query should hit cache
      query2 = build_query("cache-e2e.test", 1, 6006)
      raw2 = DNS.to_iodata(query2) |> IO.iodata_to_binary()

      :ok = :gen_udp.send(ctx.client, {127, 0, 0, 1}, ctx.port, raw2)

      assert {:ok, {_ip, _port, response_binary}} =
               :gen_udp.recv(ctx.client, 0, 2000)

      response = DNS.Message.from_iodata(response_binary)
      assert response.header.id == 6006
    end
  end

  # Walk the Abyss supervision tree to find the UDP socket port.
  defp find_abyss_listener_port(supervisor_pid) do
    case walk_tree_for_port(supervisor_pid) do
      nil -> raise "Could not find Abyss listener port"
      port -> port
    end
  end

  defp walk_tree_for_port(pid) when is_pid(pid) do
    # Check this process's linked ports for a UDP socket
    case Process.info(pid, :links) do
      {:links, links} ->
        port = find_udp_port_in_links(links)

        if port do
          port
        else
          # Try children if this is a supervisor
          try do
            Supervisor.which_children(pid)
            |> Enum.find_value(fn {_id, child_pid, _type, _mods} ->
              if is_pid(child_pid), do: walk_tree_for_port(child_pid)
            end)
          catch
            _, _ -> nil
          end
        end

      _ ->
        nil
    end
  end

  defp find_udp_port_in_links(links) do
    Enum.find_value(links, fn
      link when is_port(link) ->
        case :erlang.port_info(link, :name) do
          {:name, name} when is_list(name) ->
            name_str = to_string(name)

            if String.contains?(name_str, "udp") do
              case :inet.port(link) do
                {:ok, p} -> p
                _ -> nil
              end
            end

          _ ->
            nil
        end

      _ ->
        nil
    end)
  end

  defp build_query(domain, type_num, txn_id) do
    query = DNS.Message.new()
    query = DNS.Message.update_header_attr(query, :id, txn_id)
    query = DNS.Message.update_header_attr(query, :rd, 1)
    DNS.Message.add_question(query, DNS.Message.Question.new(domain, type_num, 1))
  end
end
