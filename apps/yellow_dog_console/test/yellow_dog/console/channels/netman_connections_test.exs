defmodule YellowDog.Console.NetmanConnectionsTest do
  use ExUnit.Case, async: false

  alias YellowDog.Console.NetmanConnections
  alias YellowDog.Management.Netmans
  alias YellowDog.ManagementCore
  alias YellowDog.Sync.Message
  alias YellowDog.Sync.Message.Journal

  setup do
    :ok = NetmanConnections.reset()
    on_exit(fn -> NetmanConnections.reset() end)
    :ok
  end

  test "promotes one concrete connection and replaces it only after activation" do
    netman_id = unique_id("replacement")
    register_netman(netman_id)
    parent = self()
    old = replacement_process(parent)
    replacement = idle_process()

    :ok = Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "management:netman:#{netman_id}")

    assert :ok = NetmanConnections.begin_candidate(netman_id, old)

    assert {:ok, nil} =
             NetmanConnections.activate(
               netman_id,
               old,
               identity(netman_id, "old"),
               status(netman_id)
             )

    assert_receive {:netman_connection, :online, %{netman_id: ^netman_id}}
    assert NetmanConnections.connected?(netman_id)

    assert :ok = NetmanConnections.begin_candidate(netman_id, replacement)
    assert {:ok, %{channel_pid: ^old}} = NetmanConnections.get(netman_id)

    assert {:ok, ^old} =
             NetmanConnections.activate(
               netman_id,
               replacement,
               identity(netman_id, "replacement"),
               status(netman_id, "replacement")
             )

    assert_receive {:replacement_notice, ^old, ^replacement}

    assert {:ok,
            %{
              netman_id: ^netman_id,
              channel_pid: ^replacement,
              identity: %{target_type: :netman, id: ^netman_id},
              status: %{target_type: :netman, target_id: ^netman_id},
              connected?: true,
              pending_request_count: 0
            }} = NetmanConnections.get(netman_id)

    stop_process(replacement)
  end

  test "keeps the active connection when a replacement Journal cannot reconcile" do
    netman_id = unique_id("replacement-journal")
    register_netman(netman_id)
    old = replacement_process(self())
    replacement = idle_process()

    assert :ok = NetmanConnections.begin_candidate(netman_id, old)

    assert {:ok, nil} =
             NetmanConnections.activate(
               netman_id,
               old,
               identity(netman_id, "old"),
               status(netman_id, "old")
             )

    assert :ok = NetmanConnections.begin_candidate(netman_id, replacement)
    assert :ok = Netmans.reset()

    encoded =
      %Journal{target_type: :netman, target_id: netman_id, entries: []}
      |> then(fn journal ->
        assert {:ok, encoded} = Message.encode(journal)
        encoded
      end)

    assert {:error, :not_found} =
             NetmanConnections.activate_after_journal(
               netman_id,
               replacement,
               identity(netman_id, "replacement"),
               status(netman_id, "replacement"),
               encoded
             )

    assert {:ok, %{channel_pid: ^old}} = NetmanConnections.get(netman_id)
    assert NetmanConnections.connected?(netman_id)
    refute_receive {:replacement_notice, ^old, ^replacement}, 50

    stop_process(old)
    stop_process(replacement)
  end

  test "bounds candidates and expires only the matching handshake" do
    registry =
      start_registry(
        handshake_timeout_ms: 20,
        max_candidates: 1,
        max_candidates_per_netman: 1,
        max_pending_requests_per_netman: 1
      )

    netman_id = unique_id("candidate")
    candidate = timeout_process(self())
    blocked = idle_process()
    monitor = Process.monitor(candidate)

    assert :ok = NetmanConnections.begin_candidate(registry, netman_id, candidate)

    assert {:error, :candidate_limit} =
             NetmanConnections.begin_candidate(registry, unique_id("blocked"), blocked)

    assert_receive {:candidate_timed_out, ^candidate}, 200
    assert_receive {:DOWN, ^monitor, :process, ^candidate, _reason}, 200

    replacement = idle_process()
    assert :ok = NetmanConnections.begin_candidate(registry, netman_id, replacement)

    stop_process(blocked)
    stop_process(replacement)
  end

  test "correlates pending requests and ignores stale, mismatched, and late results" do
    netman_id = unique_id("correlation")
    register_netman(netman_id)
    channel = forwarder_process(self())
    activate(netman_id, channel)

    first = summary(netman_id, "request-first", "netman.runtime.capabilities.get")
    second = summary(netman_id, "request-second", "netman.runtime.apply_mode.get")

    first_task = Task.async(fn -> NetmanConnections.request(first, "first", 1_000) end)
    second_task = Task.async(fn -> NetmanConnections.request(second, "second", 1_000) end)

    assert_receive {:management_push, ^channel, "first"}
    assert_receive {:management_push, ^channel, "second"}

    assert :ok =
             NetmanConnections.resolve_result(
               netman_id,
               channel,
               result(second, {:ok, %{"mode" => "managed"}})
             )

    assert {:ok, %{"mode" => "managed"}} = Task.await(second_task)

    assert :ignored =
             NetmanConnections.resolve_result(
               netman_id,
               channel,
               result(%{first | operation: second.operation}, {:ok, %{}})
             )

    assert :ok =
             NetmanConnections.resolve_result(
               netman_id,
               channel,
               result(first, {:ok, %{"capabilities" => []}})
             )

    assert {:ok, %{"capabilities" => []}} = Task.await(first_task)

    assert :ignored =
             NetmanConnections.resolve_result(
               netman_id,
               channel,
               result(first, {:ok, %{}})
             )

    timed = summary(netman_id, "request-timeout", "netman.runtime.capabilities.get")
    timed_task = Task.async(fn -> NetmanConnections.request(timed, "timed", 10) end)
    assert_receive {:management_push, ^channel, "timed"}
    assert {:error, :timeout} = Task.await(timed_task)

    assert :ignored =
             NetmanConnections.resolve_result(netman_id, channel, result(timed, {:ok, %{}}))

    stop_process(channel)
  end

  test "persists status from only the active PID and disconnects pending work" do
    netman_id = unique_id("ownership")
    register_netman(netman_id)
    active = forwarder_process(self())
    stale = idle_process()
    activate(netman_id, active)
    offline = %{status(netman_id, "offline") | state: :offline}

    assert {:error, :not_connected} = NetmanConnections.update_status(netman_id, stale, offline)
    assert {:ok, %{status: :registered}} = ManagementCore.get_netman(netman_id)

    assert :ok = NetmanConnections.update_status(netman_id, active, offline)
    assert {:ok, %{status: :offline}} = ManagementCore.get_netman(netman_id)

    pending = summary(netman_id, "request-disconnect", "netman.runtime.capabilities.get")
    task = Task.async(fn -> NetmanConnections.request(pending, "pending", 1_000) end)
    assert_receive {:management_push, ^active, "pending"}

    assert :ok = NetmanConnections.disconnect(netman_id, active)
    assert {:error, :not_connected} = Task.await(task)
    refute NetmanConnections.connected?(netman_id)
    assert {:ok, %{status: :offline}} = ManagementCore.get_netman(netman_id)

    stop_process(active)
    stop_process(stale)
  end

  test "fails closed when the registry is unavailable" do
    missing = :"missing_netman_connections_#{System.unique_integer([:positive])}"
    netman_id = unique_id("missing")
    channel = idle_process()

    refute NetmanConnections.connected?(missing, netman_id)
    assert :error = NetmanConnections.get(missing, netman_id)
    assert {:error, :internal} = NetmanConnections.begin_candidate(missing, netman_id, channel)
    assert {:error, :not_connected} = NetmanConnections.touch(missing, netman_id, channel)
    assert {:error, :not_connected} = NetmanConnections.disconnect(missing, netman_id, channel)

    stop_process(channel)
  end

  defp activate(netman_id, channel) do
    assert :ok = NetmanConnections.begin_candidate(netman_id, channel)

    assert {:ok, nil} =
             NetmanConnections.activate(
               netman_id,
               channel,
               identity(netman_id),
               status(netman_id)
             )
  end

  defp identity(netman_id, suffix \\ "primary") do
    %{
      target_type: :netman,
      id: netman_id,
      name: "Netman #{suffix}",
      version: "1.0.0",
      profile: "vm",
      capabilities: ["runtime.capabilities"],
      config_revision: String.duplicate("a", 64)
    }
  end

  defp status(netman_id, marker \\ "primary") do
    %{
      target_type: :netman,
      target_id: netman_id,
      state: :online,
      details: %{"marker" => marker},
      observed_at: DateTime.utc_now(:second)
    }
  end

  defp summary(netman_id, request_id, operation) do
    %{
      request_id: request_id,
      target_type: :netman,
      target_id: netman_id,
      operation: operation
    }
  end

  defp result(summary, outcome) do
    %{
      tag: :result,
      request_id: summary.request_id,
      target_type: summary.target_type,
      operation: summary.operation,
      outcome: outcome
    }
  end

  defp register_netman(netman_id) do
    assert {:ok, _netman} = ManagementCore.register_netman(%{id: netman_id, profile: :vm})
  end

  defp start_registry(opts) do
    name = :"netman_connections_#{System.unique_integer([:positive])}"
    {:ok, pid} = NetmanConnections.start_link(Keyword.put(opts, :name, name))
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    name
  end

  defp idle_process do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp forwarder_process(parent) do
    spawn(fn -> forward(parent) end)
  end

  defp forward(parent) do
    receive do
      {:netman_management_push, encoded} ->
        send(parent, {:management_push, self(), encoded})
        forward(parent)

      :stop ->
        :ok
    end
  end

  defp replacement_process(parent) do
    spawn(fn ->
      receive do
        {:netman_connection_replaced, new_pid} ->
          send(parent, {:replacement_notice, self(), new_pid})
      end
    end)
  end

  defp timeout_process(parent) do
    spawn(fn ->
      receive do
        :netman_handshake_timeout -> send(parent, {:candidate_timed_out, self()})
      end
    end)
  end

  defp stop_process(pid) do
    if Process.alive?(pid), do: send(pid, :stop)
  end

  defp unique_id(prefix),
    do: "#{prefix}-#{Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)}"
end
