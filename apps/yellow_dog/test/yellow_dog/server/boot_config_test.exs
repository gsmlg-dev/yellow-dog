defmodule YellowDog.Server.BootConfigTest do
  use ExUnit.Case, async: false

  alias YellowDog.Server.BootConfig
  alias YellowDog.Server.BootConfigTest.Manager
  alias YellowDog.Server.BootConfigTest.Selector

  @revision_a String.duplicate("a", 64)
  @secret "bootstrap-management-secret"

  setup do
    previous = Application.fetch_env(:yellow_dog, BootConfig)

    Application.put_env(:yellow_dog, BootConfig,
      selector: YellowDog.Server.BootConfigTest.Selector,
      manager: YellowDog.Server.BootConfigTest.Manager
    )

    Selector.configure(:no_managed_config)
    Manager.configure({:error, :not_found})
    Manager.configure_active({:error, :not_found})

    on_exit(fn ->
      Selector.clear()
      Manager.clear()
      restore_env(previous)
    end)

    :ok
  end

  test "uses the exact acknowledged journal revision for managed boot" do
    bootstrap = bootstrap()
    managed = put_in(bootstrap, ["dns", "port"], 5_353)
    Selector.configure({:ok, @revision_a})
    Manager.configure({:ok, %{revision: @revision_a, config: managed}})

    assert %{
             config: ^managed,
             source: :managed_known_good,
             revision: @revision_a,
             error: nil
           } = BootConfig.select(bootstrap, "/var/lib/yellow-dog/agent", "server-a")

    assert Selector.take_calls() == [{"/var/lib/yellow-dog/agent", "server-a"}]

    assert Manager.take_calls() == [
             {:boot_config, "/var/lib/yellow-dog/agent", @revision_a, bootstrap}
           ]
  end

  test "falls back to local bootstrap when no acknowledged managed revision exists" do
    bootstrap = bootstrap()

    assert %{config: ^bootstrap, source: :bootstrap, revision: nil, error: nil} =
             BootConfig.select(bootstrap, "/var/lib/yellow-dog/agent", "server-a")

    assert Selector.take_calls() == [{"/var/lib/yellow-dog/agent", "server-a"}]
    assert Manager.take_calls() == [{:active_revision, "/var/lib/yellow-dog/agent"}]
  end

  test "does not elevate bootstrap when the apply journal is missing after activation" do
    bootstrap = bootstrap()
    Manager.configure_active({:ok, @revision_a})

    assert %{
             config: nil,
             source: :managed_unavailable,
             revision: @revision_a,
             error: :missing_journal
           } = BootConfig.select(bootstrap, "/var/lib/yellow-dog/agent", "server-a")

    assert Manager.take_calls() == [{:active_revision, "/var/lib/yellow-dog/agent"}]
  end

  test "fails closed when the journal or exact managed revision is invalid" do
    bootstrap = bootstrap()

    for {selector_result, manager_result, expected_revision, expected_error} <- [
          {{:error, :corrupt}, {:error, :not_found}, nil, :corrupt_journal},
          {{:ok, @revision_a}, {:error, :corrupt}, @revision_a, :corrupt_revision},
          {{:ok, @revision_a}, {:ok, %{revision: @revision_a, config: "invalid"}}, @revision_a,
           :invalid_selection}
        ] do
      Selector.configure(selector_result)
      Manager.configure(manager_result)

      assert %{
               config: nil,
               source: :managed_unavailable,
               revision: ^expected_revision,
               error: ^expected_error
             } = BootConfig.select(bootstrap, "/var/lib/yellow-dog/agent", "server-a")
    end
  end

  test "incomplete bootstrap identity never probes agent storage" do
    bootstrap = bootstrap()

    for {data_dir, server_id} <- [
          {nil, "server-a"},
          {"relative", "server-a"},
          {"/var/lib/yellow-dog/agent", nil},
          {"/var/lib/yellow-dog/agent", "../server"}
        ] do
      assert %{config: ^bootstrap, source: :bootstrap, revision: nil} =
               BootConfig.select(bootstrap, data_dir, server_id)
    end

    assert Selector.take_calls() == []
    assert Manager.take_calls() == []
  end

  test "dependency failures are sanitized without exposing bootstrap secrets" do
    bootstrap = bootstrap()
    Selector.configure({:raise, "#{@secret} /private/path"})

    selection = BootConfig.select(bootstrap, "/var/lib/yellow-dog/agent", "server-a")

    assert selection.config == nil
    assert selection.source == :managed_unavailable
    assert selection.error == :selector_unavailable
    refute inspect(Map.delete(selection, :config)) =~ @secret
    refute inspect(Map.delete(selection, :config)) =~ "/private/path"
  end

  defp bootstrap do
    %{
      "data_dir" => "/var/lib/yellow-dog",
      "dns" => %{"port" => 53},
      "yellow_dog_server" => %{
        "id" => "server-a",
        "management" => %{"token" => @secret}
      }
    }
  end

  defp restore_env({:ok, value}), do: Application.put_env(:yellow_dog, BootConfig, value)
  defp restore_env(:error), do: Application.delete_env(:yellow_dog, BootConfig)

  defmodule Selector do
    @key {__MODULE__, :state}

    def configure(result), do: :persistent_term.put(@key, %{result: result, calls: []})
    def clear, do: :persistent_term.erase(@key)

    def select(data_dir, server_id) do
      state = :persistent_term.get(@key)
      :persistent_term.put(@key, %{state | calls: [{data_dir, server_id} | state.calls]})

      case state.result do
        {:raise, reason} -> raise reason
        result -> result
      end
    end

    def take_calls do
      state = :persistent_term.get(@key)
      :persistent_term.put(@key, %{state | calls: []})
      Enum.reverse(state.calls)
    end
  end

  defmodule Manager do
    @key {__MODULE__, :state}

    def configure(result),
      do:
        :persistent_term.put(@key, %{
          result: result,
          active_result: {:error, :not_found},
          calls: []
        })

    def configure_active(result) do
      state = :persistent_term.get(@key)
      :persistent_term.put(@key, %{state | active_result: result})
    end

    def clear, do: :persistent_term.erase(@key)

    def active_revision(data_dir) do
      state = :persistent_term.get(@key)
      :persistent_term.put(@key, %{state | calls: [{:active_revision, data_dir} | state.calls]})
      state.active_result
    end

    def boot_config(data_dir, revision, bootstrap) do
      state = :persistent_term.get(@key)
      call = {:boot_config, data_dir, revision, bootstrap}
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
