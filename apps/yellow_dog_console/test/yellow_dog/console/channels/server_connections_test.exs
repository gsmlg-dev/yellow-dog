defmodule YellowDog.Console.ServerConnectionsTest do
  use ExUnit.Case, async: false

  alias YellowDog.Console.ServerConnections
  alias YellowDog.ManagementCore

  setup do
    :ok = ServerConnections.reset()
    on_exit(fn -> ServerConnections.reset() end)
    :ok
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

  defp stop_process(pid) do
    if Process.alive?(pid), do: send(pid, :stop)
  end

  defp unique_id(prefix),
    do: "#{prefix}-#{Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)}"
end
