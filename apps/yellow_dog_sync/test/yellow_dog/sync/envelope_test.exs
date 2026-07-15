defmodule YellowDog.Sync.EnvelopeTest do
  use ExUnit.Case, async: false

  alias YellowDog.Sync
  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Codec
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error

  @request_id "7f12c5d1-6a5d-4b2e-9a75-4a6d5d8f18c0"
  @idempotency_key "47b8f6f4-9293-4a20-9327-1a15d87fe427"
  @sent_at ~U[2026-07-16 08:30:00.123456Z]
  @max_config_version 9_223_372_036_854_775_807

  test "JSON round trips a Server envelope through the typed facade" do
    envelope = envelope(:server, "server-east-1", %{"services" => ["dns", "dhcpv4"]})

    assert {:ok, encoded} = Sync.encode(envelope)

    assert {:ok,
            %Envelope{
              protocol_version: 1,
              request_id: @request_id,
              target_type: :server,
              target_id: "server-east-1",
              operation: "server.dns.status",
              idempotency_key: @idempotency_key,
              payload: %{"services" => ["dns", "dhcpv4"]},
              expected_revision: nil,
              sent_at: @sent_at
            } = decoded} = Sync.decode(encoded)

    assert decoded.payload_digest == digest(decoded.payload)
  end

  test "JSON round trips a Netman envelope with an expected revision" do
    payload = %{"profile" => %{"name" => "office", "dns" => ["1.1.1.1"]}}
    expected_revision = String.duplicate("a", 64)
    envelope = envelope(:netman, "netman-edge-1", payload, expected_revision: expected_revision)

    assert {:ok, encoded} = Envelope.encode(envelope)

    assert {:ok, %Envelope{target_type: :netman, expected_revision: ^expected_revision}} =
             Envelope.decode(encoded)
  end

  test "round trips positive config version boundaries" do
    for version <- [1, @max_config_version] do
      envelope =
        envelope(:server, "server-east-1", %{},
          operation: "server.settings.update",
          config_version: version
        )

      assert Envelope.to_wire(envelope)["config_version"] == version
      assert {:ok, encoded} = Envelope.encode(envelope)
      assert {:ok, decoded} = Envelope.decode(encoded)
      assert Map.fetch!(decoded, :config_version) == version
    end
  end

  test "rejects invalid config version boundaries" do
    for version <- [0, -1, @max_config_version + 1, "1", 1.0] do
      envelope =
        envelope(:server, "server-east-1", %{},
          operation: "server.settings.update",
          config_version: version
        )

      assert_invalid(Envelope.encode(envelope))
      assert_invalid(Envelope.from_wire(Envelope.to_wire(envelope)))
    end
  end

  test "omits config version when it is not present" do
    envelope = envelope(:server, "server-east-1", %{})

    refute Map.has_key?(Envelope.to_wire(envelope), "config_version")
    assert {:ok, encoded} = Envelope.encode(envelope)
    refute Map.has_key?(Jason.decode!(encoded), "config_version")
  end

  test "round trips an envelope payload at the canonical nesting limit" do
    envelope = envelope(:server, "server-east-1", nested_payload(8))

    assert {:ok, encoded} = Envelope.encode(envelope)
    assert {:ok, %Envelope{payload: payload}} = Envelope.decode(encoded)
    assert payload == nested_payload(8)
  end

  test "round trips a near-limit payload when its envelope exceeds one MiB" do
    payload = near_max_payload()
    assert {:ok, encoded_payload} = Codec.encode(payload)
    assert byte_size(encoded_payload) <= Bounds.max_payload_bytes()

    envelope = envelope(:server, "server-east-1", payload)
    assert {:ok, encoded_envelope} = Envelope.encode(envelope)
    assert byte_size(encoded_envelope) > Bounds.max_payload_bytes()
    assert byte_size(encoded_envelope) <= Codec.max_document_bytes()

    assert {:ok, %Envelope{payload: ^payload}} = Envelope.decode(encoded_envelope)
  end

  test "rejects missing required fields with a stable error" do
    wire =
      envelope(:server, "server-east-1", %{}) |> Envelope.to_wire() |> Map.delete("request_id")

    assert_invalid(Envelope.from_wire(wire))
  end

  test "rejects unsupported protocol versions and malformed lowercase UUIDs" do
    unsupported =
      envelope(:server, "server-east-1", %{})
      |> Envelope.to_wire()
      |> Map.put("protocol_version", 2)

    malformed_uuid =
      envelope(:server, "server-east-1", %{})
      |> Envelope.to_wire()
      |> Map.put("request_id", "7F12C5D1-6A5D-4B2E-9A75-4A6D5D8F18C0")

    assert_invalid(Envelope.from_wire(unsupported))
    assert_invalid(Envelope.from_wire(malformed_uuid))
  end

  test "rejects invalid target IDs and target-type mismatches" do
    invalid_target_id =
      envelope(:server, "server-east-1", %{})
      |> Envelope.to_wire()
      |> Map.put("target_id", <<255>>)

    netman = envelope(:netman, "netman-edge-1", %{}) |> Envelope.to_wire()

    assert_invalid(Envelope.from_wire(invalid_target_id))
    assert_invalid(Envelope.decode(Jason.encode!(netman), :server))
  end

  test "rejects payloads over the approved aggregate byte limit and incorrect digests" do
    oversized_payload = aggregate_payload_over_limit()
    assert {:ok, encoded_payload} = Codec.encode(oversized_payload)
    assert byte_size(encoded_payload) > Bounds.max_payload_bytes()

    oversized =
      envelope(:server, "server-east-1", oversized_payload)
      |> Envelope.to_wire()

    incorrect_digest =
      envelope(:server, "server-east-1", %{})
      |> Envelope.to_wire()
      |> Map.put("payload_digest", String.duplicate("0", 64))

    assert_invalid(Envelope.encode(envelope(:server, "server-east-1", oversized_payload)))
    assert_invalid(Envelope.from_wire(oversized))
    assert_invalid(Envelope.from_wire(incorrect_digest))
  end

  test "rejects direct envelope maps over the approved entry limit" do
    oversized =
      envelope(:server, "server-east-1", %{})
      |> Envelope.to_wire()
      |> add_entries_to_exceed_map_limit()

    assert map_size(oversized) > Bounds.max_map_entries()
    assert_invalid(Envelope.from_wire(oversized))
  end

  test "rejects non-UTC timestamps and malformed JSON with stable errors" do
    non_utc =
      envelope(:server, "server-east-1", %{})
      |> Envelope.to_wire()
      |> Map.put("sent_at", "2026-07-16T08:30:00+08:00")

    assert_invalid(Envelope.from_wire(non_utc))
    assert_invalid(Envelope.decode("not json"))
  end

  test "does not encode an envelope with a non-UTC DateTime" do
    non_utc_sent_at = %DateTime{@sent_at | utc_offset: 28_800}
    envelope = envelope(:server, "server-east-1", %{}, sent_at: non_utc_sent_at)

    assert_invalid(Envelope.encode(envelope))
  end

  test "decoding unknown operations preserves atom safety" do
    warm_wire = envelope(:server, "server-east-1", %{}) |> Envelope.to_wire()
    assert {:ok, %Envelope{}} = Envelope.from_wire(warm_wire)
    _ = System.unique_integer([:positive])
    assert_raise ArgumentError, fn -> String.to_existing_atom("unknown.operation.warmup") end

    initial_atom_count = :erlang.system_info(:atom_count)

    last_operation =
      Enum.reduce(1..500, nil, fn index, _last_operation ->
        operation = "unknown.operation.#{index}_#{System.unique_integer([:positive])}"
        wire = envelope(:server, "server-east-1", %{}, operation: operation) |> Envelope.to_wire()

        assert {:ok, %Envelope{operation: ^operation}} = Envelope.from_wire(wire)
        operation
      end)

    assert :erlang.system_info(:atom_count) == initial_atom_count
    assert_raise ArgumentError, fn -> String.to_existing_atom(last_operation) end
  end

  defp envelope(target_type, target_id, payload, overrides \\ []) do
    envelope = %Envelope{
      protocol_version: 1,
      request_id: Keyword.get(overrides, :request_id, @request_id),
      target_type: target_type,
      target_id: target_id,
      operation: Keyword.get(overrides, :operation, "server.dns.status"),
      idempotency_key: Keyword.get(overrides, :idempotency_key, @idempotency_key),
      payload: payload,
      payload_digest: digest(payload),
      expected_revision: Keyword.get(overrides, :expected_revision),
      sent_at: Keyword.get(overrides, :sent_at, @sent_at)
    }

    Map.put(envelope, :config_version, Keyword.get(overrides, :config_version))
  end

  defp digest(payload) do
    {:ok, digest} = Digest.calculate(payload)
    digest
  end

  defp aggregate_payload_over_limit do
    string = String.duplicate("x", Bounds.max_message_bytes())

    Map.new(1..Bounds.max_map_entries(), fn index ->
      {Integer.to_string(index), List.duplicate(string, 11)}
    end)
  end

  defp near_max_payload do
    string = String.duplicate("x", Bounds.max_message_bytes())

    Map.new(1..Bounds.max_map_entries(), fn index ->
      count = if index <= 20, do: 11, else: 10
      {Integer.to_string(index), List.duplicate(string, count)}
    end)
  end

  defp nested_payload(1), do: %{"value" => "ok"}
  defp nested_payload(depth), do: %{"nested" => nested_payload(depth - 1)}

  defp add_entries_to_exceed_map_limit(map) do
    entries_to_add = Bounds.max_map_entries() - map_size(map) + 1

    Enum.reduce(1..entries_to_add, map, fn index, map ->
      Map.put(map, "unexpected_#{index}", nil)
    end)
  end

  defp assert_invalid(result) do
    assert {:error, %Error{code: :invalid}} = result
  end
end
