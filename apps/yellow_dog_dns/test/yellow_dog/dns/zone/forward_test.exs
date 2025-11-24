defmodule YellowDog.Dns.Zone.ForwardTest do
  use ExUnit.Case, async: true

  alias YellowDog.Dns.Zone.Forward

  describe "new/3" do
    test "creates a forward zone with default options" do
      forwarders = [{8, 8, 8, 8}, {1, 1, 1, 1}]
      forward = Forward.new("external.com", forwarders)

      assert forward.name == "external.com"
      assert forward.forwarders == forwarders
      assert forward.forward_mode == :only
      assert forward.timeout_ms == 5000
      assert forward.max_retries == 2
    end

    test "creates a forward zone with custom options" do
      forwarders = [{8, 8, 8, 8}]

      forward =
        Forward.new("external.com", forwarders,
          forward_mode: :first,
          timeout_ms: 3000,
          max_retries: 5
        )

      assert forward.name == "external.com"
      assert forward.forwarders == forwarders
      assert forward.forward_mode == :first
      assert forward.timeout_ms == 3000
      assert forward.max_retries == 5
    end
  end

  describe "validate/1" do
    test "validates a correct forward zone" do
      forward = Forward.new("external.com", [{8, 8, 8, 8}])
      assert Forward.validate(forward) == :ok
    end

    test "rejects forward zone with missing name" do
      forward = Forward.new("", [{8, 8, 8, 8}])
      assert Forward.validate(forward) == {:error, :missing_name}
    end

    test "rejects forward zone with nil name" do
      forward = %Forward{name: nil, forwarders: [{8, 8, 8, 8}]}
      assert Forward.validate(forward) == {:error, :missing_name}
    end

    test "rejects forward zone with no forwarders" do
      forward = Forward.new("external.com", [])
      assert Forward.validate(forward) == {:error, :missing_forwarders}
    end

    test "rejects forward zone with nil forwarders" do
      forward = %Forward{name: "external.com", forwarders: nil}
      assert Forward.validate(forward) == {:error, :missing_forwarders}
    end

    test "rejects forward zone with invalid forward mode" do
      forward = %Forward{
        name: "external.com",
        forwarders: [{8, 8, 8, 8}],
        forward_mode: :invalid
      }

      assert Forward.validate(forward) == {:error, :invalid_forward_mode}
    end

    test "rejects forward zone with timeout too low" do
      forward = Forward.new("external.com", [{8, 8, 8, 8}], timeout_ms: 50)
      assert Forward.validate(forward) == {:error, :invalid_timeout}
    end

    test "rejects forward zone with timeout too high" do
      forward = Forward.new("external.com", [{8, 8, 8, 8}], timeout_ms: 35_000)
      assert Forward.validate(forward) == {:error, :invalid_timeout}
    end

    test "rejects forward zone with negative max_retries" do
      forward = Forward.new("external.com", [{8, 8, 8, 8}], max_retries: -1)
      assert Forward.validate(forward) == {:error, :invalid_max_retries}
    end

    test "rejects forward zone with max_retries too high" do
      forward = Forward.new("external.com", [{8, 8, 8, 8}], max_retries: 15)
      assert Forward.validate(forward) == {:error, :invalid_max_retries}
    end
  end

  describe "parse_config/1" do
    test "parses valid forward zone configuration" do
      config = %{
        "name" => "external.com",
        "forwarders" => ["8.8.8.8", "1.1.1.1"],
        "forward_mode" => "only",
        "timeout_ms" => 3000,
        "max_retries" => 3
      }

      assert {:ok, forward} = Forward.parse_config(config)
      assert forward.name == "external.com"
      assert forward.forwarders == [{8, 8, 8, 8}, {1, 1, 1, 1}]
      assert forward.forward_mode == :only
      assert forward.timeout_ms == 3000
      assert forward.max_retries == 3
    end

    test "parses configuration with minimal fields" do
      config = %{
        "name" => "external.com",
        "forwarders" => ["8.8.8.8"]
      }

      assert {:ok, forward} = Forward.parse_config(config)
      assert forward.name == "external.com"
      assert forward.forwarders == [{8, 8, 8, 8}]
      assert forward.forward_mode == :only
      assert forward.timeout_ms == 5000
      assert forward.max_retries == 2
    end

    test "parses forward_mode 'first'" do
      config = %{
        "name" => "external.com",
        "forwarders" => ["8.8.8.8"],
        "forward_mode" => "first"
      }

      assert {:ok, forward} = Forward.parse_config(config)
      assert forward.forward_mode == :first
    end

    test "parses IPv6 forwarders" do
      config = %{
        "name" => "external.com",
        "forwarders" => ["2001:4860:4860::8888", "2001:4860:4860::8844"]
      }

      assert {:ok, forward} = Forward.parse_config(config)

      assert forward.forwarders == [
               {0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8888},
               {0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8844}
             ]
    end

    test "returns error for missing name" do
      config = %{
        "forwarders" => ["8.8.8.8"]
      }

      assert {:error, :missing_name} = Forward.parse_config(config)
    end

    test "returns error for missing forwarders" do
      config = %{
        "name" => "external.com"
      }

      assert {:error, :missing_forwarders} = Forward.parse_config(config)
    end

    test "returns error for invalid forwarder IP" do
      config = %{
        "name" => "external.com",
        "forwarders" => ["not-an-ip"]
      }

      assert {:error, :invalid_forwarders} = Forward.parse_config(config)
    end

    test "returns error for empty forwarders list" do
      config = %{
        "name" => "external.com",
        "forwarders" => []
      }

      assert {:error, :missing_forwarders} = Forward.parse_config(config)
    end
  end

  describe "to_storage_metadata/1" do
    test "converts forward zone to storage metadata" do
      forward =
        Forward.new("external.com", [{8, 8, 8, 8}], forward_mode: :first, timeout_ms: 3000)

      metadata = Forward.to_storage_metadata(forward)

      assert metadata.type == :forward
      assert metadata.forwarders == [{8, 8, 8, 8}]
      assert metadata.forward_mode == :first
      assert metadata.timeout_ms == 3000
      assert metadata.max_retries == 2
      assert is_integer(metadata.loaded_at)
    end
  end

  describe "from_storage_metadata/2" do
    test "recreates forward zone from storage metadata" do
      metadata = %{
        type: :forward,
        forwarders: [{8, 8, 8, 8}, {1, 1, 1, 1}],
        forward_mode: :only,
        timeout_ms: 4000,
        max_retries: 3
      }

      assert {:ok, forward} = Forward.from_storage_metadata("external.com", metadata)
      assert forward.name == "external.com"
      assert forward.forwarders == [{8, 8, 8, 8}, {1, 1, 1, 1}]
      assert forward.forward_mode == :only
      assert forward.timeout_ms == 4000
      assert forward.max_retries == 3
    end

    test "uses defaults for missing optional fields" do
      metadata = %{
        type: :forward,
        forwarders: [{8, 8, 8, 8}]
      }

      assert {:ok, forward} = Forward.from_storage_metadata("external.com", metadata)
      assert forward.forward_mode == :only
      assert forward.timeout_ms == 5000
      assert forward.max_retries == 2
    end

    test "returns error for non-forward zone type" do
      metadata = %{
        type: :master,
        forwarders: [{8, 8, 8, 8}]
      }

      assert {:error, :not_forward_zone} = Forward.from_storage_metadata("external.com", metadata)
    end

    test "returns error for invalid metadata" do
      metadata = %{
        type: :forward,
        forwarders: []
      }

      assert {:error, :missing_forwarders} =
               Forward.from_storage_metadata("external.com", metadata)
    end
  end
end
