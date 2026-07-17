defmodule YellowDog.ServerAgent.HeartbeatStatusTest do
  use ExUnit.Case, async: true

  alias YellowDog.ServerAgent.Client
  alias YellowDog.ServerAgent.Heartbeat
  alias YellowDog.ServerAgent.Status
  alias YellowDog.Sync.Identity.Server

  @revision String.duplicate("b", 64)

  defmodule ApplyStoreStub do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :snapshot),
        name: Keyword.fetch!(opts, :name)
      )
    end

    @impl GenServer
    def init(snapshot), do: {:ok, snapshot}

    @impl GenServer
    def handle_call(:snapshot, _from, snapshot), do: {:reply, {:ok, snapshot}, snapshot}
  end

  defmodule OneShotHeartbeatStub do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :snapshot),
        name: Keyword.fetch!(opts, :name)
      )
    end

    @impl GenServer
    def init(snapshot), do: {:ok, snapshot}

    @impl GenServer
    def handle_call(:snapshot, _from, snapshot), do: {:stop, :normal, snapshot, snapshot}
  end

  test "Heartbeat accepts only bounded local connection states" do
    name = unique_name(:heartbeat)
    {:ok, heartbeat} = Heartbeat.start_link(name: name, agent_id: "server-east-1")

    for state <- [:disabled, :connecting, :handshaking, :active, :backoff, :unavailable] do
      assert :ok = Heartbeat.record_connection_state(name, state)
      assert Heartbeat.snapshot(name).connection_state == state
    end

    assert {:error, :invalid_connection_state} =
             Heartbeat.record_connection_state(name, {:raw, "secret"})

    assert Heartbeat.snapshot(name).connection_state == :unavailable
    assert Process.alive?(heartbeat)
  end

  test "Status projects only validated Server identity and safe local state" do
    heartbeat_name = unique_name(:heartbeat)
    {:ok, _heartbeat} = Heartbeat.start_link(name: heartbeat_name, agent_id: "server-east-1")

    identity = %Server{
      id: "server-east-1",
      name: "Server East",
      version: "1.2.3",
      profile: "dns_only",
      capabilities: ["runtime.services"],
      config_revision: @revision
    }

    assert %{
             agent: :yellow_dog_server,
             running: true,
             status: :idle,
             agent_id: "server-east-1",
             identity: %{
               target_type: :server,
               id: "server-east-1",
               name: "Server East",
               version: "1.2.3"
             },
             profile: "dns_only",
             capabilities: ["runtime.services"],
             config_revision: @revision,
             connection_state: :disabled,
             apply_status: nil,
             started_at: %DateTime{},
             last_heartbeat_at: %DateTime{}
           } =
             Status.snapshot(
               heartbeat: heartbeat_name,
               identity: identity,
               client: nil,
               config_apply_store: nil
             )
  end

  test "Status rejects arbitrary identity and option terms without exposing them" do
    secret = "do-not-expose"

    assert {:error, :invalid_options} =
             Status.snapshot(identity: %{token: secret}, unknown: secret)

    refute inspect(Status.snapshot(identity: %{token: secret}, unknown: secret)) =~ secret
  end

  test "Status keeps named agents isolated and rejects cross-wired identity" do
    east_heartbeat = unique_name(:east_heartbeat)
    west_heartbeat = unique_name(:west_heartbeat)

    {:ok, _east} = Heartbeat.start_link(name: east_heartbeat, agent_id: "server-east-1")
    {:ok, _west} = Heartbeat.start_link(name: west_heartbeat, agent_id: "server-west-1")

    east = identity("server-east-1")
    west = identity("server-west-1")

    assert %{agent_id: "server-east-1", identity: %{id: "server-east-1"}} =
             Status.snapshot(heartbeat: east_heartbeat, identity: east)

    assert %{agent_id: "server-west-1", identity: %{id: "server-west-1"}} =
             Status.snapshot(heartbeat: west_heartbeat, identity: west)

    assert {:error, :invalid_state} =
             Status.snapshot(heartbeat: east_heartbeat, identity: west)
  end

  test "Status allowlists local apply evidence and connection state" do
    heartbeat_name = unique_name(:heartbeat)
    client_name = unique_name(:client)
    apply_store_name = unique_name(:apply_store)
    secret = "raw-apply-secret"

    {:ok, _heartbeat} = Heartbeat.start_link(name: heartbeat_name, agent_id: "server-east-1")
    {:ok, _client} = Client.start_link(enabled: false, name: client_name)

    {:ok, _apply_store} =
      ApplyStoreStub.start_link(
        name: apply_store_name,
        snapshot: %{
          runtime_status: :unknown,
          attempt: %{
            status: :failed,
            version: 7,
            failure: %{reason: secret},
            payload: %{"token" => secret}
          },
          data_dir: "/secret/path",
          raw_error: {:error, secret}
        }
      )

    snapshot =
      Status.snapshot(
        heartbeat: heartbeat_name,
        identity: identity("server-east-1"),
        client: client_name,
        config_apply_store: apply_store_name
      )

    assert snapshot.connection_state == :disabled
    assert snapshot.apply_status == %{runtime_status: :unknown, state: :failed, version: 7}
    refute inspect(snapshot) =~ secret
    refute inspect(snapshot) =~ "/secret/path"
  end

  test "Status remains safe when Heartbeat restarts after its snapshot" do
    heartbeat_name = unique_name(:one_shot_heartbeat)
    now = DateTime.utc_now(:second)

    {:ok, _heartbeat} =
      OneShotHeartbeatStub.start_link(
        name: heartbeat_name,
        snapshot: %Heartbeat{
          agent_id: "server-east-1",
          status: :idle,
          started_at: now,
          last_heartbeat_at: now,
          connection_state: :disabled
        }
      )

    assert %{running: true, connection_state: :disabled} =
             Status.snapshot(
               heartbeat: heartbeat_name,
               identity: identity("server-east-1"),
               client: nil
             )
  end

  defp identity(id) do
    %Server{
      id: id,
      name: id,
      version: "1.2.3",
      profile: "dns_only",
      capabilities: ["runtime.services"],
      config_revision: @revision
    }
  end

  defp unique_name(prefix) do
    :"#{prefix}-#{System.unique_integer([:positive])}"
  end
end
