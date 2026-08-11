defmodule YellowDog.ServerAgent.QueryDispatcherTest do
  use ExUnit.Case, async: false

  Code.require_file("../../support/dispatcher_support.ex", __DIR__)

  alias YellowDog.ServerAgent.DispatcherTestAdapter
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error

  @server_id "server-east-1"
  @capability "runtime.services"
  @request_id "33333333-3333-4333-8333-333333333333"
  @idempotency_key "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
  @sent_at ~U[2026-07-17 01:00:00Z]

  test "dispatches a valid Server query once without command-journal options" do
    result = %{
      "items" => [],
      "revision" => String.duplicate("a", 64),
      "observed_at" => DateTime.to_iso8601(@sent_at)
    }

    DispatcherTestAdapter.configure(fn received ->
      assert received == envelope()
      {:ok, result}
    end)

    assert {:ok, ^result} =
             YellowDog.ServerAgent.QueryDispatcher.dispatch(
               envelope(),
               server_id: @server_id,
               capabilities: [@capability],
               runtime_adapter: DispatcherTestAdapter
             )

    assert DispatcherTestAdapter.count() == 1
  end

  test "rejects invalid query envelopes, targets, operation kinds, and capabilities before runtime work" do
    DispatcherTestAdapter.configure(fn _received -> flunk("runtime adapter must not run") end)

    invalid_inputs = [
      %{},
      envelope(target_type: :netman),
      envelope(target_id: "server-west-1"),
      command_envelope(),
      envelope()
    ]

    opts = [
      [
        server_id: @server_id,
        capabilities: [@capability],
        runtime_adapter: DispatcherTestAdapter
      ],
      [
        server_id: @server_id,
        capabilities: [@capability],
        runtime_adapter: DispatcherTestAdapter
      ],
      [
        server_id: @server_id,
        capabilities: [@capability],
        runtime_adapter: DispatcherTestAdapter
      ],
      [
        server_id: @server_id,
        capabilities: [@capability],
        runtime_adapter: DispatcherTestAdapter
      ],
      [server_id: @server_id, capabilities: [], runtime_adapter: DispatcherTestAdapter]
    ]

    for {input, input_opts} <- Enum.zip(invalid_inputs, opts) do
      assert {:error, %Error{code: :invalid, message: "invalid value", details: %{}}} =
               YellowDog.ServerAgent.QueryDispatcher.dispatch(input, input_opts)
    end

    assert DispatcherTestAdapter.count() == 0
  end

  test "sanitizes query adapter errors, exceptions, malformed returns, and invalid results" do
    expected = Error.new(:apply_failed, "apply failed", %{})

    outcomes = [
      {:error,
       %Error{code: :apply_failed, message: "adapter secret", details: %{"secret" => true}}},
      fn _envelope -> raise "adapter secret" end,
      fn _envelope -> exit(:adapter_secret) end,
      :malformed,
      {:ok, %{"invalid" => true}}
    ]

    Enum.with_index(outcomes, 1)
    |> Enum.each(fn {outcome, index} ->
      DispatcherTestAdapter.configure(fn envelope ->
        if is_function(outcome, 1), do: outcome.(envelope), else: outcome
      end)

      result =
        YellowDog.ServerAgent.QueryDispatcher.dispatch(
          envelope(request_id: request_id(index)),
          server_id: @server_id,
          capabilities: [@capability],
          runtime_adapter: DispatcherTestAdapter
        )

      if index == 1 do
        assert {:error, ^expected} = result
      else
        assert {:error, %Error{code: :internal, message: "internal error", details: %{}}} = result
      end

      assert DispatcherTestAdapter.count() == 1
    end)
  end

  test "returns a stable unsupported error for unavailable or incompatible runtime adapters" do
    for runtime_adapter <- [YellowDog.ServerAgent.MissingRuntimeAdapter, String] do
      assert {:error, %Error{code: :unsupported, message: "unsupported operation", details: %{}}} =
               YellowDog.ServerAgent.QueryDispatcher.dispatch(
                 envelope(),
                 server_id: @server_id,
                 capabilities: [@capability],
                 runtime_adapter: runtime_adapter
               )
    end
  end

  defp command_envelope do
    payload = %{"service" => "dns"}
    {:ok, payload_digest} = Digest.calculate(payload)

    %Envelope{
      protocol_version: 1,
      request_id: @request_id,
      target_type: :server,
      target_id: @server_id,
      operation: "server.runtime.services.start",
      idempotency_key: @idempotency_key,
      payload: payload,
      payload_digest: payload_digest,
      expected_revision: nil,
      config_version: nil,
      sent_at: @sent_at
    }
  end

  defp envelope(opts \\ []) do
    payload = Keyword.get(opts, :payload, %{})
    {:ok, payload_digest} = Digest.calculate(payload)

    struct!(
      Envelope,
      Keyword.merge(
        [
          protocol_version: 1,
          request_id: @request_id,
          target_type: :server,
          target_id: @server_id,
          operation: "server.runtime.services.list",
          idempotency_key: @idempotency_key,
          payload: payload,
          payload_digest: payload_digest,
          expected_revision: nil,
          config_version: nil,
          sent_at: @sent_at
        ],
        opts
      )
    )
  end

  defp request_id(index) do
    leading = index |> Integer.to_string(16) |> String.pad_leading(8, "0")
    "#{leading}-3333-4333-8333-333333333333"
  end
end
