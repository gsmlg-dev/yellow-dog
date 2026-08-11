defmodule YellowDog.NetmanAgent.DispatcherTest do
  use ExUnit.Case, async: false

  alias YellowDog.NetmanAgent.CommandJournal
  alias YellowDog.NetmanAgent.Dispatcher
  alias YellowDog.NetmanAgent.DispatcherTest.TestAdapter
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error

  @netman_id "netman-east-1"
  @capability "profiles.validate"

  setup do
    data_dir =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-netman-dispatcher-#{System.unique_integer([:positive])}"
      )
      |> Path.expand()

    File.mkdir_p!(data_dir)
    on_exit(fn -> File.rm_rf(data_dir) end)
    %{data_dir: data_dir}
  end

  test "dispatches through a configured available adapter and durably replays", %{
    data_dir: data_dir
  } do
    journal = start_journal(data_dir)
    result = validation_result()
    TestAdapter.configure(fn _envelope -> {:ok, result} end)

    assert {:ok, ^result} =
             Dispatcher.dispatch(envelope(),
               netman_id: @netman_id,
               capabilities: [@capability],
               command_journal: journal,
               runtime_adapter: TestAdapter
             )

    assert TestAdapter.calls() == 1
    assert {:replay, {:ok, ^result}} = CommandJournal.replay(envelope(), journal)
  end

  test "rejects target mismatch and missing capability before runtime dispatch" do
    assert {:error, %Error{code: :invalid}} =
             Dispatcher.dispatch(envelope(target_id: "netman-west-1"),
               netman_id: @netman_id,
               capabilities: [@capability],
               command_journal: self(),
               runtime_adapter: TestAdapter
             )

    assert {:error, %Error{code: :invalid}} =
             Dispatcher.dispatch(envelope(),
               netman_id: @netman_id,
               capabilities: [],
               command_journal: self(),
               runtime_adapter: TestAdapter
             )

    assert TestAdapter.calls() == 0
  end

  test "persists unsupported result when the configured runtime adapter is unavailable", %{
    data_dir: data_dir
  } do
    journal = start_journal(data_dir)
    missing = :"Elixir.YellowDog.NetmanAgent.MissingRuntimeAdapter"
    refute Code.ensure_loaded?(missing)

    assert {:error, %Error{code: :unsupported} = error} =
             Dispatcher.dispatch(envelope(),
               netman_id: @netman_id,
               capabilities: [@capability],
               command_journal: journal,
               runtime_adapter: missing
             )

    assert {:replay, {:error, ^error}} = CommandJournal.replay(envelope(), journal)
  end

  test "uses the guarded default Netman runtime adapter when no adapter is configured", %{
    data_dir: data_dir
  } do
    journal = start_journal(data_dir)

    assert {:error, %Error{code: code}} =
             Dispatcher.dispatch(envelope(),
               netman_id: @netman_id,
               capabilities: [@capability],
               command_journal: journal
             )

    assert code in [:unsupported, :internal]
  end

  defp start_journal(data_dir) do
    name = {:global, {__MODULE__, System.unique_integer([:positive])}}

    {:ok, pid} =
      CommandJournal.start_link(
        name: name,
        data_dir: data_dir,
        netman_id: @netman_id,
        capabilities: [@capability]
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    name
  end

  defp envelope(opts \\ []) do
    payload = profile_payload()
    {:ok, digest} = Digest.calculate(payload)

    %Envelope{
      protocol_version: 1,
      request_id: "11111111-1111-4111-8111-111111111111",
      target_type: :netman,
      target_id: Keyword.get(opts, :target_id, @netman_id),
      operation: "netman.profiles.validate",
      idempotency_key: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      payload: payload,
      payload_digest: digest,
      expected_revision: nil,
      config_version: nil,
      sent_at: ~U[2026-08-10 00:00:00Z]
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

  defp validation_result, do: %{"profile_id" => "office", "valid" => true, "errors" => []}
end

defmodule YellowDog.NetmanAgent.DispatcherTest.TestAdapter do
  def configure(callback) do
    Process.put({__MODULE__, :calls}, 0)
    Process.put({__MODULE__, :callback}, callback)
  end

  def calls, do: Process.get({__MODULE__, :calls}, 0)

  def dispatch(envelope) do
    Process.put({__MODULE__, :calls}, calls() + 1)
    Process.get({__MODULE__, :callback}).(envelope)
  end
end
