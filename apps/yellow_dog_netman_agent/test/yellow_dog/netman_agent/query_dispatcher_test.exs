defmodule YellowDog.NetmanAgent.QueryDispatcherTest do
  use ExUnit.Case, async: false

  alias YellowDog.NetmanAgent.QueryDispatcher
  alias YellowDog.NetmanAgent.QueryDispatcherTest.QueryAdapter
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error

  @netman_id "netman-east-1"
  @capability "runtime.capabilities"
  @request_id "33333333-3333-4333-8333-333333333333"
  @idempotency_key "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
  @sent_at ~U[2026-08-10 01:00:00Z]

  test "dispatches one valid Netman query without a command journal" do
    result = %{"capabilities" => [@capability]}

    QueryAdapter.configure(fn received ->
      assert received == envelope()
      {:ok, result}
    end)

    assert {:ok, ^result} =
             QueryDispatcher.dispatch(
               envelope(),
               netman_id: @netman_id,
               capabilities: [@capability],
               runtime_adapter: QueryAdapter
             )

    assert QueryAdapter.calls() == 1
  end

  test "rejects invalid options, identity, kind, target, and capability before runtime work" do
    QueryAdapter.configure(fn _received -> flunk("runtime adapter must not run") end)

    unsafe_ids = [
      "",
      ".",
      "..",
      "../netman",
      "netman/child",
      "netman\\child",
      "C:netman",
      "netman\u0000control",
      "netman\u212A",
      String.duplicate("n", 129)
    ]

    for netman_id <- unsafe_ids do
      assert_invalid(
        QueryDispatcher.dispatch(
          envelope(target_id: netman_id),
          netman_id: netman_id,
          capabilities: [@capability],
          runtime_adapter: QueryAdapter
        )
      )
    end

    invalid_calls = [
      {%{}, base_opts()},
      {envelope(target_type: :server), base_opts()},
      {envelope(target_id: "netman-west-1"), base_opts()},
      {command_envelope(), base_opts()},
      {envelope(), base_opts(capabilities: [])},
      {envelope(), base_opts(capabilities: [:runtime_capabilities])},
      {envelope(), base_opts() ++ [command_journal: self()]},
      {envelope(), base_opts() ++ [netman_id: @netman_id]},
      {envelope(), Keyword.put(base_opts(), :runtime_adapter, "adapter")}
    ]

    for {input, opts} <- invalid_calls do
      assert_invalid(QueryDispatcher.dispatch(input, opts))
    end

    assert QueryAdapter.calls() == 0
  end

  test "validates results and sanitizes adapter errors and failures after one invocation" do
    expected = Error.new(:apply_failed, "apply failed", %{})

    outcomes = [
      {:error,
       %Error{code: :apply_failed, message: "adapter secret", details: %{"secret" => true}}},
      fn _envelope -> raise "adapter secret" end,
      fn _envelope -> throw(:adapter_secret) end,
      fn _envelope -> exit(:adapter_secret) end,
      :malformed,
      {:ok, %{"invalid" => true}},
      {:error, %Error{code: :unknown, message: "secret", details: %{}}}
    ]

    Enum.with_index(outcomes, 1)
    |> Enum.each(fn {outcome, index} ->
      QueryAdapter.configure(fn received ->
        assert received.request_id == request_id(index)
        if is_function(outcome, 1), do: outcome.(received), else: outcome
      end)

      result =
        QueryDispatcher.dispatch(
          envelope(request_id: request_id(index)),
          base_opts()
        )

      if index == 1 do
        assert {:error, ^expected} = result
      else
        assert {:error, %Error{code: :internal, message: "internal error", details: %{}}} =
                 result
      end

      assert QueryAdapter.calls() == 1
    end)
  end

  test "returns stable unsupported for unavailable and incompatible runtime adapters" do
    for adapter <- [YellowDog.NetmanAgent.MissingQueryAdapter, String] do
      assert {:error, %Error{code: :unsupported, message: "unsupported operation", details: %{}}} =
               QueryDispatcher.dispatch(
                 envelope(),
                 netman_id: @netman_id,
                 capabilities: [@capability],
                 runtime_adapter: adapter
               )
    end
  end

  defp assert_invalid(result) do
    assert {:error, %Error{code: :invalid, message: "invalid value", details: %{}}} = result
  end

  defp base_opts(overrides \\ []) do
    Keyword.merge(
      [
        netman_id: @netman_id,
        capabilities: [@capability],
        runtime_adapter: QueryAdapter
      ],
      overrides
    )
  end

  defp command_envelope do
    payload = profile_payload()
    {:ok, payload_digest} = Digest.calculate(payload)

    %Envelope{
      protocol_version: 1,
      request_id: @request_id,
      target_type: :netman,
      target_id: @netman_id,
      operation: "netman.profiles.validate",
      idempotency_key: @idempotency_key,
      payload: payload,
      payload_digest: payload_digest,
      expected_revision: nil,
      config_version: nil,
      sent_at: @sent_at
    }
  end

  defp profile_payload do
    %{
      "profile_id" => "office",
      "type" => "ethernet",
      "interface" => "eth0",
      "autoconnect" => true,
      "autoconnect_priority" => 0,
      "zone" => "default",
      "ethernet" => %{"mtu" => nil},
      "ipv4" => %{
        "method" => "auto",
        "address" => nil,
        "gateway" => nil,
        "dns" => [],
        "dns_search" => []
      },
      "ipv6" => %{
        "method" => "auto",
        "address" => nil,
        "gateway" => nil,
        "dns" => [],
        "dns_search" => []
      }
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
          target_type: :netman,
          target_id: @netman_id,
          operation: "netman.runtime.capabilities.get",
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

defmodule YellowDog.NetmanAgent.QueryDispatcherTest.QueryAdapter do
  @moduledoc false

  def configure(callback) when is_function(callback, 1) do
    Process.put({__MODULE__, :calls}, 0)
    Process.put({__MODULE__, :callback}, callback)
  end

  def calls, do: Process.get({__MODULE__, :calls}, 0)

  def dispatch(envelope) do
    Process.put({__MODULE__, :calls}, calls() + 1)
    Process.get({__MODULE__, :callback}).(envelope)
  end
end
