defmodule YellowDog.NetmanAgent.CommandJournalTest do
  use ExUnit.Case, async: false

  alias YellowDog.NetmanAgent.CommandJournal
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error

  @netman_id "netman-east-1"
  @capability "profiles.validate"

  setup do
    trap_exit = Process.flag(:trap_exit, true)

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-netman-journal-#{System.unique_integer([:positive])}"
      )
      |> Path.expand()

    File.mkdir_p!(data_dir)

    on_exit(fn ->
      Process.flag(:trap_exit, trap_exit)
      File.rm_rf(data_dir)
    end)

    %{data_dir: data_dir}
  end

  test "durably replays a completed command after restart", %{data_dir: data_dir} do
    name = unique_name()
    journal = start_journal(data_dir, name: name)
    command = envelope()
    result = validation_result()

    assert {:reserved, request_id} = CommandJournal.reserve(command, journal)
    assert request_id == command.request_id
    assert :ok = CommandJournal.mark_running(command.request_id, journal)
    assert {:ok, ^result} = CommandJournal.complete_success(command.request_id, result, journal)
    stop(journal)

    restarted = start_journal(data_dir, name: name)
    assert {:replay, {:ok, ^result}} = CommandJournal.replay(command, restarted)
  end

  test "replays duplicate command reservations without creating a second record", %{
    data_dir: data_dir
  } do
    journal = start_journal(data_dir)
    command = envelope()

    assert {:reserved, request_id} = CommandJournal.reserve(command, journal)
    assert request_id == command.request_id
    assert {:error, %Error{code: :conflict}} = CommandJournal.reserve(command, journal)
    assert [file] = Path.wildcard(Path.join([data_dir, "netman", "journals", "*.json"]))
    assert Path.basename(file) == "#{command.request_id}.json"
  end

  test "enforces bounded journal retention", %{data_dir: data_dir} do
    journal = start_journal(data_dir, max_records: 1)
    first = envelope()

    second =
      envelope(
        request_id: "22222222-2222-4222-8222-222222222222",
        idempotency_key: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
      )

    assert {:reserved, request_id} = CommandJournal.reserve(first, journal)
    assert request_id == first.request_id
    assert {:error, %Error{code: :conflict}} = CommandJournal.reserve(second, journal)
  end

  test "marks incomplete commands unknown during restart recovery", %{data_dir: data_dir} do
    name = unique_name()
    journal = start_journal(data_dir, name: name)
    command = envelope()

    assert {:reserved, request_id} = CommandJournal.reserve(command, journal)
    assert request_id == command.request_id
    assert :ok = CommandJournal.mark_running(command.request_id, journal)
    stop(journal)

    restarted = start_journal(data_dir, name: name)
    assert {:replay, {:unknown, request_id}} = CommandJournal.replay(command, restarted)
    assert request_id == command.request_id
  end

  test "rejects corrupt durable files on recovery", %{data_dir: data_dir} do
    journal_dir = Path.join([data_dir, "netman", "journals"])
    File.mkdir_p!(journal_dir)
    File.write!(Path.join(journal_dir, "11111111-1111-4111-8111-111111111111.json"), "{")

    assert {:error, {:journal_recovery_failed, _reason}} =
             CommandJournal.start_link(
               name: unique_name(),
               data_dir: data_dir,
               netman_id: @netman_id,
               capabilities: [@capability]
             )
  end

  test "isolates journal state by concrete Netman target ID", %{data_dir: data_dir} do
    journal = start_journal(data_dir)
    foreign = envelope(target_id: "netman-west-1")

    assert {:error, %Error{code: :invalid}} = CommandJournal.reserve(foreign, journal)
    refute File.exists?(Path.join([data_dir, "netman", "journals", "#{foreign.request_id}.json"]))
  end

  defp start_journal(data_dir, opts \\ []) do
    name = Keyword.get(opts, :name, unique_name())

    {:ok, pid} =
      CommandJournal.start_link(
        [name: name, data_dir: data_dir, netman_id: @netman_id, capabilities: [@capability]] ++
          Keyword.drop(opts, [:name])
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    name
  end

  defp stop(name), do: GenServer.stop(name, :normal)
  defp unique_name, do: {:global, {__MODULE__, System.unique_integer([:positive])}}

  defp envelope(opts \\ []) do
    payload = profile_payload()
    {:ok, digest} = Digest.calculate(payload)

    %Envelope{
      protocol_version: 1,
      request_id: Keyword.get(opts, :request_id, "11111111-1111-4111-8111-111111111111"),
      target_type: :netman,
      target_id: Keyword.get(opts, :target_id, @netman_id),
      operation: "netman.profiles.validate",
      idempotency_key:
        Keyword.get(opts, :idempotency_key, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"),
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
