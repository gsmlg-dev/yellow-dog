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
    def list_zones(%{"access_key_id" => "denied"}), do: {:error, :route53_access_denied}

    def list_zones(_credentials) do
      Agent.get(__MODULE__, fn state ->
        {:ok, Enum.map(state.zones, fn {id, zone} -> %{id: id, name: zone.name} end)}
      end)
    end

    def fetch(id, credentials) do
      Agent.get_and_update(__MODULE__, fn state ->
        result =
          case state.zones[id] do
            nil -> {:error, :zone_not_found}
            zone -> {:ok, zone}
          end

        {result, Map.put(state, :last_credentials, credentials)}
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

  test "Cloud DNS imports a listed zone by name and reviews the pull before saving", %{
    caller: caller
  } do
    provider = add_provider(caller)
    conn = Phoenix.ConnTest.build_conn()
    {:ok, new_zone, _html} = live(conn, "/management/zones/new")
    assert has_element?(new_zone, "a[href='/management/zones/new/cloud']", "Cloud-synced")
    {:ok, view, _html} = live(conn, "/management/zones/new/cloud")
    view |> element("#cloud-dns-import-binding") |> render_click()
    render_async(view)

    assert has_element?(
             view,
             "#cloud-dns-import-provider option[selected][value='#{provider.id}']"
           )

    assert has_element?(view, "#cloud-dns-import-zone option[value='#{@remote_id}']", @name)

    view
    |> form("#cloud-dns-import-form", %{provider_id: provider.id, remote_id: @remote_id})
    |> render_submit()

    assert has_element?(view, "button[phx-click='select']", @name)
    assert has_element?(view, "#cloud-dns-zone-name", @name)
    refute has_element?(view, "button[phx-click='select']", @remote_id)

    {:ok, view, _html} = live(conn, "/management/zones/new/cloud")
    assert render_async(view) =~ @name
    view |> element("button[phx-click='select']", @name) |> render_click()
    assert has_element?(view, "#cloud-dns-zone-name", @name)
    refute has_element?(view, "p", "Zone ID")

    view |> element("#cloud-dns-preview-pull") |> render_click()
    assert render_async(view) =~ "Review pull"
    assert [] = Domain.list_zones()
    view |> element("#cloud-dns-confirm") |> render_click()
    {path, flash} = assert_redirect(view, 2_000)
    assert [%{"name" => @name, "id" => zone_id}] = Domain.list_zones()
    assert URI.parse(path).path == "/management/zones/#{zone_id}/sync"
    assert flash["info"] == "Cloud records saved to the local zone draft."

    {:ok, details, _html} = live(conn, "/management/zones/#{zone_id}/edit")
    assert has_element?(details, "a[href='/management/zones/#{zone_id}/sync']", "Cloud Sync")

    {:ok, sync, _html} = live(conn, path)
    assert has_element?(sync, "#cloud-dns-zone-name", @name)
    assert has_element?(sync, "#cloud-dns-preview-pull")
    refute has_element?(sync, "#cloud-dns-import-binding")

    {:ok, records, _html} = live(conn, "/management/zones/#{zone_id}/records")
    assert has_element?(records, "#records-table th", "RDATA")
    assert has_element?(records, "#records-table code", "192.0.2.1")
    refute has_element?(records, "#records-table code", ~s("address"))
  end

  test "switching providers clears the cloud zone list and rejects stale selections", %{
    caller: caller
  } do
    provider = add_provider(caller)

    assert {:ok, denied} =
             CloudDns.add_provider(caller, %{
               "name" => "Denied provider",
               "kind" => "route53",
               "access_key_id" => "denied",
               "secret_access_key" => "fixture"
             })

    {:ok, view, _html} = live(Phoenix.ConnTest.build_conn(), "/management/zones/new/cloud")
    view |> element("#cloud-dns-import-binding") |> render_click()
    refute has_element?(view, "#cloud-dns-import-zone option[value='#{@remote_id}']")

    view
    |> element("#cloud-dns-import-provider")
    |> render_change(%{"provider_id" => provider.id})

    render_async(view)
    assert has_element?(view, "#cloud-dns-import-zone option[value='#{@remote_id}']", @name)

    view |> element("#cloud-dns-import-provider") |> render_change(%{"provider_id" => denied.id})
    assert render_async(view) =~ "Could not load cloud zones"
    assert has_element?(view, "#cloud-dns-import-zone[disabled]")
    refute has_element?(view, "#cloud-dns-import-zone option[value='#{@remote_id}']")

    assert render_submit(view, "import_cloud_zone", %{
             "provider_id" => provider.id,
             "remote_id" => @remote_id
           }) =~
             "Select a cloud zone for this provider."

    assert {:ok, []} = CloudDns.list(caller)
  end

  test "adding cloud sync from a local zone keeps it in the authoritative zone workflow", %{
    caller: caller
  } do
    provider = add_provider(caller)
    zone = create_zone(@name, [])
    conn = Phoenix.ConnTest.build_conn()
    path = "/management/zones/#{zone["id"]}"

    {:ok, details, _html} = live(conn, path <> "/edit")
    refute has_element?(details, "a[href='#{path}/sync']")

    {:ok, setup, _html} = live(conn, "/management/zones/new/cloud")
    assert setup |> element("#cloud-dns-create-binding") |> render_click() =~ "Local zone"

    render_hook(setup, "submit_modal", %{"provider_id" => provider.id, "zone_id" => zone["id"]})
    {sync_path, _flash} = assert_redirect(setup)
    assert URI.parse(sync_path).path == path <> "/sync"

    {:ok, sync, _html} = live(conn, sync_path)
    refute has_element?(sync, "#cloud-dns-create-binding")
    sync |> element("#cloud-dns-create-remote") |> render_click()
    assert render_async(sync) =~ "A matching cloud zone already exists"
    assert writes() == []
    assert [%{"id" => id}] = Domain.list_zones()
    assert id == zone["id"]
  end

  test "system management creates and edits providers through schema modals", %{caller: caller} do
    {:ok, view, _html} = live(Phoenix.ConnTest.build_conn(), "/system/cloud-providers")
    assert render_click(view |> element("#cloud-provider-new")) =~ "SchemaModal"

    assert render_hook(view, "submit_modal", %{"kind" => "route53"}) =~ "AWS Secret Access Key"
    render_hook(view, "submit_modal", %{"name" => "DNS test"})
    assert_reply view, %{error: "Credentials require all mandatory fields for this provider"}

    render_hook(view, "submit_modal", %{
      "name" => "DNS test",
      "access_key_id" => "web-access-key",
      "secret_access_key" => "web-secret-key",
      "session_token" => "web-session-token"
    })

    assert {:ok, [provider]} = CloudDns.providers(caller)
    assert has_element?(view, "#cloud-provider-#{provider.id}", "DNS test")
    assert is_nil(provider.credentials)

    edit = fn ->
      view |> element("#cloud-provider-#{provider.id} button[phx-click=edit]") |> render_click()
    end

    refute edit.() =~ "web-secret-key"
    render_hook(view, "submit_modal", %{"name" => "Production DNS", "secret_access_key" => ""})
    assert has_element?(view, "#cloud-provider-#{provider.id}", "Production DNS")

    binding = import_binding(caller)
    assert {:ok, [provider]} = CloudDns.providers(caller)
    assert provider.bound?
    assert binding.provider_id == provider.id

    assert {:ok, preview} = CloudDns.preview(caller, binding.id, :pull)

    assert %{
             "access_key_id" => "web-access-key",
             "secret_access_key" => "web-secret-key",
             "session_token" => "web-session-token"
           } = Agent.get(Provider, & &1.last_credentials)

    edit.()

    render_hook(view, "submit_modal", %{
      "name" => "Production DNS",
      "secret_access_key" => "rotated-secret-key",
      "remove_session_token" => true
    })

    assert {:error, :stale_preview} = CloudDns.confirm(caller, binding.id, :pull, preview.stamp)

    assert %{"access_key_id" => "web-access-key", "secret_access_key" => "rotated-secret-key"} =
             credentials = Agent.get(Provider, & &1.last_credentials)

    refute Map.has_key?(credentials, "session_token")

    assert {:error, %Ecto.Changeset{}} = CloudDns.delete_provider(caller, provider.id)
    assert {:ok, :unlinked} = CloudDns.unlink(caller, binding.id)
    assert {:ok, _provider} = CloudDns.delete_provider(caller, provider.id)
  end

  test "web credentials replace an existing environment profile without unlinking its zone", %{
    caller: caller
  } do
    binding = import_binding(caller)
    assert {:ok, [_]} = CloudDns.providers(caller)
    assert {:ok, _} = CloudDns.preview(caller, binding.id, :pull)
    assert %{"access_key_id" => "key"} = Agent.get(Provider, & &1.last_credentials)

    {:ok, view, _html} = live(Phoenix.ConnTest.build_conn(), "/system/cloud-providers")

    view
    |> element("#cloud-provider-#{binding.provider_id} button[phx-click=edit]")
    |> render_click()

    render_hook(view, "submit_modal", %{
      "name" => "DNS test",
      "access_key_id" => "REPLACEMENTKEY",
      "secret_access_key" => "replacement-secret"
    })

    assert {:ok, [%{id: id, profile: nil, bound?: true}]} = CloudDns.providers(caller)
    assert id == binding.provider_id
    assert {:ok, _} = CloudDns.preview(caller, binding.id, :pull)

    assert %{"access_key_id" => "REPLACEMENTKEY", "secret_access_key" => "replacement-secret"} =
             Agent.get(Provider, & &1.last_credentials)
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
