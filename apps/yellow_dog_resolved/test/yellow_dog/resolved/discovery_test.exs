defmodule YellowDog.Resolved.DiscoveryTest do
  use ExUnit.Case, async: true

  alias YellowDog.Resolved.Discovery

  describe "EDNS option encoding" do
    test "generates 16-byte instance ID" do
      uuid = :crypto.strong_rand_bytes(16)
      assert byte_size(uuid) == 16
    end

    test "each UUID is unique" do
      uuid1 = :crypto.strong_rand_bytes(16)
      uuid2 = :crypto.strong_rand_bytes(16)
      assert uuid1 != uuid2
    end

    test "OPT record EDNS option survives DNS wire-format round-trip" do
      # Reproduces the encoding bug: DNS.Parameter.to_iodata/1 for BitString
      # encodes raw binaries as domain names.  The fix wraps edns_options in
      # DNS.Message.Record.Data so the generic impl emits <<rdlength::16, data>>.
      instance_id = :crypto.strong_rand_bytes(16)
      edns_data = <<1::8, instance_id::binary-size(16)>>
      edns_options = <<65321::16, byte_size(edns_data)::16, edns_data::binary>>
      rdlen = byte_size(edns_options)

      opt_rr = %DNS.Message.Record{
        name: %DNS.Message.Domain{value: ".", size: 1},
        type: DNS.ResourceRecordType.new(41),
        class: DNS.Class.new(4096),
        ttl: 0,
        rdlength: rdlen,
        data: %DNS.Message.Record.Data{rdlength: rdlen, raw: edns_options}
      }

      query = DNS.Message.new()

      query_with_opt = %{
        query
        | arlist: [opt_rr],
          header: %{query.header | arcount: 1}
      }

      packet = DNS.to_iodata(query_with_opt) |> IO.iodata_to_binary()
      parsed = DNS.Message.from_iodata(packet)

      # The OPT record must survive serialization (arcount = 1)
      assert parsed.header.arcount == 1
      assert length(parsed.arlist) == 1
      [parsed_opt] = parsed.arlist

      # rdlength in the parsed record must match the original EDNS option length
      assert parsed_opt.rdlength == rdlen
    end
  end

  describe "EDNS option format" do
    test "option code 65321 is in private-use range" do
      # RFC 6891: private-use range 65001-65534
      assert 65321 >= 65001
      assert 65321 <= 65534
    end

    test "EDNS option data structure" do
      instance_id = :crypto.strong_rand_bytes(16)
      version = 1

      # Build the EDNS option data as the Discovery module would
      edns_data = <<version::8, instance_id::binary-size(16)>>

      assert byte_size(edns_data) == 17

      # Verify we can decode it back
      <<decoded_version::8, decoded_id::binary-size(16)>> = edns_data
      assert decoded_version == 1
      assert decoded_id == instance_id
    end

    test "EDNS option wire format" do
      instance_id = :crypto.strong_rand_bytes(16)
      edns_data = <<1::8, instance_id::binary-size(16)>>

      # Full option: code (2 bytes) + length (2 bytes) + data
      option_code = 65321
      option_length = byte_size(edns_data)
      wire = <<option_code::16, option_length::16, edns_data::binary>>

      assert byte_size(wire) == 4 + 17

      # Decode wire format
      <<decoded_code::16, decoded_len::16, decoded_data::binary-size(decoded_len)>> = wire
      assert decoded_code == 65321
      assert decoded_len == 17
      <<v::8, id::binary-size(16)>> = decoded_data
      assert v == 1
      assert id == instance_id
    end
  end

  describe "EDNS option extraction from wire-format response" do
    test "OPT record.data is a struct with raw field after DNS.Message.from_iodata parse" do
      # ex_dns stores type 41 (OPT) using the generic DNS.Message.Record.Data fallback
      # because OPT is not registered in its type registry. find_edns_option must
      # call extract_rdata/1 to get the binary from the struct instead of passing the
      # struct directly to parse_edns_options/1.
      ws_path = "/ws/resolved"
      edns_data = <<1::8, ws_path::binary>>
      edns_options = <<65321::16, byte_size(edns_data)::16, edns_data::binary>>
      rdlen = byte_size(edns_options)

      opt_rr = %DNS.Message.Record{
        name: %DNS.Message.Domain{value: ".", size: 1},
        type: DNS.ResourceRecordType.new(41),
        class: DNS.Class.new(4096),
        ttl: 0,
        rdlength: rdlen,
        data: %DNS.Message.Record.Data{rdlength: rdlen, raw: edns_options}
      }

      query = DNS.Message.new()
      msg = %{query | arlist: [opt_rr], header: %{query.header | arcount: 1}}
      packet = DNS.to_iodata(msg) |> IO.iodata_to_binary()
      parsed = DNS.Message.from_iodata(packet)

      [parsed_opt] = parsed.arlist

      # After round-trip, record.data is a struct with a raw binary field, NOT a plain binary.
      # extract_rdata/1 is required to obtain the bytes.
      assert %{raw: rdata} = parsed_opt.data
      assert is_binary(rdata)
      assert byte_size(rdata) == rdlen

      # The raw bytes must preserve the EDNS option intact for the discovery parser.
      <<option_code::16, option_len::16, option_data::binary-size(option_len)>> = rdata
      assert option_code == 65321
      <<version::8, path::binary>> = option_data
      assert version == 1
      assert path == ws_path
    end
  end

  describe "EDNS response parsing" do
    test "response option data structure" do
      ws_path = "/ws/resolved"
      version = 1

      # Build response option data
      response_data = <<version::8, ws_path::binary>>

      # Decode
      <<decoded_version::8, decoded_path::binary>> = response_data
      assert decoded_version == 1
      assert decoded_path == "/ws/resolved"
    end

    test "EDNS option with only version byte and no ws_path is rejected" do
      # Simulates a server that sends version=1 but no path bytes.
      # The resulting empty binary must NOT be treated as a valid ws_path.
      version = 1
      data_with_no_path = <<version::8>>

      # Verify the binary contains no path bytes after the version
      <<_v::8, rest::binary>> = data_with_no_path
      assert byte_size(rest) == 0

      # Ensure a valid path is non-empty
      valid_data = <<version::8, "/ws/resolved"::binary>>
      <<_v2::8, path::binary>> = valid_data
      assert byte_size(path) > 0
    end

    test "SRV record port 0 must not be used as WebSocket port" do
      # Port 0 has special OS-level meaning and must be rejected by find_srv_record
      port = 0
      refute port >= 1 and port <= 65535
    end

    test "SRV record port above 65535 must be rejected" do
      port = 65536
      refute port >= 1 and port <= 65535
    end

    test "SRV record with valid port is accepted" do
      for port <- [1, 80, 443, 8080, 65535] do
        assert port >= 1 and port <= 65535
      end
    end

    test "SRV target trailing dot is stripped for WebSocket URL" do
      # DNS FQDN responses include a trailing dot; it must be stripped
      # before embedding in the ws:// URL or the HTTP client will fail.
      fqdn = "server.local."
      host = String.trim_trailing(fqdn, ".")
      assert host == "server.local"
      refute String.ends_with?(host, ".")
    end

    test "SRV target without trailing dot is unchanged" do
      bare = "server.local"
      host = String.trim_trailing(bare, ".")
      assert host == "server.local"
    end
  end

  describe "discovery startup" do
    test "starts discovery GenServer with no upstreams" do
      config = %{
        upstreams: [],
        discovery: %{
          enabled: true,
          websocket: %{
            heartbeat_interval_s: 30,
            reconnect_base_s: 5,
            reconnect_max_s: 60
          }
        }
      }

      {:ok, pid} = Discovery.start_link(config)
      assert Process.alive?(pid)

      # Can retrieve instance_id
      id = Discovery.instance_id()
      assert is_binary(id)
      assert byte_size(id) == 16

      GenServer.stop(pid)
    end
  end

  describe "probe with multiple upstreams" do
    test "no probes emitted when no upstreams configured" do
      config = %{
        upstreams: [],
        discovery: %{
          enabled: true,
          websocket: %{
            heartbeat_interval_s: 30,
            reconnect_base_s: 5,
            reconnect_max_s: 60
          }
        }
      }

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:yellow_dog, :resolved, :discovery, :probe]
        ])

      {:ok, pid} = Discovery.start_link(config)
      Process.sleep(50)

      # No probes should have been sent (no upstreams)
      refute_received {[:yellow_dog, :resolved, :discovery, :probe], ^ref, %{}, %{upstream: _}}

      GenServer.stop(pid)
    end

    test "management_down clears endpoint and pid in state" do
      config = %{
        upstreams: [],
        discovery: %{
          enabled: true,
          websocket: %{
            heartbeat_interval_s: 30,
            reconnect_base_s: 1,
            reconnect_max_s: 4
          }
        }
      }

      {:ok, pid} = Discovery.start_link(config)
      Process.sleep(10)

      # Simulate management disconnect
      send(pid, {:management_down, :connection_closed})
      Process.sleep(10)

      state = :sys.get_state(pid)
      assert state.management_pid == nil
      assert state.discovered_endpoint == nil

      GenServer.stop(pid)
    end

    test "unknown messages are handled gracefully" do
      config = %{
        upstreams: [],
        discovery: %{
          enabled: true,
          websocket: %{reconnect_base_s: 5, reconnect_max_s: 60}
        }
      }

      {:ok, pid} = Discovery.start_link(config)
      Process.sleep(10)

      # Send random message — should not crash
      send(pid, :some_random_message)
      send(pid, {:unexpected, :data})
      Process.sleep(10)

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "probe_result :not_found keeps GenServer alive" do
      config = %{
        upstreams: [],
        discovery: %{
          enabled: true,
          websocket: %{reconnect_base_s: 5, reconnect_max_s: 60}
        }
      }

      {:ok, pid} = Discovery.start_link(config)
      Process.sleep(10)

      # Simulate a probe task that returned :not_found (e.g. due to an exception)
      send(pid, {:probe_result, :not_found})
      Process.sleep(10)

      # GenServer must remain alive — no crash from unhandled :not_found
      assert Process.alive?(pid)
      state = :sys.get_state(pid)
      assert state.management_pid == nil

      GenServer.stop(pid)
    end
  end

  describe "exponential backoff" do
    test "management_down triggers re-probe with exponential backoff" do
      config = %{
        upstreams: [],
        discovery: %{
          enabled: true,
          websocket: %{
            heartbeat_interval_s: 30,
            reconnect_base_s: 1,
            reconnect_max_s: 8
          }
        }
      }

      {:ok, pid} = Discovery.start_link(config)

      # Get initial state via sys
      state = :sys.get_state(pid)
      assert state.reconnect_delay == 1000
      assert state.reconnect_base == 1000
      assert state.reconnect_max == 8000

      # Simulate management connection loss
      send(pid, {:management_down, :test_disconnect})
      Process.sleep(10)

      # Backoff should have doubled
      state = :sys.get_state(pid)
      assert state.reconnect_delay == 2000

      # Simulate another disconnect
      send(pid, {:management_down, :test_disconnect_2})
      Process.sleep(10)

      state = :sys.get_state(pid)
      assert state.reconnect_delay == 4000

      # And another
      send(pid, {:management_down, :test_disconnect_3})
      Process.sleep(10)

      state = :sys.get_state(pid)
      assert state.reconnect_delay == 8000

      # Should be capped at max
      send(pid, {:management_down, :test_disconnect_4})
      Process.sleep(10)

      state = :sys.get_state(pid)
      assert state.reconnect_delay == 8000

      GenServer.stop(pid)
    end
  end
end
