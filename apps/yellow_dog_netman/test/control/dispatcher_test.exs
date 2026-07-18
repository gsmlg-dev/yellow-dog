defmodule YellowDog.Netman.Control.DispatcherTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias YellowDog.Netman.Control
  alias YellowDog.Netman.Control.Dispatcher
  alias YellowDog.Netman.Control.Result
  alias YellowDog.Netman.RuntimeState
  alias YellowDog.Netman.Types.Profile
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error

  @request_id "00000000-0000-0000-0000-000000000201"
  @idempotency_key "00000000-0000-0000-0000-000000000202"
  @sent_at ~U[2026-07-18 00:00:00Z]
  @revision String.duplicate("b", 64)

  setup do
    previous = Application.get_env(:yellow_dog_netman, Dispatcher)
    runtime_state = :sys.get_state(RuntimeState)

    Application.put_env(:yellow_dog_netman, Dispatcher,
      adapters: %{profiles: NetmanControlTestAdapter}
    )

    start_supervised!(NetmanControlTestAdapter)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:yellow_dog_netman, Dispatcher)
      else
        Application.put_env(:yellow_dog_netman, Dispatcher, previous)
      end

      :sys.replace_state(RuntimeState, fn _state -> runtime_state end)
    end)
  end

  test "rejects non-Netman targets and unknown operations without creating atoms" do
    assert {:error, %Error{code: :invalid}} = Control.dispatch(%{target_type: :netman})

    wrong_target = %{envelope("netman.profiles.list", %{}) | target_type: :server}
    assert {:error, %Error{code: :invalid}} = Control.dispatch(wrong_target)

    assert {:error, %Error{code: :unsupported}} =
             Control.dispatch(envelope("netman.runtime.capabilities.get", %{}))

    initial_atom_count = :erlang.system_info(:atom_count)

    assert {:error, %Error{code: :invalid}} =
             Control.dispatch(envelope("netman.untrusted.operation", %{}))

    assert :erlang.system_info(:atom_count) == initial_atom_count
  end

  test "validates envelope payload bounds before routing an adapter" do
    assert {:error, %Error{code: :invalid}} =
             Control.dispatch(
               envelope("netman.profiles.validate", %{
                 "profile_id" => "office",
                 "name" => "Office",
                 "interfaces" => [],
                 "approved" => true
               })
             )

    assert [] = NetmanControlTestAdapter.take_calls()
  end

  test "dispatches locally available profile validation through a fixed adapter" do
    result = %{"profile_id" => "office", "valid" => true, "errors" => []}
    NetmanControlTestAdapter.configure(response: {:ok, result})

    assert {:ok, ^result} =
             Control.dispatch(
               envelope("netman.profiles.validate", %{
                 "profile_id" => "office",
                 "name" => "Office",
                 "interfaces" => []
               })
             )

    assert [{:dispatch, "netman.profiles.validate"}] = NetmanControlTestAdapter.take_calls()
  end

  test "returns unsupported for a known route without a production adapter" do
    assert {:error, %Error{code: :unsupported}} =
             Control.dispatch(envelope("netman.resolved.upstreams.list", %{}))
  end

  test "rejects every capability route disabled by retained runtime features" do
    Application.put_env(:yellow_dog_netman, Dispatcher,
      adapters:
        Map.new(
          [:profiles, :network, :resolved, :dhcp_client, :vpn],
          &{&1, NetmanControlTestAdapter}
        )
    )

    for {operation, payload, disabled_feature} <- [
          {"netman.network.links.list", %{}, :link_state},
          {"netman.network.addresses.list", %{}, :interfaces},
          {"netman.network.routes.list", %{}, :routes},
          {"netman.network.connection_state.get", %{"connection_id" => "office"}, :interfaces},
          {"netman.network.connection_state.get", %{"connection_id" => "office"}, :link_state},
          {"netman.resolved.upstreams.list", %{}, :dns_client},
          {"netman.dhcp_client.fsm.get", %{}, :dhcp_client},
          {"netman.vpn.profile.get", %{}, :vpn}
        ] do
      features = Map.put(all_features(), disabled_feature, false)
      replace_runtime_state(%{apply_mode: :managed, features: features})

      assert {:error, %Error{code: :unsupported}} = Control.dispatch(envelope(operation, payload))
      assert [] = NetmanControlTestAdapter.take_calls()
    end
  end

  test "routes every enabled capability through its fixed adapter" do
    Application.put_env(:yellow_dog_netman, Dispatcher,
      adapters:
        Map.new(
          [:runtime, :profiles, :network, :resolved, :dhcp_client, :vpn],
          &{&1, NetmanControlTestAdapter}
        )
    )

    replace_runtime_state(%{
      apply_mode: :managed,
      features: %{
        interfaces: true,
        dhcp_client: true,
        dns_client: true,
        routes: true,
        link_state: true,
        vpn: true
      }
    })

    for {operation, payload, result} <- [
          {"netman.runtime.apply_mode.get", %{}, %{"mode" => "managed"}},
          {"netman.profiles.validate", profile_payload(), profile_validation()},
          {"netman.network.links.list", %{}, list_result(network_link())},
          {"netman.network.addresses.list", %{}, list_result(network_address())},
          {"netman.network.routes.list", %{}, list_result(network_route())},
          {"netman.network.connection_state.get", %{"connection_id" => "office"},
           %{"connection_id" => "office", "state" => "activated"}},
          {"netman.resolved.upstreams.list", %{}, list_result(resolved_upstream())},
          {"netman.dhcp_client.fsm.get", %{}, %{"connection_id" => "office", "state" => "bound"}},
          {"netman.vpn.profile.get", %{}, %{"profile_id" => "vpn-default", "state" => "resolved"}}
        ] do
      NetmanControlTestAdapter.configure(response: {:ok, result})

      assert {:ok, ^result} = Control.dispatch(envelope(operation, payload))
      assert [{:dispatch, ^operation}] = NetmanControlTestAdapter.take_calls()
    end
  end

  test "uses the profile owner's canonical revision and forwards trusted mutation context" do
    profile_id = "dispatcher-owner-revision"
    profile = %Profile{id: profile_id, type: :ethernet, interface: "eth0"}
    on_exit(fn -> YellowDog.Netman.delete_profile(profile_id) end)

    assert :ok = YellowDog.Netman.put_profile(profile_id, profile)
    assert {:ok, owner_revision} = YellowDog.Netman.profile_revision(profile_id)

    canonical_revision =
      profile
      |> Profile.canonical_toml()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    assert owner_revision == canonical_revision

    result = revisioned_profile(profile_id, owner_revision)

    NetmanControlTestAdapter.configure(
      current: {:owner_revision, profile_id},
      response: {:ok, result}
    )

    payload = profile_payload(profile_id)

    assert {:ok, ^result} =
             Control.dispatch(
               envelope("netman.profiles.put", payload, expected_revision: owner_revision)
             )

    assert [
             {:current, "netman.profiles.put"},
             {:dispatch, "netman.profiles.put",
              %{
                expected_revision: ^owner_revision,
                current_revision: ^owner_revision,
                precondition: {:revision, ^owner_revision},
                config_version: nil
              }}
           ] = NetmanControlTestAdapter.take_calls()
  end

  test "owner missing precondition prevents a create race from overwriting a profile" do
    profile_id = "dispatcher-create-race-#{System.unique_integer([:positive])}"
    direct_owner = %Profile{id: profile_id, type: :ethernet, autoconnect_priority: 10}
    attempted = %Profile{id: profile_id, type: :ethernet, autoconnect_priority: 99}
    on_exit(fn -> YellowDog.Netman.delete_profile(profile_id) end)

    NetmanControlTestAdapter.configure(
      current: {:owner_create_then_missing, direct_owner},
      response: {:owner_put, attempted}
    )

    assert {:error, %Error{code: :conflict, message: "operation conflict", details: %{}}} =
             Control.dispatch(envelope("netman.profiles.put", profile_payload(profile_id)))

    assert [
             {:current, "netman.profiles.put"},
             {:dispatch, "netman.profiles.put",
              %{
                expected_revision: nil,
                current_revision: :missing,
                precondition: :must_be_missing,
                config_version: nil
              }}
           ] = NetmanControlTestAdapter.take_calls()

    assert {:ok, ^direct_owner} = YellowDog.Netman.get_profile(profile_id)
  end

  test "rejects stale owner revisions before invoking a mutation" do
    current_revision = @revision

    NetmanControlTestAdapter.configure(current: {:ok, current_revision})

    assert {:error,
            %Error{
              code: :conflict,
              details: %{"current_revision" => ^current_revision}
            }} =
             Control.dispatch(
               envelope(
                 "netman.profiles.put",
                 profile_payload(),
                 expected_revision: String.duplicate("a", 64)
               )
             )

    assert [{:current, "netman.profiles.put"}] = NetmanControlTestAdapter.take_calls()
  end

  test "validates config versions before routing and forwards a valid version" do
    Application.put_env(:yellow_dog_netman, Dispatcher,
      adapters: %{resolved: NetmanControlTestAdapter}
    )

    replace_runtime_state(%{
      apply_mode: :managed,
      features: %{dns_client: true}
    })

    payload = %{"upstreams" => ["1.1.1.1"], "search_domains" => ["example.test"]}

    for config_version <- [nil, 0, "7"] do
      assert {:error, %Error{code: :invalid}} =
               Control.dispatch(
                 envelope("netman.resolved.config.update", payload,
                   config_version: config_version,
                   expected_revision: @revision
                 )
               )

      assert [] = NetmanControlTestAdapter.take_calls()
    end

    result = config_state(7)
    NetmanControlTestAdapter.configure(current: {:ok, @revision}, response: {:ok, result})

    assert {:ok, ^result} =
             Control.dispatch(
               envelope("netman.resolved.config.update", payload,
                 config_version: 7,
                 expected_revision: @revision
               )
             )

    assert [
             {:current, "netman.resolved.config.update"},
             {:dispatch, "netman.resolved.config.update",
              %{
                expected_revision: @revision,
                current_revision: @revision,
                precondition: {:revision, @revision},
                config_version: 7
              }}
           ] = NetmanControlTestAdapter.take_calls()
  end

  test "normalizes every fixed Netman result enum" do
    for value <- [
          :healthy,
          :degraded,
          :unhealthy,
          :up,
          :down,
          :unknown,
          :global,
          :link,
          :host,
          :dhcp,
          :static,
          :disabled,
          :activated,
          :deactivated,
          :failed,
          :init,
          :selecting,
          :requesting,
          :bound,
          :renewing,
          :rebinding,
          :managed,
          :observe_first,
          :observe,
          :resolved,
          :unavailable,
          :delivered,
          :applying,
          :applied,
          :ipv4,
          :ipv6,
          :delivery,
          :validation,
          :apply,
          :rollback
        ] do
      assert {:ok, %{"value" => normalized}} = Result.normalize(%{value: value})
      assert normalized == Atom.to_string(value)
    end
  end

  test "allows complete HTTP URIs and CIDRs" do
    for value <- [
          "https://example.test/callback?next=/dashboard",
          "http://127.0.0.1/a//b",
          "192.0.2.10/24",
          "2001:db8::1/64"
        ] do
      assert {:ok, %{"value" => ^value}} = Result.normalize(%{value: value})
    end
  end

  test "rejects local runtime values and local path forms" do
    assert {:error, %Error{code: :invalid}} = Result.normalize(%{pid: self()})
    assert {:error, %Error{code: :invalid}} = Result.normalize(%{path: "/var/lib/yellowdog"})

    for message <- [
          "failed at /var/lib/yellowdog",
          "see file:///etc/secret",
          "prefix FILE:///etc/secret",
          "unix:///run/yellowdog.sock",
          "failed:(/var/lib/data)",
          "failed at //var/lib/yellowdog",
          "failed at ///etc/shadow",
          "failed at ////var/run/yellowdog.sock",
          "failed at /var//lib/yellowdog",
          "failed=[C:\\ProgramData\\yellowdog]",
          "failed=(D:/YellowDog/data)",
          "failed=(\\\\server\\share\\yellowdog)",
          "https://user:password@example.test/dashboard",
          "path:/etc/yellowdog",
          "failed./var/lib/yellowdog"
        ] do
      assert {:error, %Error{code: :invalid}} = Result.normalize(%{message: message})
    end
  end

  test "rejects normalized adapter results that violate the operation schema" do
    NetmanControlTestAdapter.configure(
      response:
        {:ok,
         %{
           profile_id: "office",
           valid: true,
           errors: [],
           unexpected: "normalized"
         }}
    )

    assert {:error, %Error{code: :invalid}} =
             Control.dispatch(envelope("netman.profiles.validate", profile_payload()))
  end

  test "redacts adapter errors, exception messages, and stack details" do
    secret = "netman-control-secret"

    NetmanControlTestAdapter.configure(
      response: {:error, Error.new(:not_found, "file:///#{secret}", %{"token" => secret})}
    )

    assert {:error, %Error{code: :not_found, message: "resource not found", details: %{}}} =
             Control.dispatch(envelope("netman.profiles.list", %{}))

    NetmanControlTestAdapter.configure(response: {:raise, secret})

    log =
      capture_log(fn ->
        assert {:error, %Error{code: :internal, message: "internal error", details: %{}}} =
                 Control.dispatch(envelope("netman.profiles.list", %{}))
      end)

    refute log =~ secret
    refute log =~ "dispatcher_test.exs"
  end

  defp envelope(operation, payload, overrides \\ []) do
    {:ok, payload_digest} = YellowDog.Sync.Digest.calculate(payload)

    %Envelope{
      protocol_version: 1,
      request_id: Keyword.get(overrides, :request_id, @request_id),
      target_type: :netman,
      target_id: "netman-control-test",
      operation: operation,
      idempotency_key: Keyword.get(overrides, :idempotency_key, @idempotency_key),
      payload: payload,
      payload_digest: payload_digest,
      expected_revision: Keyword.get(overrides, :expected_revision),
      config_version: Keyword.get(overrides, :config_version),
      sent_at: @sent_at
    }
  end

  defp replace_runtime_state(overrides) do
    :sys.replace_state(RuntimeState, fn state -> Map.merge(state, overrides) end)
  end

  defp all_features do
    %{
      interfaces: true,
      dhcp_client: true,
      dns_client: true,
      routes: true,
      link_state: true,
      vpn: true
    }
  end

  defp profile_payload(profile_id \\ "office") do
    %{"profile_id" => profile_id, "name" => "Office", "interfaces" => []}
  end

  defp profile_validation do
    %{"profile_id" => "office", "valid" => true, "errors" => []}
  end

  defp list_result(item) do
    %{"items" => [item], "revision" => @revision, "observed_at" => DateTime.to_iso8601(@sent_at)}
  end

  defp network_link, do: %{"link_id" => "eth0", "name" => "eth0", "state" => "up"}

  defp network_address,
    do: %{"link_id" => "eth0", "address" => "192.0.2.10/24", "scope" => "global"}

  defp network_route,
    do: %{"destination" => "0.0.0.0/0", "gateway" => "192.0.2.1", "link_id" => "eth0"}

  defp resolved_upstream, do: %{"address" => "1.1.1.1", "source" => "managed"}

  defp revisioned_profile(profile_id, revision) do
    %{
      "resource_type" => "netman_profile",
      "resource_id" => profile_id,
      "resource" => profile_payload(profile_id),
      "revision" => revision
    }
  end

  defp config_state(version) do
    %{
      "state" => "delivered",
      "version" => version,
      "digest" => @revision,
      "applied_revision" => nil,
      "previous_version" => nil,
      "previous_revision" => nil,
      "failure" => nil,
      "rollback" => nil
    }
  end
end

defmodule NetmanControlTestAdapter do
  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> %{calls: [], current: {:ok, :missing}, response: {:ok, %{}}} end,
      name: __MODULE__
    )
  end

  def configure(opts) do
    Agent.update(__MODULE__, fn state ->
      state
      |> maybe_put(:current, opts)
      |> maybe_put(:response, opts)
    end)
  end

  def take_calls do
    Agent.get_and_update(__MODULE__, fn state ->
      {Enum.reverse(state.calls), %{state | calls: []}}
    end)
  end

  def current(operation, _payload) do
    current =
      Agent.get_and_update(__MODULE__, fn state ->
        {state.current, %{state | calls: [{:current, operation} | state.calls]}}
      end)

    case current do
      {:owner_revision, profile_id} ->
        case YellowDog.Netman.profile_revision(profile_id) do
          {:ok, revision} -> {:ok, revision}
          {:error, :not_found} -> {:ok, :missing}
        end

      {:owner_create_then_missing, profile} ->
        :ok =
          YellowDog.Netman.put_profile(profile.id, profile, expected_revision: :missing)

        {:ok, :missing}

      result ->
        result
    end
  end

  def dispatch(operation, _payload) do
    Agent.get_and_update(__MODULE__, fn state ->
      {state.response, %{state | calls: [{:dispatch, operation} | state.calls]}}
    end)
    |> run()
  end

  def dispatch(operation, _payload, context) do
    response =
      Agent.get_and_update(__MODULE__, fn state ->
        {state.response, %{state | calls: [{:dispatch, operation, context} | state.calls]}}
      end)

    run(response, context)
  end

  defp maybe_put(state, key, opts) do
    if Keyword.has_key?(opts, key),
      do: Map.put(state, key, Keyword.fetch!(opts, key)),
      else: state
  end

  defp run({:raise, reason}), do: raise(reason)
  defp run(result), do: result

  defp run({:owner_put, profile}, context) do
    expected_revision =
      case context.precondition do
        :must_be_missing -> :missing
        {:revision, revision} -> revision
      end

    case YellowDog.Netman.put_profile(profile.id, profile, expected_revision: expected_revision) do
      :ok ->
        {:ok, %{}}

      {:error, {:conflict, current_revision}} ->
        {:error,
         YellowDog.Sync.Error.new(:conflict, "owner conflict", %{
           "current_revision" => current_revision
         })}

      {:error, reason} ->
        {:error, YellowDog.Sync.Error.new(:internal, inspect(reason), %{})}
    end
  end

  defp run(result, _context), do: run(result)
end
