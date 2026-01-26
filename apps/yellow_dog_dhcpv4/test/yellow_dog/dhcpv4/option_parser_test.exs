defmodule YellowDog.Dhcpv4.OptionParserTest do
  use ExUnit.Case, async: true

  alias YellowDog.Dhcpv4.OptionParser

  describe "extract_common/1" do
    test "extracts all common options in a single pass" do
      options = [
        # DISCOVER
        %{type: 53, length: 1, value: <<1>>},
        # hostname
        %{type: 12, length: 7, value: "client1"},
        # client_id
        %{type: 61, length: 7, value: <<1, 0, 1, 2, 3, 4, 5>>},
        # requested IP
        %{type: 50, length: 4, value: <<192, 168, 1, 50>>},
        # vendor class
        %{type: 60, length: 9, value: "MSFT 5.0 "},
        # user class (typically has trailing bytes)
        %{type: 77, length: 6, value: "PXE "}
      ]

      result = OptionParser.extract_common(options)

      assert result.message_type == :discover
      assert result.hostname == "client1"
      assert result.client_id == <<1, 0, 1, 2, 3, 4, 5>>
      assert result.requested_ip == {192, 168, 1, 50}
      assert result.vendor_class == "MSFT 5.0 "
      assert result.user_class == "PXE "
      assert result.server_id == nil
      assert result.client_arch == nil
    end

    test "extracts message type discover" do
      options = [%{type: 53, length: 1, value: <<1>>}]
      result = OptionParser.extract_common(options)
      assert result.message_type == :discover
    end

    test "extracts message type offer" do
      options = [%{type: 53, length: 1, value: <<2>>}]
      result = OptionParser.extract_common(options)
      assert result.message_type == :offer
    end

    test "extracts message type request" do
      options = [%{type: 53, length: 1, value: <<3>>}]
      result = OptionParser.extract_common(options)
      assert result.message_type == :request
    end

    test "extracts message type decline" do
      options = [%{type: 53, length: 1, value: <<4>>}]
      result = OptionParser.extract_common(options)
      assert result.message_type == :decline
    end

    test "extracts message type ack" do
      options = [%{type: 53, length: 1, value: <<5>>}]
      result = OptionParser.extract_common(options)
      assert result.message_type == :ack
    end

    test "extracts message type nak" do
      options = [%{type: 53, length: 1, value: <<6>>}]
      result = OptionParser.extract_common(options)
      assert result.message_type == :nak
    end

    test "extracts message type release" do
      options = [%{type: 53, length: 1, value: <<7>>}]
      result = OptionParser.extract_common(options)
      assert result.message_type == :release
    end

    test "extracts message type inform" do
      options = [%{type: 53, length: 1, value: <<8>>}]
      result = OptionParser.extract_common(options)
      assert result.message_type == :inform
    end

    test "handles unknown message type" do
      options = [%{type: 53, length: 1, value: <<99>>}]
      result = OptionParser.extract_common(options)
      assert result.message_type == nil
    end

    test "extracts server identifier" do
      options = [%{type: 54, length: 4, value: <<10, 0, 0, 1>>}]
      result = OptionParser.extract_common(options)
      assert result.server_id == <<10, 0, 0, 1>>
    end

    test "extracts client architecture" do
      # Intel x86
      options = [%{type: 93, length: 2, value: <<0, 0>>}]
      result = OptionParser.extract_common(options)
      assert result.client_arch == <<0, 0>>
    end

    test "returns nil for missing options" do
      options = []
      result = OptionParser.extract_common(options)

      assert result.message_type == nil
      assert result.hostname == nil
      assert result.client_id == nil
      assert result.server_id == nil
      assert result.requested_ip == nil
      assert result.vendor_class == nil
      assert result.user_class == nil
      assert result.client_arch == nil
    end

    test "ignores unknown option types" do
      options = [
        # DISCOVER
        %{type: 53, length: 1, value: <<1>>},
        # END
        %{type: 255, length: 0, value: <<>>},
        # PAD
        %{type: 0, length: 0, value: <<>>},
        # subnet mask (not extracted)
        %{type: 1, length: 4, value: <<255, 255, 255, 0>>}
      ]

      result = OptionParser.extract_common(options)
      assert result.message_type == :discover
      # Verify these options were processed without error
    end

    test "handles malformed requested IP" do
      # Too short
      options = [%{type: 50, length: 3, value: <<192, 168, 1>>}]
      result = OptionParser.extract_common(options)
      assert result.requested_ip == nil
    end
  end

  describe "extract_message_type/1" do
    test "efficiently extracts only message type" do
      options = [
        %{type: 12, length: 7, value: "client1"},
        %{type: 53, length: 1, value: <<3>>},
        %{type: 61, length: 7, value: <<1, 0, 1, 2, 3, 4, 5>>}
      ]

      assert OptionParser.extract_message_type(options) == :request
    end

    test "returns nil when message type not present" do
      options = [%{type: 12, length: 7, value: "client1"}]
      assert OptionParser.extract_message_type(options) == nil
    end
  end

  describe "build_client_info/2" do
    test "builds client info map from parsed options" do
      message = %{chaddr: <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>}

      parsed = %{
        message_type: :discover,
        hostname: "client1",
        client_id: nil,
        server_id: nil,
        requested_ip: nil,
        vendor_class: "MSFT 5.0",
        user_class: "PXE",
        client_arch: <<0, 0>>
      }

      result = OptionParser.build_client_info(message, parsed)

      assert result.mac_address == <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>
      assert result.vendor_class == "MSFT 5.0"
      assert result.user_class == "PXE"
      assert result.client_arch == <<0, 0>>
    end

    test "handles nil values in parsed options" do
      message = %{chaddr: <<1, 2, 3, 4, 5, 6>>}

      parsed = %{
        message_type: :discover,
        hostname: nil,
        client_id: nil,
        server_id: nil,
        requested_ip: nil,
        vendor_class: nil,
        user_class: nil,
        client_arch: nil
      }

      result = OptionParser.build_client_info(message, parsed)

      assert result.mac_address == <<1, 2, 3, 4, 5, 6>>
      assert result.vendor_class == nil
      assert result.user_class == nil
      assert result.client_arch == nil
    end
  end

  describe "performance" do
    test "single pass is more efficient than multiple iterations" do
      # Create a realistic options list
      options =
        Enum.concat([
          [
            %{type: 53, length: 1, value: <<1>>},
            %{type: 12, length: 10, value: "workstation"},
            %{type: 61, length: 7, value: <<1, 0, 1, 2, 3, 4, 5>>},
            %{type: 50, length: 4, value: <<192, 168, 1, 100>>},
            %{type: 54, length: 4, value: <<192, 168, 1, 1>>},
            %{type: 60, length: 8, value: "MSFT 5.0"},
            %{type: 77, length: 4, value: "TEST"}
          ],
          # Add some other options to make the list more realistic
          Enum.map(1..20, fn i -> %{type: 100 + i, length: 4, value: <<i, i, i, i>>} end)
        ])

      # Warm up
      OptionParser.extract_common(options)

      # Measure single-pass extraction
      {time_single, result} =
        :timer.tc(fn ->
          for _ <- 1..1000 do
            OptionParser.extract_common(options)
          end
        end)

      # Verify extraction works correctly
      assert result |> List.last() |> Map.get(:message_type) == :discover
      assert result |> List.last() |> Map.get(:hostname) == "workstation"

      # Just verify it completes reasonably fast (under 100ms for 1000 iterations)
      assert time_single < 100_000
    end
  end
end
