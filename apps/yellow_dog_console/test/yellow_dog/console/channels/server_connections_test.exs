defmodule YellowDog.Console.ServerConnectionsTest do
  use ExUnit.Case, async: false

  alias YellowDog.Console.ServerConnections
  alias YellowDog.ManagementCore

  setup do
    :ok = ServerConnections.reset()
    on_exit(fn -> ServerConnections.reset() end)
    :ok
  end

  test "uses explicit bounded defaults and rejects malformed limit configuration" do
    assert 5_000 == Application.fetch_env!(:yellow_dog_console, :server_handshake_timeout_ms)
    assert 256 == Application.fetch_env!(:yellow_dog_console, :server_max_candidates)

    assert 1 ==
             Application.fetch_env!(
               :yellow_dog_console,
               :server_max_candidates_per_server
             )

    assert 128 ==
             Application.fetch_env!(
               :yellow_dog_console,
               :server_max_pending_requests_per_server
             )

    name = :"invalid_server_connections_#{System.unique_integer([:positive])}"
    previous = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous) end)

    assert {:error, {:invalid_server_connections_config, _values}} =
             ServerConnections.start_link(
               name: name,
               handshake_timeout_ms: 0,
               max_candidates: 1,
               max_candidates_per_server: 1,
               max_pending_requests_per_server: 1
             )
  end

  test "promotes a candidate atomically and exposes safe connection inspection" do
    server_id = unique_id("connection")
    register_server(server_id)
    channel = idle_process()
    identity = identity(server_id)
    status = status(server_id)

    assert :ok = ServerConnections.begin_candidate(server_id, channel)
    refute ServerConnections.connected?(server_id)
    assert :error = ServerConnections.get(server_id)

    assert {:ok, nil} = ServerConnections.activate(server_id, channel, identity, status)
    assert ServerConnections.connected?(server_id)

    assert {:ok,
            %{
              server_id: ^server_id,
              channel_pid: ^channel,
              identity: ^identity,
              status: ^status,
              connected?: true,
              connected_at: %DateTime{},
              last_seen_at: %DateTime{}
            }} = ServerConnections.get(server_id)

    assert [%{server_id: ^server_id}] = ServerConnections.list()
    stop_process(channel)
  end

  test "keeps the old active connection until a replacement candidate activates" do
    server_id = unique_id("replacement")
    register_server(server_id)
    parent = self()
    old_channel = replacement_process(parent)
    new_channel = idle_process()

    assert :ok = ServerConnections.join_candidate(server_id, old_channel)

    assert {:ok, nil} =
             ServerConnections.activate(
               server_id,
               old_channel,
               identity(server_id, "old"),
               status(server_id, "old")
             )

    assert :ok = ServerConnections.begin_candidate(server_id, new_channel)
    assert {:ok, %{channel_pid: ^old_channel}} = ServerConnections.get(server_id)

    assert {:ok, ^old_channel} =
             ServerConnections.activate(
               server_id,
               new_channel,
               identity(server_id, "new"),
               status(server_id, "new")
             )

    assert_receive {:replacement_notice, ^old_channel, ^new_channel}

    assert {:ok, %{channel_pid: ^new_channel, connected?: true}} =
             ServerConnections.get(server_id)

    stop_process(new_channel)
  end

  test "candidate disconnect cannot evict the active connection" do
    server_id = unique_id("candidate-disconnect")
    register_server(server_id)
    active = idle_process()
    candidate = idle_process()

    assert :ok = ServerConnections.begin_candidate(server_id, active)

    assert {:ok, nil} =
             ServerConnections.activate(
               server_id,
               active,
               identity(server_id),
               status(server_id)
             )

    assert :ok = ServerConnections.begin_candidate(server_id, candidate)
    assert :ok = ServerConnections.disconnect(server_id, candidate)

    assert ServerConnections.connected?(server_id)
    assert {:ok, %{channel_pid: ^active}} = ServerConnections.get(server_id)

    stop_process(active)
    stop_process(candidate)
  end

  test "active disconnect marks both connection registry and ManagementCore offline" do
    server_id = unique_id("active-disconnect")
    register_server(server_id)
    channel = idle_process()

    assert :ok = ServerConnections.begin_candidate(server_id, channel)

    assert {:ok, nil} =
             ServerConnections.activate(
               server_id,
               channel,
               identity(server_id),
               status(server_id)
             )

    assert :ok = ServerConnections.disconnect(server_id, channel)
    refute ServerConnections.connected?(server_id)

    assert {:ok, %{channel_pid: nil, connected?: false}} =
             ServerConnections.get(server_id)

    assert {:ok, %{status: :offline}} = ManagementCore.get_server(server_id)
    stop_process(channel)
  end

  test "broadcasts presence only on the concrete server topic" do
    server_id = unique_id("broadcast")
    other_id = unique_id("other")
    register_server(server_id)
    channel = idle_process()

    :ok =
      Phoenix.PubSub.subscribe(
        YellowDog.Console.PubSub,
        "management:server:#{server_id}"
      )

    :ok =
      Phoenix.PubSub.subscribe(
        YellowDog.Console.PubSub,
        "management:server:#{other_id}"
      )

    assert :ok = ServerConnections.begin_candidate(server_id, channel)

    assert {:ok, nil} =
             ServerConnections.activate(
               server_id,
               channel,
               identity(server_id),
               status(server_id)
             )

    assert_receive {:server_connection, :online, %{server_id: ^server_id}}
    refute_receive {:server_connection, _, %{server_id: ^other_id}}
    stop_process(channel)
  end

  test "bounds candidates globally and per concrete server without evicting active" do
    registry =
      start_registry(
        handshake_timeout_ms: 5_000,
        max_candidates: 2,
        max_candidates_per_server: 1
      )

    server_id = unique_id("bounded")
    active = idle_process()
    first = idle_process()
    same_id = idle_process()
    second = idle_process()
    over_global = idle_process()

    assert :ok = ServerConnections.begin_candidate(registry, server_id, active)

    assert {:ok, nil} =
             ServerConnections.activate(
               registry,
               server_id,
               active,
               identity(server_id),
               status(server_id)
             )

    assert :ok = ServerConnections.begin_candidate(registry, server_id, first)

    assert {:error, :candidate_limit} =
             ServerConnections.begin_candidate(registry, server_id, same_id)

    assert :ok =
             ServerConnections.begin_candidate(registry, unique_id("second"), second)

    assert {:error, :candidate_limit} =
             ServerConnections.begin_candidate(registry, unique_id("global"), over_global)

    assert {:ok, %{channel_pid: ^active, connected?: true}} =
             ServerConnections.get(registry, server_id)

    Enum.each([active, first, same_id, second, over_global], &stop_process/1)
  end

  test "handshake timeout removes and stops only the matching candidate" do
    registry =
      start_registry(
        handshake_timeout_ms: 20,
        max_candidates: 2,
        max_candidates_per_server: 1
      )

    server_id = unique_id("timeout")
    candidate = timeout_process(self())
    monitor = Process.monitor(candidate)

    assert :ok = ServerConnections.begin_candidate(registry, server_id, candidate)
    assert_receive {:candidate_timed_out, ^candidate}, 200
    assert_receive {:DOWN, ^monitor, :process, ^candidate, _reason}, 200

    replacement = idle_process()
    assert :ok = ServerConnections.begin_candidate(registry, server_id, replacement)
    stop_process(replacement)
  end

  test "activation and DOWN cleanup make stale candidate timers harmless" do
    registry =
      start_registry(
        handshake_timeout_ms: 40,
        max_candidates: 2,
        max_candidates_per_server: 1
      )

    active_id = unique_id("stale-timer")
    active = idle_process()
    assert :ok = ServerConnections.begin_candidate(registry, active_id, active)

    assert {:ok, nil} =
             ServerConnections.activate(
               registry,
               active_id,
               active,
               identity(active_id),
               status(active_id)
             )

    dead_id = unique_id("down")
    dead = idle_process()
    assert :ok = ServerConnections.begin_candidate(registry, dead_id, dead)
    Process.exit(dead, :kill)

    eventually(fn ->
      replacement = idle_process()
      assert :ok = ServerConnections.begin_candidate(registry, dead_id, replacement)
      stop_process(replacement)
    end)

    Process.sleep(60)
    assert ServerConnections.connected?(registry, active_id)
    stop_process(active)
  end

  test "candidate disconnect and reset cancel handshake timers" do
    registry =
      start_registry(
        handshake_timeout_ms: 20,
        max_candidates: 2,
        max_candidates_per_server: 1
      )

    disconnected_id = unique_id("timer-disconnect")
    disconnected = timeout_process(self())
    assert :ok = ServerConnections.begin_candidate(registry, disconnected_id, disconnected)
    assert :ok = ServerConnections.disconnect(registry, disconnected_id, disconnected)

    reset_id = unique_id("timer-reset")
    reset_candidate = timeout_process(self())
    assert :ok = ServerConnections.begin_candidate(registry, reset_id, reset_candidate)
    assert :ok = ServerConnections.reset(registry)

    Process.sleep(40)
    assert Process.alive?(disconnected)
    assert Process.alive?(reset_candidate)
    refute_receive {:candidate_timed_out, _candidate}
    stop_process(disconnected)
    stop_process(reset_candidate)
  end

  test "periodic status persists before updating only the active PID" do
    server_id = unique_id("status")
    register_server(server_id)
    active = idle_process()
    stale = idle_process()

    assert :ok = ServerConnections.begin_candidate(server_id, active)

    assert {:ok, nil} =
             ServerConnections.activate(
               server_id,
               active,
               identity(server_id),
               status(server_id)
             )

    offline = %{status(server_id, "periodic") | state: :offline}

    assert {:error, :not_connected} =
             ServerConnections.update_status(server_id, stale, offline)

    assert {:ok, %{status: :registered}} = ManagementCore.get_server(server_id)

    assert :ok = ServerConnections.update_status(server_id, active, offline)
    assert {:ok, %{status: :offline}} = ManagementCore.get_server(server_id)
    assert {:ok, %{status: ^offline}} = ServerConnections.get(server_id)

    stop_process(active)
    stop_process(stale)
  end

  test "registry calls fail closed when the registry is unavailable" do
    missing = :"missing_server_connections_#{System.unique_integer([:positive])}"
    server_id = unique_id("missing")
    channel = idle_process()

    refute ServerConnections.connected?(missing, server_id)
    assert :error = ServerConnections.get(missing, server_id)
    assert {:error, :internal} = ServerConnections.begin_candidate(missing, server_id, channel)
    assert {:error, :not_connected} = ServerConnections.touch(missing, server_id, channel)
    assert {:error, :not_connected} = ServerConnections.disconnect(missing, server_id, channel)
    stop_process(channel)
  end

  defp identity(server_id, suffix \\ "primary") do
    %{
      id: server_id,
      name: "Server #{suffix}",
      version: "1.0.0",
      profile: "dns_only",
      capabilities: ["runtime.services"],
      config_revision: String.duplicate("a", 64)
    }
  end

  defp status(server_id, marker \\ "primary") do
    %{
      target_type: :server,
      target_id: server_id,
      state: :online,
      details: %{"marker" => marker},
      observed_at: DateTime.utc_now(:second)
    }
  end

  defp register_server(server_id) do
    assert {:ok, _server} =
             ManagementCore.register_server(%{id: server_id, profile: :dns_only})
  end

  defp idle_process do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp replacement_process(parent) do
    spawn(fn ->
      receive do
        {:server_connection_replaced, new_pid} ->
          send(parent, {:replacement_notice, self(), new_pid})
      end
    end)
  end

  defp timeout_process(parent) do
    spawn(fn ->
      receive do
        :server_handshake_timeout ->
          send(parent, {:candidate_timed_out, self()})
      end
    end)
  end

  defp start_registry(opts) do
    name = :"server_connections_#{System.unique_integer([:positive])}"
    {:ok, pid} = ServerConnections.start_link(Keyword.put(opts, :name, name))
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    name
  end

  defp stop_process(pid) do
    if Process.alive?(pid), do: send(pid, :stop)
  end

  defp eventually(assertion, attempts \\ 20)
  defp eventually(assertion, 0), do: assertion.()

  defp eventually(assertion, attempts) do
    assertion.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(5)
      eventually(assertion, attempts - 1)
  end

  defp unique_id(prefix),
    do: "#{prefix}-#{Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)}"
end
