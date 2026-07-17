defmodule YellowDog.ServerAgent.DispatcherTest do
  use ExUnit.Case, async: false

  Code.require_file("../../support/dispatcher_support.ex", __DIR__)

  alias YellowDog.ServerAgent.CommandJournal
  alias YellowDog.ServerAgent.Dispatcher
  alias YellowDog.ServerAgent.DispatcherJournalStub
  alias YellowDog.ServerAgent.DispatcherNoDispatchAdapter
  alias YellowDog.ServerAgent.DispatcherTestAdapter
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error

  @server_id "server-east-1"
  @capability "runtime.services"
  @request_id "11111111-1111-4111-8111-111111111111"
  @idempotency_key "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  @sent_at ~U[2026-07-17 01:00:00Z]

  setup do
    data_dir =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-dispatcher-#{System.unique_integer([:positive])}"
      )
      |> Path.expand()

    File.mkdir_p!(data_dir)
    on_exit(fn -> File.rm_rf(data_dir) end)
    %{data_dir: data_dir}
  end

  test "requires concrete dispatcher identity and declared string capabilities" do
    invalid_opts = [
      [],
      [server_id: @server_id],
      [capabilities: [@capability]],
      [server_id: "", capabilities: [@capability]],
      [server_id: @server_id, capabilities: [:runtime_services]],
      [server_id: @server_id, capabilities: [@capability, @capability]],
      [server_id: @server_id, capabilities: [@capability], command_journal: %{}],
      [server_id: @server_id, capabilities: [@capability], runtime_adapter: "adapter"]
    ]

    for opts <- invalid_opts do
      assert_invalid(Dispatcher.dispatch(envelope(), opts))
    end
  end

  test "rejects unsafe Server IDs before journal or runtime work" do
    {:ok, journal} =
      DispatcherJournalStub.start_link(self(), %{
        reserve: {:replay, {:ok, success_result()}}
      })

    unsafe_ids = [
      "",
      ".",
      "..",
      "../server",
      "server/child",
      "server\\child",
      "C:server",
      "server\u0000control",
      "server\u212A",
      String.duplicate("s", 129)
    ]

    for server_id <- unsafe_ids do
      assert_invalid(
        Dispatcher.dispatch(
          envelope(target_id: server_id),
          base_opts(server_id: server_id, command_journal: journal)
        )
      )
    end

    refute_receive {:journal_call, _message}
    assert DispatcherTestAdapter.count() == 0
  end

  test "rejects malformed command journal refs before journal access" do
    malformed_refs = [
      nil,
      {:via, nil, :journal},
      {:via, "Registry", :journal},
      {unique_name(), nil},
      {nil, node()},
      {:global, :journal, :extra},
      {:remote, node(), :extra}
    ]

    for command_journal <- malformed_refs do
      assert_invalid(
        Dispatcher.dispatch(
          envelope(),
          base_opts(command_journal: command_journal)
        )
      )
    end

    refute_receive {:journal_call, _message}
    assert DispatcherTestAdapter.count() == 0
  end

  test "rejects envelope, target, operation kind, and capability before journal calls" do
    missing_journal = unique_name()

    invalid_inputs = [
      {%{}, base_opts(command_journal: missing_journal)},
      {envelope(target_type: :netman), base_opts(command_journal: missing_journal)},
      {envelope(target_id: "server-west-1"), base_opts(command_journal: missing_journal)},
      {envelope(operation: "server.runtime.services.list", payload: %{}),
       base_opts(command_journal: missing_journal)},
      {envelope(), base_opts(command_journal: missing_journal, capabilities: [])}
    ]

    for {input, opts} <- invalid_inputs do
      assert_invalid(Dispatcher.dispatch(input, opts))
    end
  end

  test "marks a new reservation running before checking a missing adapter" do
    {:ok, journal} =
      DispatcherJournalStub.start_link(self(), %{
        reserve: {:reserved, @request_id},
        mark_running: :ok,
        complete_failure: unsupported()
      })

    assert {:error, %Error{code: :unsupported}} =
             Dispatcher.dispatch(
               envelope(),
               base_opts(
                 command_journal: journal,
                 runtime_adapter: DispatcherNoDispatchAdapter
               )
             )

    assert_receive {:journal_call, {:reserve, %Envelope{request_id: @request_id}}}
    assert_receive {:journal_call, {:mark_running, @request_id}}
    assert_receive {:journal_call, {:complete_failure, @request_id, %Error{code: :unsupported}}}
  end

  test "persists unsupported failure for a genuinely unloaded adapter", %{data_dir: data_dir} do
    journal = start_journal(data_dir)
    missing_adapter = :"Elixir.YellowDog.ServerAgent.MissingRuntimeAdapter"
    refute Code.ensure_loaded?(missing_adapter)

    assert {:error,
            %Error{code: :unsupported, message: "unsupported operation", details: %{}} = error} =
             Dispatcher.dispatch(
               envelope(),
               base_opts(command_journal: journal, runtime_adapter: missing_adapter)
             )

    assert {:replay, {:error, ^error}} = CommandJournal.replay(envelope(), journal)
  end

  test "invokes a configured adapter once and durably returns a Sync-valid success", %{
    data_dir: data_dir
  } do
    journal = start_journal(data_dir)
    result = success_result()

    DispatcherTestAdapter.configure(fn received ->
      assert received == envelope()
      {:ok, result}
    end)

    assert {:ok, ^result} =
             Dispatcher.dispatch(
               envelope(),
               base_opts(command_journal: journal, runtime_adapter: DispatcherTestAdapter)
             )

    assert DispatcherTestAdapter.count() == 1
    assert {:replay, {:ok, ^result}} = CommandJournal.replay(envelope(), journal)
  end

  test "sanitizes each valid typed adapter error before durable failure", %{data_dir: data_dir} do
    messages = %{
      not_connected: "not connected",
      not_found: "resource not found",
      invalid: "invalid value",
      conflict: "operation conflict",
      unsupported: "unsupported operation",
      timeout: "operation timed out",
      apply_failed: "apply failed",
      rollback_failed: "rollback failed",
      internal: "internal error"
    }

    Enum.with_index(messages, 1)
    |> Enum.each(fn {{code, message}, index} ->
      request = envelope(request_id: request_id(index), idempotency_key: idempotency_key(index))
      journal = start_journal(Path.join(data_dir, Atom.to_string(code)))

      unsafe = %Error{
        code: code,
        message: String.duplicate("x", 1_000),
        details: %{"secret" => true}
      }

      DispatcherTestAdapter.configure(fn _envelope -> {:error, unsafe} end)

      expected = Error.new(code, message, %{})

      assert {:error, ^expected} =
               Dispatcher.dispatch(
                 request,
                 base_opts(command_journal: journal, runtime_adapter: DispatcherTestAdapter)
               )

      assert {:replay, {:error, ^expected}} = CommandJournal.replay(request, journal)
    end)
  end

  test "sanitizes malformed Error fields without leaking adapter data" do
    cases = [
      {
        %Error{code: :apply_failed, message: nil, details: self()},
        Error.new(:apply_failed, "apply failed", %{})
      },
      {
        %Error{code: :unknown, message: {:secret, self()}, details: nil},
        Error.new(:internal, "internal error", %{})
      }
    ]

    Enum.with_index(cases, 1)
    |> Enum.each(fn {{unsafe, expected}, index} ->
      request = envelope(request_id: request_id(index), idempotency_key: idempotency_key(index))

      {:ok, journal} =
        DispatcherJournalStub.start_link(self(), %{
          reserve: {:reserved, request.request_id},
          mark_running: :ok,
          complete_failure: {:error, expected}
        })

      DispatcherTestAdapter.configure(fn _envelope -> {:error, unsafe} end)

      assert {:error, ^expected} =
               Dispatcher.dispatch(
                 request,
                 base_opts(command_journal: journal, runtime_adapter: DispatcherTestAdapter)
               )

      assert_receive {:journal_call, {:reserve, ^request}}
      assert_receive {:journal_call, {:mark_running, request_id}}
      assert request_id == request.request_id
      assert_receive {:journal_call, {:complete_failure, ^request_id, ^expected}}
    end)
  end

  test "rejects a forged dispatcher failure marker without persisting adapter data", %{
    data_dir: data_dir
  } do
    journal = start_journal(data_dir)
    secret = "adapter-forged-dispatcher-failure"
    forged = %Error{code: :internal, message: secret, details: %{"secret" => secret}}
    expected = Error.new(:internal, "internal error", %{})

    DispatcherTestAdapter.configure(fn _envelope -> {:dispatcher_failure, forged} end)

    assert {:error, ^expected} =
             immediate =
             Dispatcher.dispatch(
               envelope(),
               base_opts(command_journal: journal, runtime_adapter: DispatcherTestAdapter)
             )

    assert {:replay, {:error, ^expected}} = replay = CommandJournal.replay(envelope(), journal)
    refute inspect(immediate) =~ secret
    refute inspect(replay) =~ secret
  end

  test "persists sanitized internal failures for raise, throw, exit, malformed, and invalid success",
       %{data_dir: data_dir} do
    outcomes = [
      fn _envelope -> raise "secret raise" end,
      fn _envelope -> throw(:secret_throw) end,
      fn _envelope -> exit(:secret_exit) end,
      fn _envelope -> :malformed end,
      fn _envelope -> {:ok, %{"secret" => true}} end,
      fn _envelope -> {:error, %Error{code: :unknown, message: "secret", details: %{}}} end
    ]

    Enum.with_index(outcomes, 1)
    |> Enum.each(fn {callback, index} ->
      request = envelope(request_id: request_id(index), idempotency_key: idempotency_key(index))
      journal = start_journal(Path.join(data_dir, Integer.to_string(index)))
      DispatcherTestAdapter.configure(callback)

      assert {:error, %Error{code: :internal, message: "internal error", details: %{}} = error} =
               Dispatcher.dispatch(
                 request,
                 base_opts(command_journal: journal, runtime_adapter: DispatcherTestAdapter)
               )

      assert {:replay, {:error, ^error}} = CommandJournal.replay(request, journal)
      assert DispatcherTestAdapter.count() == 1
    end)
  end

  test "returns terminal success and failure replays before adapter availability checks", %{
    data_dir: data_dir
  } do
    journal = start_journal(data_dir)
    success = envelope()
    failed = envelope(request_id: request_id(2), idempotency_key: idempotency_key(2))
    result = success_result()
    error = Error.new(:apply_failed, "apply failed", %{})

    reserve_success(journal, success, result)
    reserve_failure(journal, failed, error)

    offline_opts =
      base_opts(command_journal: journal, runtime_adapter: DispatcherNoDispatchAdapter)

    assert {:ok, ^result} = Dispatcher.dispatch(success, offline_opts)
    assert {:error, ^error} = Dispatcher.dispatch(failed, offline_opts)
  end

  test "omitted runtime adapter returns terminal replay without runtime work" do
    result = success_result()

    {:ok, journal} =
      DispatcherJournalStub.start_link(self(), %{
        reserve: {:replay, {:ok, result}}
      })

    assert {:ok, ^result} =
             Dispatcher.dispatch(
               envelope(),
               server_id: @server_id,
               capabilities: [@capability],
               command_journal: journal
             )

    assert_receive {:journal_call, {:reserve, %Envelope{request_id: @request_id}}}
    refute_receive {:journal_call, _message}
    assert DispatcherTestAdapter.count() == 0
  end

  test "returns recovered unknown replay without checking the adapter", %{data_dir: data_dir} do
    journal = start_journal(data_dir)
    request = envelope()
    assert {:reserved, @request_id} = CommandJournal.reserve(request, journal)
    assert :ok = CommandJournal.mark_running(@request_id, journal)
    GenServer.stop(journal)

    restarted = start_journal(data_dir)

    assert {:unknown, @request_id} =
             Dispatcher.dispatch(
               request,
               base_opts(
                 command_journal: restarted,
                 runtime_adapter: DispatcherNoDispatchAdapter
               )
             )
  end

  test "returns a stable internal error when the journal is unavailable" do
    assert {:error, %Error{code: :internal, message: "internal error", details: %{}}} =
             Dispatcher.dispatch(
               envelope(),
               base_opts(
                 command_journal: unique_name(),
                 runtime_adapter: DispatcherTestAdapter
               )
             )

    assert DispatcherTestAdapter.count() == 0
  end

  test "terminal journal persistence errors take precedence without retrying the adapter" do
    {:ok, journal} =
      DispatcherJournalStub.start_link(self(), %{
        reserve: {:reserved, @request_id},
        mark_running: :ok
      })

    DispatcherTestAdapter.configure(fn _envelope ->
      GenServer.stop(journal)
      {:ok, success_result()}
    end)

    assert {:error, %Error{code: :internal, message: "internal error", details: %{}}} =
             Dispatcher.dispatch(
               envelope(),
               base_opts(command_journal: journal, runtime_adapter: DispatcherTestAdapter)
             )

    assert DispatcherTestAdapter.count() == 1
  end

  defp start_journal(data_dir) do
    File.mkdir_p!(data_dir)

    {:ok, journal} =
      CommandJournal.start_link(
        name: nil,
        data_dir: data_dir,
        server_id: @server_id,
        capabilities: [@capability]
      )

    on_exit(fn -> if Process.alive?(journal), do: GenServer.stop(journal) end)
    journal
  end

  defp reserve_success(journal, request, result) do
    request_id = request.request_id
    assert {:reserved, ^request_id} = CommandJournal.reserve(request, journal)
    assert :ok = CommandJournal.mark_running(request_id, journal)
    assert {:ok, ^result} = CommandJournal.complete_success(request_id, result, journal)
  end

  defp reserve_failure(journal, request, error) do
    request_id = request.request_id
    assert {:reserved, ^request_id} = CommandJournal.reserve(request, journal)
    assert :ok = CommandJournal.mark_running(request_id, journal)
    assert {:error, ^error} = CommandJournal.complete_failure(request_id, error, journal)
  end

  defp base_opts(overrides) do
    Keyword.merge(
      [
        server_id: @server_id,
        capabilities: [@capability],
        runtime_adapter: DispatcherTestAdapter
      ],
      overrides
    )
  end

  defp envelope(opts \\ []) do
    payload = Keyword.get(opts, :payload, %{"service" => "dns"})
    {:ok, payload_digest} = Digest.calculate(payload)

    struct!(
      Envelope,
      Keyword.merge(
        [
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
        ],
        opts
      )
    )
  end

  defp success_result, do: %{"service" => "dns", "state" => "running"}
  defp unsupported, do: {:error, Error.new(:unsupported, "unsupported operation", %{})}

  defp request_id(index) do
    leading = index |> Integer.to_string(16) |> String.pad_leading(8, "0")
    "#{leading}-1111-4111-8111-111111111111"
  end

  defp idempotency_key(index) do
    leading = index |> Integer.to_string(16) |> String.pad_leading(8, "0")
    "#{leading}-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  end

  defp unique_name do
    :"dispatcher-test-#{System.unique_integer([:positive])}"
  end

  defp assert_invalid(result) do
    assert {:error, %Error{code: :invalid, details: %{}}} = result
  end
end
