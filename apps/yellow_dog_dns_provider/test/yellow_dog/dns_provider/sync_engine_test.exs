defmodule YellowDog.DnsProvider.SyncEngineTest do
  use ExUnit.Case, async: false

  alias YellowDog.DnsProvider.{Config, SyncEngine}
  alias YellowDog.DnsProvider.Provider.Cloudflare

  setup do
    case Registry.start_link(keys: :unique, name: YellowDog.DnsProvider.Registry) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  defp build_config(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          name: "test-provider-#{System.unique_integer([:positive])}",
          type: :cloudflare,
          zones: ["example.com"],
          sync_interval: 3600,
          conflict_strategy: :local_wins,
          enabled: true,
          credentials: %{}
        },
        overrides
      )

    {:ok, config} = Config.new(attrs)
    config
  end

  defp start_engine(config, provider_opts \\ %{}) do
    credentials =
      Map.merge(
        %{zones: config.zones, records: %{}},
        provider_opts
      )

    config = %{config | credentials: credentials}

    start_supervised!(
      {SyncEngine, config: config, provider_module: YellowDog.DnsProvider.Provider.Test}
    )
  end

  describe "start_link/1" do
    test "starts and registers with provider name" do
      config = build_config()
      pid = start_engine(config)

      assert is_pid(pid)
      assert Process.alive?(pid)

      # Verify registry lookup
      assert [{^pid, nil}] =
               Registry.lookup(YellowDog.DnsProvider.Registry, config.name)
    end
  end

  describe "sync_now/1" do
    test "triggers sync for all zones" do
      config = build_config()

      remote_records = %{
        "example.com" => [
          %{owner: "www.example.com", type: "A", ttl: 300, rdata: "1.2.3.4"}
        ]
      }

      pid = start_engine(config, %{records: remote_records})

      # Status before sync
      status_before = SyncEngine.status(pid)
      assert status_before.sync_count == 0
      assert status_before.last_sync == nil

      # Trigger sync
      :ok = SyncEngine.sync_now(pid)

      # Give the cast time to process
      :sys.get_state(pid)

      status_after = SyncEngine.status(pid)
      assert status_after.sync_count == 1
      assert status_after.last_sync != nil
    end
  end

  describe "sync_now/2" do
    test "triggers sync for a specific zone" do
      config = build_config(%{zones: ["example.com", "other.com"]})

      remote_records = %{
        "example.com" => [
          %{owner: "www.example.com", type: "A", ttl: 300, rdata: "1.2.3.4"}
        ],
        "other.com" => [
          %{owner: "mail.other.com", type: "MX", ttl: 3600, rdata: "10 mail.other.com"}
        ]
      }

      pid = start_engine(config, %{records: remote_records})

      :ok = SyncEngine.sync_now(pid, "example.com")
      :sys.get_state(pid)

      status = SyncEngine.status(pid)
      # Single zone sync increments count by 1
      assert status.sync_count == 1
    end
  end

  describe "status/1" do
    test "returns sync status map" do
      config = build_config()
      pid = start_engine(config)

      status = SyncEngine.status(pid)

      assert status.provider == config.name
      assert status.zones == ["example.com"]
      assert status.interval == 3_600_000
      assert status.sync_count == 0
      assert status.last_sync == nil
      assert status.last_error == nil
    end

    test "updates after sync" do
      config = build_config()
      pid = start_engine(config)

      :ok = SyncEngine.sync_now(pid)
      :sys.get_state(pid)

      status = SyncEngine.status(pid)
      assert status.sync_count == 1
      assert is_integer(status.last_sync)
      assert status.last_error == nil
    end
  end

  describe "resolve_conflict/3" do
    test "synchronously applies the local RRset against the stored remote RRset" do
      config = build_config()

      remote = %{owner: "www.example.com", type: "A", ttl: 60, rdata: "192.0.2.2"}
      local = %{owner: "www.example.com", type: "A", ttl: 60, rdata: "192.0.2.1"}

      pid = start_engine(config, %{records: %{"example.com" => [remote]}})

      conflict = %{
        zone: "example.com",
        local_records: [local],
        remote_records: [remote]
      }

      assert :ok = apply(SyncEngine, :resolve_conflict, [pid, conflict, 5_000])

      assert %{provider_state: %{records: %{"example.com" => [^local]}, apply_count: 1}} =
               :sys.get_state(pid)
    end

    test "returns a provider rejection without accepting the remote changeset" do
      config = build_config()
      local = %{owner: "www.example.com", type: "A", ttl: 60, rdata: "192.0.2.1"}
      remote = %{owner: "www.example.com", type: "A", ttl: 60, rdata: "192.0.2.2"}

      pid =
        start_engine(config, %{records: %{"example.com" => [remote]}, apply_error: :remote_failed})

      assert {:error, :apply_failed} =
               SyncEngine.resolve_conflict(
                 pid,
                 %{
                   zone: "example.com",
                   local_records: [local],
                   remote_records: [remote]
                 },
                 5_000
               )

      assert %{provider_state: %{records: %{"example.com" => [^remote]}, apply_count: 0}} =
               :sys.get_state(pid)
    end

    test "resolves and uses the exact nonempty Cloudflare zone ID" do
      owner = self()

      config = build_config(%{name: "cf-zone-id"})
      pid = start_cloudflare_engine(config, cloudflare_adapter(owner))

      conflict = conflict_records("example.com.")

      result = SyncEngine.resolve_conflict(pid, conflict, 5_000)

      assert_receive {:request, :get, "/client/v4/zones"}
      assert_receive {:request, :get, "/client/v4/zones/zone-exact-123/dns_records"}
      assert_receive {:request, :get, "/client/v4/zones/zone-exact-123/dns_records"}

      assert_receive {:request, :delete,
                      "/client/v4/zones/zone-exact-123/dns_records/remote-record"}

      assert_receive {:request, :post, "/client/v4/zones/zone-exact-123/dns_records"}
      refute_receive {:request, _method, "/client/v4/zones//dns_records"}
      assert :ok = result
    end

    test "returns not_found before writes when Cloudflare has no matching zone" do
      owner = self()

      adapter = cloudflare_zone_list_adapter(owner, [])

      config = build_config(%{name: "cf-zone-missing"})
      pid = start_cloudflare_engine(config, adapter)

      assert {:error, :not_found} =
               SyncEngine.resolve_conflict(pid, conflict_records("example.com."), 5_000)

      assert_receive {:request, :get, "/client/v4/zones"}
      refute_receive {:request, :post, _path}
      refute_receive {:request, :delete, _path}
    end

    test "returns conflict before writes for duplicate Cloudflare zone mappings" do
      owner = self()

      adapter =
        cloudflare_zone_list_adapter(owner, [
          %{"name" => "example.com", "id" => "zone-one"},
          %{"name" => "example.com.", "id" => "zone-two"}
        ])

      config = build_config(%{name: "cf-zone-duplicate"})
      pid = start_cloudflare_engine(config, adapter)

      assert {:error, :conflict} =
               SyncEngine.resolve_conflict(pid, conflict_records("example.com."), 5_000)

      assert_receive {:request, :get, "/client/v4/zones"}
      refute_receive {:request, :post, _path}
      refute_receive {:request, :delete, _path}
    end

    test "returns unsupported before writes for an empty Cloudflare zone ID" do
      owner = self()

      adapter =
        cloudflare_zone_list_adapter(owner, [
          %{"name" => "example.com", "id" => ""}
        ])

      config = build_config(%{name: "cf-zone-invalid"})
      pid = start_cloudflare_engine(config, adapter)

      assert {:error, :unsupported} =
               SyncEngine.resolve_conflict(pid, conflict_records("example.com."), 5_000)

      assert_receive {:request, :get, "/client/v4/zones"}
      refute_receive {:request, :post, _path}
      refute_receive {:request, :delete, _path}
    end
  end

  describe "read-only provider" do
    test "skips push to remote" do
      config = build_config()

      remote_records = %{
        "example.com" => [
          %{owner: "ns.example.com", type: "A", ttl: 300, rdata: "10.0.0.1"}
        ]
      }

      pid = start_engine(config, %{records: remote_records, read_only: true})

      :ok = SyncEngine.sync_now(pid)
      :sys.get_state(pid)

      status = SyncEngine.status(pid)
      assert status.sync_count == 1
      assert status.last_error == nil
    end
  end

  defp start_cloudflare_engine(config, adapter) do
    req =
      Req.new(
        base_url: "https://api.cloudflare.test/client/v4",
        adapter: adapter
      )

    config = %{config | credentials: %{api_token: "test-token", req: req}}

    start_supervised!({SyncEngine, config: config, provider_module: Cloudflare})
  end

  defp conflict_records(zone) do
    %{
      zone: zone,
      local_records: [
        %{owner: "www.example.com.", type: "A", ttl: 60, rdata: "192.0.2.1"}
      ],
      remote_records: [
        %{owner: "www.example.com.", type: "A", ttl: 60, rdata: "192.0.2.2"}
      ]
    }
  end

  defp cloudflare_adapter(owner) do
    fn request ->
      send(owner, {:request, request.method, request.url.path})
      {request, cloudflare_resolution_response(request)}
    end
  end

  defp cloudflare_zone_list_adapter(owner, zones) do
    fn request ->
      send(owner, {:request, request.method, request.url.path})
      {request, Req.Response.new(status: 200, body: %{"result" => zones})}
    end
  end

  defp cloudflare_resolution_response(%{method: :get, url: %{path: "/client/v4/zones"}}) do
    Req.Response.new(
      status: 200,
      body: %{"result" => [%{"name" => "example.com", "id" => "zone-exact-123"}]}
    )
  end

  defp cloudflare_resolution_response(%{
         method: :get,
         url: %{path: "/client/v4/zones/zone-exact-123/dns_records"}
       }) do
    Req.Response.new(
      status: 200,
      body: %{
        "result" => [
          %{
            "id" => "remote-record",
            "name" => "www.example.com",
            "type" => "A",
            "ttl" => 60,
            "content" => "192.0.2.2"
          }
        ],
        "result_info" => %{"total_pages" => 1}
      }
    )
  end

  defp cloudflare_resolution_response(%{
         method: :delete,
         url: %{path: "/client/v4/zones/zone-exact-123/dns_records/remote-record"}
       }) do
    Req.Response.new(status: 200, body: %{"success" => true})
  end

  defp cloudflare_resolution_response(%{
         method: :post,
         url: %{path: "/client/v4/zones/zone-exact-123/dns_records"}
       }) do
    Req.Response.new(status: 200, body: %{"success" => true})
  end

  defp cloudflare_resolution_response(_request) do
    Req.Response.new(status: 404, body: %{"error" => "unexpected request path"})
  end
end
