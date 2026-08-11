defmodule YellowDog.Console.NetmanManagementTransportTest do
  use ExUnit.Case, async: false

  alias YellowDog.Console.ManagementTransport
  alias YellowDog.Console.NetmanConnections
  alias YellowDog.ManagementCore
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Message
  alias YellowDog.Sync.Message.{Command, ConfigDelivery, Query}

  @observed_at ~U[2026-08-11 08:30:00Z]

  setup do
    :ok = NetmanConnections.reset()
    on_exit(fn -> NetmanConnections.reset() end)
    :ok
  end

  test "routes canonical Netman Query and Command requests to only the concrete connection" do
    netman_id = unique_id("transport")
    register_and_activate(netman_id)

    assert ManagementTransport.connected?(:netman, netman_id)
    refute ManagementTransport.connected?(:netman, unique_id("missing"))

    for {envelope, wrapper, value} <- [
          {envelope(netman_id, "netman.runtime.capabilities.get", %{}), Query,
           %{"capabilities" => []}},
          {envelope(netman_id, "netman.resolved.cache.flush", %{}), Command,
           %{"cleared_entries" => 2}}
        ] do
      task = Task.async(fn -> ManagementTransport.request(envelope, 1_000) end)

      assert_receive {:netman_management_push, encoded}
      assert {:ok, decoded} = Message.decode(encoded)
      assert decoded.__struct__ == wrapper
      assert decoded.envelope == envelope

      assert :ok =
               NetmanConnections.resolve_result(netman_id, self(), %{
                 tag: :result,
                 request_id: envelope.request_id,
                 target_type: :netman,
                 operation: envelope.operation,
                 outcome: {:ok, value}
               })

      assert {:ok, ^value} = Task.await(task)
    end
  end

  test "returns typed timeout and not-connected errors for Netman requests" do
    netman_id = unique_id("timeout")
    register_and_activate(netman_id)
    envelope = envelope(netman_id, "netman.runtime.capabilities.get", %{})

    task = Task.async(fn -> ManagementTransport.request(envelope, 10) end)
    assert_receive {:netman_management_push, _encoded}
    assert {:error, %Error{code: :timeout}} = Task.await(task)

    assert :ok = NetmanConnections.disconnect(netman_id, self())

    assert {:error, %Error{code: :not_connected}} =
             ManagementTransport.request(envelope, 100)
  end

  test "routes canonical Netman config delivery to only the concrete connection" do
    netman_id = unique_id("config")
    register_and_activate(netman_id)
    envelope = config_envelope(netman_id)

    assert :ok = ManagementTransport.deliver_config(envelope)
    assert_receive {:netman_management_push, encoded}

    assert {:ok, %ConfigDelivery{envelope: ^envelope}} = Message.decode(encoded)

    assert :ok = NetmanConnections.disconnect(netman_id, self())

    assert {:error, %Error{code: :not_connected}} =
             ManagementTransport.deliver_config(envelope)
  end

  defp register_and_activate(netman_id) do
    assert {:ok, _netman} = ManagementCore.register_netman(%{id: netman_id, profile: :vm})
    assert :ok = NetmanConnections.begin_candidate(netman_id, self())

    identity = %{
      target_type: :netman,
      id: netman_id,
      name: "Netman",
      version: "1.0.0",
      profile: "vm",
      capabilities: ["runtime.capabilities", "resolved.cache.write"],
      config_revision: String.duplicate("a", 64)
    }

    status = %{
      target_type: :netman,
      target_id: netman_id,
      state: :online,
      details: %{},
      observed_at: @observed_at
    }

    assert {:ok, nil} = NetmanConnections.activate(netman_id, self(), identity, status)
  end

  defp config_envelope(netman_id) do
    envelope(
      netman_id,
      "netman.profiles.replace",
      %{"profiles" => []},
      1
    )
  end

  defp envelope(netman_id, operation, payload, config_version \\ nil) do
    {:ok, digest} = Digest.calculate(payload)

    %Envelope{
      protocol_version: 1,
      request_id: uuid(),
      target_type: :netman,
      target_id: netman_id,
      operation: operation,
      idempotency_key: uuid(),
      payload: payload,
      payload_digest: digest,
      expected_revision: nil,
      config_version: config_version,
      sent_at: @observed_at
    }
  end

  defp uuid do
    <<prefix::binary-size(6), version, middle, variant, suffix::binary-size(7)>> =
      :crypto.strong_rand_bytes(16)

    bytes =
      <<prefix::binary, Bitwise.band(version, 0x0F) + 0x40, middle,
        Bitwise.band(variant, 0x3F) + 0x80, suffix::binary>>

    Base.encode16(bytes, case: :lower)
    |> then(fn value ->
      binary_part(value, 0, 8) <>
        "-" <>
        binary_part(value, 8, 4) <>
        "-" <>
        binary_part(value, 12, 4) <>
        "-" <>
        binary_part(value, 16, 4) <> "-" <> binary_part(value, 20, 12)
    end)
  end

  defp unique_id(prefix),
    do: "#{prefix}-#{Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)}"
end
