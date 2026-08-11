defmodule YellowDog.Server.Control.ManagedConfigControlTest do
  use ExUnit.Case, async: false

  alias YellowDog.Server.Control
  alias YellowDog.Server.Control.ManagedConfigControlTest.ConfigFake
  alias YellowDog.Server.Control.ManagedConfigControlTest.ManagerFake
  alias YellowDog.Server.Control.ManagedConfigControlTest.RuntimeFake
  alias YellowDog.Sync.Digest

  @revision String.duplicate("a", 64)

  setup do
    previous = Application.fetch_env(:yellow_dog, Control)

    Application.put_env(:yellow_dog, Control,
      config: ConfigFake,
      manager: ManagerFake,
      runtime: RuntimeFake,
      data_dir: "/var/lib/yellow-dog/agent"
    )

    ConfigFake.configure(bootstrap(), bootstrap())
    ManagerFake.configure(%{})
    RuntimeFake.configure(:ok)

    on_exit(fn ->
      ConfigFake.clear()
      ManagerFake.clear()
      RuntimeFake.clear()
      restore_env(previous)
    end)

    :ok
  end

  test "validates and installs only the aggregate Server config contract" do
    document = document(5_353)
    assert :ok = Control.validate_config(document)

    assert {:ok, @revision} =
             Control.install_config(document,
               version: 7,
               digest: digest(document),
               expected_revision: nil,
               operation: "server.config.replace",
               profile: :dns_only
             )

    assert ManagerFake.take_calls() == [
             {:validate_document, document},
             {:validate_document, document},
             {:install, "/var/lib/yellow-dog/agent", document}
           ]

    assert ConfigFake.get_all() == bootstrap()

    refute :ok == Control.validate_config(%{"service" => "dns", "entries" => []})

    refute match?(
             {:ok, _revision},
             Control.install_config(document,
               version: 7,
               digest: digest(document),
               operation: "server.settings.update"
             )
           )
  end

  test "activation hot-reconciles from the prior effective config" do
    previous = bootstrap()
    next = put_in(previous, ["dns", "port"], 5_353)
    ConfigFake.configure(previous, bootstrap())

    ManagerFake.configure(%{
      activate: {:ok, %{revision: @revision, config: next, recovery: "recovery-token"}}
    })

    assert :ok = Control.activate_config(@revision)

    assert ManagerFake.take_calls() == [
             {:activate, "/var/lib/yellow-dog/agent", @revision, bootstrap()}
           ]

    assert RuntimeFake.take_calls() == [{:reconcile_config, previous, next}]
  end

  test "restore selects the exact prior revision and reconciles affected services" do
    candidate = put_in(bootstrap(), ["dns", "port"], 5_353)
    restored = bootstrap()
    ConfigFake.configure(candidate, bootstrap())

    ManagerFake.configure(%{
      restore: {:ok, %{revision: @revision, config: restored, recovery: "recovery-token"}}
    })

    assert :ok = Control.restore_config(@revision)

    assert ManagerFake.take_calls() == [
             {:restore, "/var/lib/yellow-dog/agent", @revision, bootstrap()}
           ]

    assert RuntimeFake.take_calls() == [{:reconcile_config, candidate, restored}]
  end

  test "manager and reconcile failures are bounded and fail the apply callback" do
    document = document(5_353)
    ManagerFake.configure(%{validate_document: {:error, {:invalid_document, ["secret.path"]}}})

    assert {:error, :invalid_config} = Control.validate_config(document)

    ManagerFake.configure(%{activate: {:error, {:storage, "secret=/tmp/config"}}})
    assert {:error, :activation_failed} = Control.activate_config(@revision)

    previous = bootstrap()
    next = put_in(previous, ["dns", "port"], 5_353)

    ManagerFake.configure(%{
      activate: {:ok, %{revision: @revision, config: next, recovery: "recovery-token"}},
      compensate: {:ok, %{revision: nil, config: previous}}
    })

    RuntimeFake.configure({:error, {:restart_failed, "secret=/tmp/socket"}})

    assert {:error, :activation_failed} = Control.activate_config(@revision)

    assert ManagerFake.take_calls() == [
             {:activate, "/var/lib/yellow-dog/agent", @revision, bootstrap()},
             {:compensate, "/var/lib/yellow-dog/agent", "recovery-token", bootstrap()}
           ]

    assert RuntimeFake.take_calls() == [
             {:reconcile_config, previous, next},
             {:reconcile_config, next, previous}
           ]
  end

  defp bootstrap do
    %{
      "data_dir" => "/var/lib/yellow-dog",
      "dns" => %{"listen" => "0.0.0.0", "port" => 53},
      "yellow_dog_server" => %{
        "id" => "server-a",
        "profile" => "dns_only",
        "services" => %{"dns" => true, "server_agent" => true},
        "management" => %{"url" => "wss://management.example.test"}
      }
    }
  end

  defp document(port) do
    %{
      "schema_version" => 1,
      "profile" => "dns_only",
      "entries" => [
        %{
          "setting" => "dns.port",
          "value" => %{"type" => "integer", "value" => port}
        },
        %{
          "setting" => "services.dns.enabled",
          "value" => %{"type" => "boolean", "value" => true}
        }
      ]
    }
  end

  defp digest(value) do
    {:ok, digest} = Digest.calculate(value)
    digest
  end

  defp restore_env({:ok, value}), do: Application.put_env(:yellow_dog, Control, value)
  defp restore_env(:error), do: Application.delete_env(:yellow_dog, Control)

  defmodule ConfigFake do
    @key {__MODULE__, :state}

    def configure(effective, bootstrap),
      do: :persistent_term.put(@key, %{effective: effective, bootstrap: bootstrap})

    def clear, do: :persistent_term.erase(@key)
    def get_all, do: :persistent_term.get(@key).effective
    def bootstrap, do: :persistent_term.get(@key).bootstrap
  end

  defmodule ManagerFake do
    @key {__MODULE__, :state}
    @revision String.duplicate("a", 64)

    def configure(responses),
      do: :persistent_term.put(@key, %{responses: responses, calls: []})

    def clear, do: :persistent_term.erase(@key)

    def validate_document(document),
      do: invoke(:validate_document, {:validate_document, document}, :ok)

    def install(data_dir, document),
      do: invoke(:install, {:install, data_dir, document}, {:ok, @revision})

    def activate(data_dir, revision, bootstrap),
      do:
        invoke(
          :activate,
          {:activate, data_dir, revision, bootstrap},
          {:ok, %{revision: revision, config: bootstrap}}
        )

    def restore(data_dir, revision, bootstrap),
      do:
        invoke(
          :restore,
          {:restore, data_dir, revision, bootstrap},
          {:ok, %{revision: revision, config: bootstrap}}
        )

    def compensate(data_dir, recovery, bootstrap),
      do:
        invoke(
          :compensate,
          {:compensate, data_dir, recovery, bootstrap},
          {:ok, %{revision: nil, config: bootstrap}}
        )

    def take_calls do
      state = :persistent_term.get(@key)
      :persistent_term.put(@key, %{state | calls: []})
      Enum.reverse(state.calls)
    end

    defp invoke(key, call, default) do
      state = :persistent_term.get(@key)
      :persistent_term.put(@key, %{state | calls: [call | state.calls]})
      Map.get(state.responses, key, default)
    end
  end

  defmodule RuntimeFake do
    @key {__MODULE__, :state}

    def configure(result), do: :persistent_term.put(@key, %{result: result, calls: []})
    def clear, do: :persistent_term.erase(@key)

    def reconcile_config(previous, next) do
      state = :persistent_term.get(@key)
      call = {:reconcile_config, previous, next}
      :persistent_term.put(@key, %{state | calls: [call | state.calls]})
      state.result
    end

    def take_calls do
      state = :persistent_term.get(@key)
      :persistent_term.put(@key, %{state | calls: []})
      Enum.reverse(state.calls)
    end
  end
end
