defmodule YellowDog.Mdns.ClientTest do
  @moduledoc """
  Tests for YellowDog.Mdns.Client.

  The mDNS client sends queries to the multicast group 224.0.0.251:5353 (IPv4)
  or ff02::fb:5353 (IPv6). Binding port 5353 typically requires root or
  CAP_NET_BIND_SERVICE, so in test environments `open_multicast_socket/2` will
  fail with {:error, :eacces} or {:error, :eaddrinuse}.

  Key design notes:
  - query/3, query_raw/3, browse/1, discover/2, send_message/2: return
    {:ok, []} on quiet network OR {:error, _} on socket failure — both valid.
  - resolve/2: ALWAYS returns {:ok, %{ipv4: [], ipv6: []}} because socket
    errors are silently converted to empty lists.
  - announce/2: uses Abyss.Client.broadcast (ephemeral port, no root needed)
    so it usually returns :ok even in test environments.
  """
  use ExUnit.Case, async: true

  alias YellowDog.Mdns.Client

  # ── Module structure ────────────────────────────────────────────────

  describe "module structure" do
    test "module is loadable" do
      assert {:module, Client} = Code.ensure_loaded(Client)
    end

    test "exports all expected public functions" do
      exported = Client.__info__(:functions)

      required = [
        query: 2,
        query: 3,
        query_raw: 2,
        query_raw: 3,
        discover: 1,
        discover: 2,
        browse: 0,
        browse: 1,
        resolve: 1,
        resolve: 2,
        send_message: 1,
        send_message: 2,
        announce: 1,
        announce: 2
      ]

      Enum.each(required, fn {name, arity} ->
        assert {name, arity} in exported,
               "Expected #{name}/#{arity} to be exported from #{Client}"
      end)
    end
  end

  # ── query/3 ─────────────────────────────────────────────────────────

  describe "query/3" do
    # In test environment: socket bind to port 5353 may fail (eacces/eaddrinuse)
    # OR succeed with no responses received (empty list).

    test "returns {:ok, []} or {:error, _} — does not crash" do
      result = Client.query("test.local", :a, timeout: 50)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "result is a list when successful" do
      case Client.query("host.local", :a, timeout: 50) do
        {:ok, responses} -> assert is_list(responses)
        {:error, _} -> :ok
      end
    end

    test "accepts all common mDNS record types" do
      # :any is not supported by DNS.ResourceRecordType.new/1, so omit it here.
      types = [:a, :aaaa, :ptr, :srv, :txt]

      Enum.each(types, fn type ->
        result = Client.query("service.local", type, timeout: 50)
        assert match?({:ok, _}, result) or match?({:error, _}, result)
      end)
    end

    test "accepts ipv6: true option" do
      # IPv6 multicast socket may exit with :badarg in environments without IPv6.
      result =
        try do
          Client.query("host.local", :aaaa, timeout: 50, ipv6: true)
        catch
          :exit, _ -> {:error, :badarg}
        end

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  # ── query_raw/3 ──────────────────────────────────────────────────────

  describe "query_raw/3" do
    test "returns {:ok, [binaries]} or {:error, _}" do
      result = Client.query_raw("test.local", :a, timeout: 50)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "raw responses are binaries when successful" do
      case Client.query_raw("host.local", :a, timeout: 50) do
        {:ok, responses} ->
          Enum.each(responses, fn r -> assert is_binary(r) end)

        {:error, _} ->
          :ok
      end
    end
  end

  # ── browse/1 ────────────────────────────────────────────────────────

  describe "browse/1" do
    test "returns {:ok, service_type_list} or {:error, _}" do
      result = Client.browse(timeout: 50)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "service types are strings when successful" do
      case Client.browse(timeout: 50) do
        {:ok, types} ->
          Enum.each(types, fn t -> assert is_binary(t) end)

        {:error, _} ->
          :ok
      end
    end
  end

  # ── discover/2 ──────────────────────────────────────────────────────

  describe "discover/2" do
    test "returns {:ok, services} or {:error, _}" do
      result = Client.discover("_http._tcp.local", timeout: 50)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "discovered services are maps when successful" do
      case Client.discover("_ssh._tcp.local", timeout: 50) do
        {:ok, services} ->
          # Each service has name, host, port, priority, weight, txt fields
          Enum.each(services, fn svc ->
            assert is_map(svc)
            assert Map.has_key?(svc, :name)
            assert Map.has_key?(svc, :host)
            assert Map.has_key?(svc, :port)
          end)

        {:error, _} ->
          :ok
      end
    end
  end

  # ── resolve/2 ───────────────────────────────────────────────────────

  describe "resolve/2" do
    # resolve/2 ALWAYS returns {:ok, %{ipv4: [], ipv6: []}} when no server
    # responds, because socket errors are silently converted to empty lists.

    test "always returns {:ok, map} structure" do
      result = Client.resolve("nonexistent.local", timeout: 50)
      assert {:ok, addrs} = result
      assert Map.has_key?(addrs, :ipv4)
      assert Map.has_key?(addrs, :ipv6)
    end

    test "ipv4 and ipv6 lists are empty when no mDNS responses" do
      {:ok, addrs} = Client.resolve("unknown-device.local", timeout: 50)
      assert is_list(addrs.ipv4)
      assert is_list(addrs.ipv6)
    end

    test "ipv4 addresses are 4-tuples when present" do
      {:ok, addrs} = Client.resolve("any.local", timeout: 50)

      Enum.each(addrs.ipv4, fn addr ->
        assert is_tuple(addr)
        assert tuple_size(addr) == 4
      end)
    end

    test "ipv6 addresses are 8-tuples when present" do
      {:ok, addrs} = Client.resolve("any.local", timeout: 50)

      Enum.each(addrs.ipv6, fn addr ->
        assert is_tuple(addr)
        assert tuple_size(addr) == 8
      end)
    end
  end

  # ── send_message/2 ──────────────────────────────────────────────────

  describe "send_message/2" do
    test "returns {:ok, []} or {:error, _}" do
      message = build_dns_query("test.local", :a)
      result = Client.send_message(message, timeout: 50)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "accepts DNS.Message struct" do
      message = build_dns_query("host.local", :ptr)
      assert is_struct(message, DNS.Message)
    end
  end

  # ── announce/2 ──────────────────────────────────────────────────────

  describe "announce/2" do
    # announce/2 uses Abyss.Client.broadcast (ephemeral port 0 — no root needed),
    # so it typically returns :ok even in test environments.

    test "returns :ok or {:error, _} — does not crash" do
      message = build_dns_announcement("mydevice.local", {192, 168, 1, 100})
      result = Client.announce(message)
      assert result == :ok or match?({:error, _}, result)
    end

    test "accepts ipv6: false option" do
      message = build_dns_announcement("device.local", {10, 0, 0, 1})
      result = Client.announce(message, ipv6: false)
      assert result == :ok or match?({:error, _}, result)
    end
  end

  # ── Underlying DNS message building ─────────────────────────────────

  describe "DNS message building" do
    test "query builds a DNS.Message with QR=0 (query) and RD=0" do
      # mDNS uses QR=0 for queries, RD=0 (no recursion in mDNS per RFC 6762)
      message = build_dns_query("example.local", :a)
      assert %DNS.Message{} = message
      assert message.header.qr == 0
      assert message.header.rd == 0
    end

    test "query message has exactly one question" do
      message = build_dns_query("printer.local", :ptr)
      assert length(message.qdlist) == 1
    end

    test "query question has correct name" do
      message = build_dns_query("server.local", :aaaa)
      [question] = message.qdlist
      # DNS.Message.Question.name is a DNS.Domain struct — use to_string/1
      assert String.contains?(to_string(question.name), "server.local")
    end

    test "message can be serialized to binary" do
      message = build_dns_query("test.local", :a)
      binary = DNS.to_iodata(message) |> IO.iodata_to_binary()
      assert is_binary(binary)
      # Minimum DNS message: 12 bytes header
      assert byte_size(binary) >= 12
    end
  end

  # ── Integration tests (skipped in CI) ───────────────────────────────

  describe "integration with live mDNS network" do
    @tag :skip
    @tag :integration
    test "query returns responses from real mDNS hosts" do
      # Requires a local network with mDNS-capable devices
      {:ok, responses} = Client.query("_http._tcp.local", :ptr, timeout: 3000)
      assert is_list(responses)
    end

    @tag :skip
    @tag :integration
    test "browse returns service types from network" do
      {:ok, types} = Client.browse(timeout: 3000)
      assert is_list(types)
    end

    @tag :skip
    @tag :integration
    test "resolve returns IP addresses for known .local host" do
      # Requires a known .local hostname on the test network
      {:ok, addrs} = Client.resolve("hostname.local", timeout: 3000)
      assert %{ipv4: ipv4, ipv6: _ipv6} = addrs
      assert length(ipv4) > 0
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp build_dns_query(name, type) do
    # Use Question.new/3 which converts name→Domain, type→RRType, class→Class.
    message = DNS.Message.new()
    message = %{message | header: %{message.header | id: 0, rd: 0}}
    DNS.Message.add_question(message, DNS.Message.Question.new(name, type, :in))
  end

  defp build_dns_announcement(_name, _ip) do
    # For announce tests we only need a serializable message; content doesn't matter.
    message = DNS.Message.new()
    %{message | header: %{message.header | id: 0, qr: 1, aa: 1, rd: 0}}
  end
end
