defmodule YellowDog.Mdns.ServiceRegistryTest do
  use ExUnit.Case, async: false

  alias YellowDog.Mdns.{ServiceRegistry, ServiceStore}
  alias DNS.Message.Question

  setup do
    # Start the registry for each test
    {:ok, pid} = start_supervised({ServiceRegistry, [load_on_start: false]})

    # Clean up ETS table after each test
    on_exit(fn ->
      if Process.alive?(pid) do
        :ok
      end
    end)

    %{registry: pid}
  end

  describe "register_service/2" do
    test "registers a new service" do
      service_def = %{
        name: "Test Web Server",
        type: "_http._tcp",
        port: 8080
      }

      assert {:ok, service_id} = ServiceRegistry.register_service(service_def)
      assert service_id =~ "Test Web Server"
      assert service_id =~ "_http._tcp.local"

      # Verify service can be retrieved
      service = ServiceRegistry.get_service(service_id)
      assert service != nil
      assert service.name == "Test Web Server"
      assert service.port == 8080
    end

    test "registers service with TXT records" do
      service_def = %{
        name: "API Server",
        type: "_http._tcp",
        port: 8080,
        txt: %{"version" => "1.0", "path" => "/api"}
      }

      assert {:ok, service_id} = ServiceRegistry.register_service(service_def)
      service = ServiceRegistry.get_service(service_id)

      assert service.txt_records == %{"version" => "1.0", "path" => "/api"}
    end

    test "registers service with addresses" do
      service_def = %{
        name: "Multi-address Service",
        type: "_http._tcp",
        port: 8080,
        addresses: ["192.168.1.100", "fe80::1"]
      }

      assert {:ok, service_id} = ServiceRegistry.register_service(service_def)
      service = ServiceRegistry.get_service(service_id)

      assert length(service.addresses) == 2
      assert {192, 168, 1, 100} in service.addresses
    end

    test "normalizes service type" do
      # Service type without protocol should get _tcp added
      service_def = %{
        name: "Test",
        type: "_myapp",
        port: 8080
      }

      assert {:ok, service_id} = ServiceRegistry.register_service(service_def)
      service = ServiceRegistry.get_service(service_id)

      assert service.type == "_myapp._tcp"
    end

    test "sets source to :api by default" do
      service_def = %{
        name: "Test",
        type: "_http._tcp",
        port: 8080
      }

      assert {:ok, service_id} = ServiceRegistry.register_service(service_def)
      service = ServiceRegistry.get_service(service_id)

      assert service.source == :api
    end

    test "can set source to :file" do
      service_def = %{
        name: "File Service",
        type: "_http._tcp",
        port: 8080
      }

      assert {:ok, service_id} = ServiceRegistry.register_service(service_def, source: :file)
      service = ServiceRegistry.get_service(service_id)

      assert service.source == :file
    end

    test "rejects invalid service" do
      invalid_service = %{
        name: "Invalid",
        # Missing type and port
        type: nil,
        port: nil
      }

      assert {:error, _reason} = ServiceRegistry.register_service(invalid_service)
    end
  end

  describe "unregister_service/2" do
    test "unregisters an existing service" do
      service_def = %{name: "Temp Service", type: "_http._tcp", port: 8080}

      {:ok, service_id} = ServiceRegistry.register_service(service_def)
      assert ServiceRegistry.get_service(service_id) != nil

      assert :ok = ServiceRegistry.unregister_service(service_id)
      assert ServiceRegistry.get_service(service_id) == nil
    end

    test "returns error for non-existent service" do
      assert {:error, :not_found} =
               ServiceRegistry.unregister_service("nonexistent._http._tcp.local")
    end

    test "goodbye records for the unregistered service all have TTL=0 (RFC 6762 §10.1)" do
      # Verify that build_goodbye_records produces TTL=0 records for any
      # registered service — these are the records that ServiceRegistry sends
      # to the multicast group before removing the service from the registry.
      service_def = %{
        name: "Goodbye Test",
        type: "_http._tcp",
        port: 9090,
        addresses: ["127.0.0.1"]
      }

      {:ok, service_id} = ServiceRegistry.register_service(service_def)
      service = ServiceRegistry.get_service(service_id)

      goodbye_records = YellowDog.Mdns.RecordBuilder.build_goodbye_records(service)
      assert goodbye_records != [], "Expected at least one goodbye record"

      for record <- goodbye_records do
        assert record.ttl == 0, "Expected TTL=0, got #{record.ttl} for #{inspect(record.name)}"
      end

      # Service is removed from registry after unregister
      assert :ok = ServiceRegistry.unregister_service(service_id)
      assert ServiceRegistry.get_service(service_id) == nil
    end
  end

  describe "update_service/3" do
    test "updates service fields" do
      service_def = %{name: "Update Test", type: "_http._tcp", port: 8080}

      {:ok, service_id} = ServiceRegistry.register_service(service_def)

      updates = %{port: 9090, txt_records: %{"new" => "value"}}
      assert :ok = ServiceRegistry.update_service(service_id, updates)

      service = ServiceRegistry.get_service(service_id)
      assert service.port == 9090
      assert service.txt_records == %{"new" => "value"}
    end

    test "returns error for non-existent service" do
      assert {:error, :not_found} =
               ServiceRegistry.update_service("nonexistent._http._tcp.local", %{port: 9090})
    end
  end

  describe "toggle_service/1" do
    test "toggles service enabled state" do
      service_def = %{name: "Toggle Test", type: "_http._tcp", port: 8080}

      {:ok, service_id} = ServiceRegistry.register_service(service_def)
      service = ServiceRegistry.get_service(service_id)
      initial_enabled = service.enabled

      assert :ok = ServiceRegistry.toggle_service(service_id)
      service = ServiceRegistry.get_service(service_id)
      assert service.enabled == not initial_enabled

      assert :ok = ServiceRegistry.toggle_service(service_id)
      service = ServiceRegistry.get_service(service_id)
      assert service.enabled == initial_enabled
    end
  end

  describe "list_services/1" do
    setup do
      # Register a few test services
      {:ok, _} =
        ServiceRegistry.register_service(%{name: "Service 1", type: "_http._tcp", port: 8080})

      {:ok, _} =
        ServiceRegistry.register_service(%{
          name: "Service 2",
          type: "_ssh._tcp",
          port: 22,
          enabled: false
        })

      {:ok, _} =
        ServiceRegistry.register_service(%{name: "Service 3", type: "_ftp._tcp", port: 21},
          source: :file
        )

      :ok
    end

    test "lists all services by default" do
      services = ServiceRegistry.list_services()
      assert length(services) >= 3
    end

    test "filters enabled services" do
      services = ServiceRegistry.list_services(filter: :enabled)
      assert length(services) >= 2
      assert Enum.all?(services, & &1.enabled)
    end

    test "filters disabled services" do
      ServiceRegistry.register_service(%{
        name: "Disabled",
        type: "_test._tcp",
        port: 9999,
        enabled: false
      })

      services = ServiceRegistry.list_services(filter: :disabled)
      assert length(services) >= 1
      assert Enum.all?(services, &(not &1.enabled))
    end

    test "filters by source" do
      file_services = ServiceRegistry.list_services(source: :file)
      assert length(file_services) >= 1
      assert Enum.all?(file_services, &(&1.source == :file))

      api_services = ServiceRegistry.list_services(source: :api)
      assert length(api_services) >= 2
      assert Enum.all?(api_services, &(&1.source == :api))
    end

    test "sorts services by name" do
      services = ServiceRegistry.list_services()
      names = Enum.map(services, & &1.name)
      assert names == Enum.sort(names)
    end
  end

  describe "get_records_for_query/1" do
    setup do
      {:ok, _} =
        ServiceRegistry.register_service(%{
          name: "Web Server",
          type: "_http._tcp",
          port: 8080,
          addresses: ["192.168.1.100"]
        })

      {:ok, _} =
        ServiceRegistry.register_service(%{
          name: "SSH Server",
          type: "_ssh._tcp",
          port: 22
        })

      :ok
    end

    test "finds services matching PTR query" do
      question = %Question{
        name: "_http._tcp.local",
        type: :PTR,
        class: :IN
      }

      services = ServiceRegistry.get_records_for_query([question])
      assert length(services) == 1
      assert hd(services).name == "Web Server"
    end

    test "finds services matching SRV query" do
      question = %Question{
        name: "Web Server._http._tcp.local",
        type: :SRV,
        class: :IN
      }

      services = ServiceRegistry.get_records_for_query([question])
      assert length(services) == 1
      assert hd(services).name == "Web Server"
    end

    test "returns empty list for non-matching query" do
      question = %Question{
        name: "_nonexistent._tcp.local",
        type: :PTR,
        class: :IN
      }

      services = ServiceRegistry.get_records_for_query([question])
      assert services == []
    end

    test "handles multiple questions" do
      questions = [
        %Question{name: "_http._tcp.local", type: :PTR, class: :IN},
        %Question{name: "_ssh._tcp.local", type: :PTR, class: :IN}
      ]

      services = ServiceRegistry.get_records_for_query(questions)
      assert length(services) == 2
    end
  end

  describe "stats/0" do
    test "returns registry statistics" do
      # Register various services
      {:ok, _} =
        ServiceRegistry.register_service(%{name: "S1", type: "_http._tcp", port: 8080})

      {:ok, _} =
        ServiceRegistry.register_service(%{
          name: "S2",
          type: "_ssh._tcp",
          port: 22,
          enabled: false
        })

      {:ok, _} =
        ServiceRegistry.register_service(%{name: "S3", type: "_ftp._tcp", port: 21},
          source: :file
        )

      stats = ServiceRegistry.stats()

      assert stats.total >= 3
      assert stats.enabled >= 2
      assert stats.disabled >= 1
      assert stats.from_file >= 1
      assert stats.from_api >= 2
    end
  end

  describe "persistence" do
    @tag :tmp_dir
    test "can save and load services", %{tmp_dir: tmp_dir} do
      storage_file = Path.join(tmp_dir, "test_services.toml")

      # Stop the default registry started in setup
      stop_supervised(ServiceRegistry)

      # Start registry with custom storage file
      {:ok, _} =
        start_supervised(
          {ServiceRegistry, [storage_file: storage_file, load_on_start: false, auto_save: false]}
        )

      # Register services
      {:ok, _} =
        ServiceRegistry.register_service(%{name: "Persist Test", type: "_http._tcp", port: 8080})

      # Save to file
      assert :ok = ServiceRegistry.save_to_file()
      assert File.exists?(storage_file)

      # Verify file content
      {:ok, services} = YellowDog.Mdns.ServiceStore.load_services(storage_file)
      assert length(services) >= 1
    end
  end

  describe "control service mutations" do
    @tag :tmp_dir
    test "registers a canonical service ID with the normalized service type", %{tmp_dir: tmp_dir} do
      stop_supervised(ServiceRegistry)

      start_supervised!(
        {ServiceRegistry,
         [
           storage_file: Path.join(tmp_dir, "services.toml"),
           load_on_start: false,
           auto_save: false
         ]}
      )

      service = %{name: "Office Printer", type: "_ipp", port: 631, txt: %{"note" => "East"}}
      service_id = "Office Printer._ipp._tcp.local"

      assert {:ok, [], [registered]} =
               ServiceRegistry.control_register_service(service_id, service)

      assert registered.id == service_id
      assert registered.type == "_ipp._tcp"
      assert registered.host =~ ".local"
      assert registered.addresses == []
      assert registered.enabled
      assert registered.state == :registered
      assert {:ok, [^registered]} = ServiceRegistry.control_snapshot()
    end

    test "rejects a service ID that does not match the normalized service type" do
      service = %{name: "Office Printer", type: "_ipp", port: 631}

      assert {:error, :invalid_service_id} =
               ServiceRegistry.control_register_service("printer._ipp._tcp.local", service)
    end

    test "updates fixed fields while preserving hidden runtime fields" do
      original_def = %{
        name: "Catalog",
        type: "_http._tcp",
        port: 8080,
        host: "catalog-host",
        addresses: ["192.0.2.20"],
        enabled: false,
        txt: %{"version" => "1"}
      }

      assert {:ok, service_id} = ServiceRegistry.register_service(original_def, source: :file)
      original = ServiceRegistry.get_service(service_id)

      assert {:ok, [^original], [updated]} =
               ServiceRegistry.control_update_service(service_id, %{
                 name: "Catalog",
                 type: "_http._tcp",
                 port: 9090,
                 txt: %{"version" => "2"},
                 host: "ignored-host",
                 addresses: ["192.0.2.99"],
                 enabled: true
               })

      assert updated.port == 9090
      assert updated.txt_records == %{"version" => "2"}

      assert Map.take(updated, [
               :host,
               :addresses,
               :enabled,
               :source,
               :state,
               :registered_at,
               :last_announced
             ]) ==
               Map.take(original, [
                 :host,
                 :addresses,
                 :enabled,
                 :source,
                 :state,
                 :registered_at,
                 :last_announced
               ])
    end

    test "returns prior and resulting snapshots for toggle and delete" do
      service = %{name: "Status", type: "_http._tcp", port: 8080}
      service_id = "Status._http._tcp.local"

      assert {:ok, [], [registered]} =
               ServiceRegistry.control_register_service(service_id, service)

      assert {:ok, [^registered], [toggled]} = ServiceRegistry.control_toggle_service(service_id)
      refute toggled.enabled
      assert registered.enabled

      assert {:ok, [^toggled], []} = ServiceRegistry.control_delete_service(service_id)
    end

    @tag :tmp_dir
    test "persists the complete candidate before registry activation", %{tmp_dir: tmp_dir} do
      storage_file = Path.join(tmp_dir, "services.toml")
      parent = self()

      restart_control_registry(
        storage_file,
        control_apply_hook: fn _candidate ->
          send(parent, {:apply_after_save, ServiceStore.load_services(storage_file)})
          :ok
        end
      )

      service = %{name: "Durable", type: "_http._tcp", port: 8080}
      service_id = "Durable._http._tcp.local"

      assert {:ok, [], [_service]} = ServiceRegistry.control_register_service(service_id, service)
      assert_receive {:apply_after_save, {:ok, [persisted]}}, 1_000
      assert persisted.name == "Durable"
      assert persisted.port == 8080
    end

    @tag :tmp_dir
    test "leaves the prior registry and file untouched when candidate persistence fails", %{
      tmp_dir: tmp_dir
    } do
      storage_file = Path.join(tmp_dir, "services.toml")
      File.write!(storage_file, "prior durable file")

      restart_control_registry(storage_file,
        control_save_hook: fn _path, _services -> {:error, :disk_full} end
      )

      service = %{name: "Unsaved", type: "_http._tcp", port: 8080}

      assert {:error, :persistence_failed} =
               ServiceRegistry.control_register_service("Unsaved._http._tcp.local", service)

      assert {:ok, []} = ServiceRegistry.control_snapshot()
      assert {:ok, "prior durable file"} = File.read(storage_file)
    end

    @tag :tmp_dir
    test "restores the durable file before restoring the prior registry snapshot on apply failure",
         %{
           tmp_dir: tmp_dir
         } do
      storage_file = Path.join(tmp_dir, "services.toml")
      parent = self()
      {:ok, sequence} = Agent.start_link(fn -> [:error, :ok] end)

      restart_control_registry(
        storage_file,
        control_apply_hook: fn _candidate ->
          result = Agent.get_and_update(sequence, fn [result | rest] -> {result, rest} end)

          if result == :ok do
            send(parent, {:rollback_registry_apply, ServiceStore.load_services(storage_file)})
          end

          result
        end
      )

      old_service = %{name: "Old", type: "_http._tcp", port: 8080}
      assert {:ok, old_id} = ServiceRegistry.register_service(old_service)
      assert :ok = ServiceRegistry.save_to_file()

      assert {:error, :apply_failed} =
               ServiceRegistry.control_register_service("New._http._tcp.local", %{
                 name: "New",
                 type: "_http._tcp",
                 port: 8081
               })

      assert {:ok, [restored]} = ServiceRegistry.control_snapshot()
      assert restored.id == old_id
      assert_receive {:rollback_registry_apply, {:ok, [persisted_before_apply]}}, 1_000
      assert persisted_before_apply.name == "Old"
      assert {:ok, [persisted]} = ServiceStore.load_services(storage_file)
      assert persisted.name == "Old"
    end

    @tag :tmp_dir
    test "reports rollback failure distinctly when durable restoration fails", %{tmp_dir: tmp_dir} do
      storage_file = Path.join(tmp_dir, "services.toml")
      {:ok, saves} = Agent.start_link(fn -> [:ok, {:error, :disk_full}] end)

      restart_control_registry(
        storage_file,
        control_apply_hook: fn _candidate -> :error end,
        control_save_hook: fn path, services ->
          case Agent.get_and_update(saves, fn [result | rest] -> {result, rest} end) do
            :ok -> ServiceStore.save_services(path, services)
            result -> result
          end
        end
      )

      assert {:error, :rollback_failed} =
               ServiceRegistry.control_register_service("Rollback._http._tcp.local", %{
                 name: "Rollback",
                 type: "_http._tcp",
                 port: 8080
               })
    end

    test "returns a typed result when the registry is absent" do
      stop_supervised(ServiceRegistry)
      assert {:error, :registry_absent} = ServiceRegistry.control_snapshot()
    end

    test "rejects malformed complete snapshots without exposing persistence details" do
      assert {:error, :invalid_snapshot} =
               ServiceRegistry.control_commit_snapshot(
                 [%{id: "malformed"}],
                 {:registered, "malformed"}
               )
    end
  end

  defp restart_control_registry(storage_file, opts) do
    stop_supervised(ServiceRegistry)

    start_supervised!(
      {ServiceRegistry,
       Keyword.merge([storage_file: storage_file, load_on_start: false, auto_save: false], opts)}
    )
  end
end
