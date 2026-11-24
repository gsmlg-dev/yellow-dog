defmodule YellowDog.Management.CloudDnsTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest, only: [get: 2]
  import Phoenix.LiveViewTest

  alias YellowDog.Management.{Caller, CloudDns, Domain, IntegrationSettings, Repo}

  @endpoint YellowDog.ManagementUI.Endpoint
  @remote_id "Z1234"
  @name "sync.example."
  @a {"www.sync.example.", "A"}
  @old {"old.sync.example.", "A"}
  @new {"new.sync.example.", "A"}
  @protected {"proxy.sync.example.", "A"}

  defmodule Provider do
    def fetch(id, _credentials) do
      Agent.get(__MODULE__, fn state ->
        case state.zones[id] do
          nil -> {:error, :zone_not_found}
          zone -> {:ok, zone}
        end
      end)
    end

    def apply(id, _credentials, changes) do
      Agent.update(__MODULE__, fn state ->
        rrsets =
          Enum.reduce(changes, state.zones[id].rrsets, fn
            %{key: key, after: nil}, acc -> Map.delete(acc, key)
            %{key: key, after: rrset}, acc -> Map.put(acc, key, Map.put(rrset, :protected, false))
          end)

        state
        |> put_in([:zones, id, :rrsets], rrsets)
        |> Map.update!(:writes, &[changes | &1])
      end)
    end

    def create_zone(name, _credentials, _request_id) do
      Agent.get_and_update(__MODULE__, fn state ->
        if Enum.any?(state.zones, fn {_id, zone} -> zone.name == name end) do
          {{:error, :remote_zone_exists}, state}
        else
          zone = %{name: name, name_servers: ["ns.example."], rrsets: %{}}
          {{:ok, "ZNEW"}, put_in(state.zones["ZNEW"], zone)}
        end
      end)
    end
  end

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    start_supervised!(%{
      id: Provider,
      start:
        {Agent, :start_link,
         [
           fn ->
             zone = %{
               name: @name,
               name_servers: ["ns.example."],
               rrsets: %{
                 @a => rr("192.0.2.1"),
                 @old => rr("192.0.2.2"),
                 @protected => Map.put(rr("192.0.2.3"), :protected, true)
               }
             }

             %{zones: %{@remote_id => zone}, writes: []}
           end,
           [name: Provider]
         ]}
    })

    previous = Application.get_env(:yellow_dog_management, :cloud_dns_adapters)
    Application.put_env(:yellow_dog_management, :cloud_dns_adapters, %{"route53" => Provider})
    vars = %{"TEST_DNS_AWS_ACCESS_KEY_ID" => "key", "TEST_DNS_AWS_SECRET_ACCESS_KEY" => "secret"}
    original = Map.new(vars, fn {name, _} -> {name, System.get_env(name)} end)
    System.put_env(vars)

    on_exit(fn ->
      if previous do
        Application.put_env(:yellow_dog_management, :cloud_dns_adapters, previous)
      else
        Application.delete_env(:yellow_dog_management, :cloud_dns_adapters)
      end

      for {name, value} <- original do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end
    end)

    caller = %Caller{
      issuer: "urn:yellow-dog:trusted-local",
      subject: "cloud-dns-test",
      scopes: IntegrationSettings.scopes(),
      source: :ui,
      correlation_id: Ecto.UUID.generate(),
      expires_at: System.system_time(:second) + 600,
      policy_revision: IntegrationSettings.get().policy_revision,
      authentication: :trusted_local
    }

    %{caller: caller}
  end

  test "initial cloud import overwrites a matching local draft but never writes the provider", %{
    caller: caller
  } do
    original = create_zone(@name, [record(@a, "192.0.2.99"), record(@new, "192.0.2.8")])
    binding = import_binding(caller)

    assert {:error, :pull_first} = CloudDns.preview(caller, binding.id, :push)
    assert {:ok, preview} = CloudDns.preview(caller, binding.id, :pull)
    assert preview.initial?
    assert preview.zone_id == original["id"]
    assert @protected in preview.protected
    assert Enum.map(preview.rows, & &1.key) == Enum.sort([@a, @old, @new])

    assert {:ok, binding} = CloudDns.confirm(caller, binding.id, :pull, preview.stamp)
    assert binding.zone_id == original["id"]
    assert {:ok, zone} = Domain.get_zone(binding.zone_id)
    assert a_records(zone) == Enum.sort([record(@a, "192.0.2.1"), record(@old, "192.0.2.2")])
    assert writes() == []
    assert {:error, :confirm_local_version} = CloudDns.preview(caller, binding.id, :push)
  end

  test "only the confirmed add, edit and delete are pushed and protected data remains", %{
    caller: caller
  } do
    binding = pull(caller, import_binding(caller))
    {:ok, zone} = Domain.get_zone(binding.zone_id)
    updated = update_zone(zone, [record(@a, "192.0.2.10"), record(@new, "192.0.2.11")])
    confirm_zone(updated)

    assert {:ok, %{blocked?: false} = review} = CloudDns.preview(caller, binding.id, :push)
    assert writes() == []

    change_remote(@a, "192.0.2.12")
    assert {:error, :stale_preview} = CloudDns.confirm(caller, binding.id, :push, review.stamp)
    assert writes() == []
    assert {:ok, %{blocked?: true}} = CloudDns.preview(caller, binding.id, :push)
    assert {:ok, pull_review} = CloudDns.preview(caller, binding.id, :pull)
    index = Enum.find_index(pull_review.rows, &(&1.key == @a and &1.state == :conflict))
    assert is_integer(index)

    assert {:error, :resolve_conflicts} =
             CloudDns.confirm(caller, binding.id, :pull, pull_review.stamp)

    assert {:ok, _} =
             CloudDns.confirm(caller, binding.id, :pull, pull_review.stamp, %{
               to_string(index) => "local"
             })

    assert {:ok, %{blocked?: false} = reviewed} = CloudDns.preview(caller, binding.id, :push)
    assert {:ok, _} = CloudDns.confirm(caller, binding.id, :push, reviewed.stamp)
    assert [changes] = writes()
    assert Enum.map(changes, & &1.key) == Enum.sort([@a, @old, @new])

    assert %{before: nil, after: %{values: ["192.0.2.11"]}} =
             Enum.find(changes, &(&1.key == @new))

    assert %{before: %{values: ["192.0.2.12"]}, after: %{values: ["192.0.2.10"]}} =
             Enum.find(changes, &(&1.key == @a))

    assert %{after: nil} = Enum.find(changes, &(&1.key == @old))
    assert {:ok, %{rrsets: %{@protected => %{protected: true}}}} = Provider.fetch(@remote_id, %{})
  end

  test "creation refuses an existing cloud zone, and a new zone is seeded only after review", %{
    caller: caller
  } do
    existing = create_zone(@name, [record(@a, "192.0.2.99")])
    matching = create_binding(caller, existing)
    assert {:error, :remote_zone_exists} = CloudDns.create_remote(caller, matching.id)
    assert writes() == []

    name = "new-cloud.example."
    key = {"www." <> name, "A"}
    zone = create_zone(name, [record(key, "192.0.2.8")])
    confirm_zone(zone)
    binding = create_binding(caller, zone)
    assert {:ok, linked} = CloudDns.create_remote(caller, binding.id)
    assert linked.remote_id == "ZNEW"
    assert {:ok, %{rrsets: rrsets}} = Provider.fetch("ZNEW", %{})
    assert rrsets == %{}
    assert {:ok, %{blocked?: false} = review} = CloudDns.preview(caller, linked.id, :push)

    Agent.update(Provider, &put_in(&1.zones["ZNEW"].rrsets[key], rr("192.0.2.77")))
    assert {:error, :stale_preview} = CloudDns.confirm(caller, linked.id, :push, review.stamp)
    assert {:ok, %{blocked?: true}} = CloudDns.preview(caller, linked.id, :push)
    assert writes() == []

    Agent.update(
      Provider,
      &update_in(&1.zones["ZNEW"].rrsets, fn rrsets -> Map.delete(rrsets, key) end)
    )

    assert {:ok, %{blocked?: false} = refreshed} = CloudDns.preview(caller, linked.id, :push)
    assert {:ok, _} = CloudDns.confirm(caller, linked.id, :push, refreshed.stamp)
    assert {:ok, %{rrsets: %{^key => %{values: ["192.0.2.8"]}}}} = Provider.fetch("ZNEW", %{})
  end

  test "Cloud DNS page uses a schema modal to select a configured provider", %{caller: caller} do
    provider = add_provider(caller)
    {:ok, view, _html} = live(Phoenix.ConnTest.build_conn(), "/management/zones/cloud")
    modal = render_click(view |> element("#cloud-dns-import-binding"))
    assert modal =~ "SchemaModal"
    assert modal =~ "provider_id"
    assert modal =~ provider.id
    refute modal =~ "Credential profile prefix"

    render_hook(view, "submit_modal", %{"provider_id" => provider.id, "remote_id" => @remote_id})
    view |> element("#cloud-dns-preview-pull") |> render_click()
    assert render_async(view) =~ "Review pull"
    assert [] = Domain.list_zones()
    view |> element("#cloud-dns-confirm") |> render_click()
    assert render_async(view) =~ "Cloud records saved to the local zone draft"
    assert [%{"name" => @name}] = Domain.list_zones()
  end

  test "system management creates and edits providers through schema modals", %{caller: caller} do
    {:ok, view, _html} = live(Phoenix.ConnTest.build_conn(), "/system/cloud-providers")
    assert render_click(view |> element("#cloud-provider-new")) =~ "SchemaModal"

    render_hook(view, "submit_modal", %{
      "name" => "DNS test",
      "kind" => "route53",
      "profile" => "TEST_DNS"
    })

    assert {:ok, [provider]} = CloudDns.providers(caller)
    assert has_element?(view, "#cloud-provider-#{provider.id}", "DNS test")

    view |> element("#cloud-provider-#{provider.id} button[phx-click=edit]") |> render_click()
    render_hook(view, "submit_modal", %{"name" => "Production DNS"})
    assert has_element?(view, "#cloud-provider-#{provider.id}", "Production DNS")

    binding = import_binding(caller)
    assert {:ok, [provider]} = CloudDns.providers(caller)
    assert provider.bound?
    assert binding.provider_id == provider.id

    assert {:error, :provider_in_use} =
             CloudDns.update_provider(caller, provider, %{"profile" => "DIFFERENT"})

    assert {:error, %Ecto.Changeset{}} = CloudDns.delete_provider(caller, provider.id)
    assert {:ok, :unlinked} = CloudDns.unlink(caller, binding.id)
    assert {:ok, _provider} = CloudDns.delete_provider(caller, provider.id)
  end

  defp rr(value), do: %{ttl: 300, values: [value], protected: false}

  defp record({name, "A"}, address),
    do: %{"name" => name, "type" => "A", "ttl" => 300, "data" => %{"address" => address}}

  defp a_records(zone), do: zone["records"] |> Enum.filter(&(&1["type"] == "A")) |> Enum.sort()

  defp create_zone(name, payload) do
    soa = %{
      "name" => name,
      "type" => "SOA",
      "ttl" => 3600,
      "data" => %{
        "mname" => "ns.example.",
        "rname" => "hostmaster." <> name,
        "serial" => 1,
        "refresh" => 3600,
        "retry" => 600,
        "expire" => 86400,
        "minimum" => 300
      }
    }

    ns = %{"name" => name, "type" => "NS", "ttl" => 3600, "data" => %{"host" => "ns.example."}}
    mutate("create_zone", %{"name" => name, "records" => [soa, ns | payload]})
  end

  defp update_zone(zone, payload) do
    mutate("update_zone", %{
      "id" => zone["id"],
      "expected_revision" => zone["revision"],
      "name" => zone["name"],
      "records" => Enum.reject(zone["records"], &(&1["type"] == "A")) ++ payload
    })
  end

  defp confirm_zone(zone),
    do: mutate("confirm_zone", %{"id" => zone["id"], "expected_revision" => zone["revision"]})

  defp mutate(op, params) do
    assert {:ok, value} = Domain.mutate(op, params, "cloud-dns-test", Ecto.UUID.generate())
    value
  end

  defp import_binding(caller),
    do: add_binding(caller, %{"mode" => "import", "remote_id" => @remote_id})

  defp create_binding(caller, zone),
    do: add_binding(caller, %{"mode" => "create", "zone_id" => zone["id"]})

  defp add_provider(caller) do
    case CloudDns.providers(caller) do
      {:ok, []} ->
        assert {:ok, provider} =
                 CloudDns.add_provider(caller, %{
                   "name" => "DNS test",
                   "kind" => "route53",
                   "profile" => "TEST_DNS"
                 })

        provider

      {:ok, [provider]} ->
        provider
    end
  end

  defp add_binding(caller, fields) do
    provider = add_provider(caller)
    assert {:ok, binding} = CloudDns.add(caller, Map.put(fields, "provider_id", provider.id))
    binding
  end

  defp pull(caller, binding) do
    assert {:ok, preview} = CloudDns.preview(caller, binding.id, :pull)
    assert {:ok, linked} = CloudDns.confirm(caller, binding.id, :pull, preview.stamp)
    linked
  end

  defp change_remote(key, address),
    do: Agent.update(Provider, &put_in(&1.zones[@remote_id].rrsets[key], rr(address)))

  defp writes, do: Agent.get(Provider, & &1.writes)
end
