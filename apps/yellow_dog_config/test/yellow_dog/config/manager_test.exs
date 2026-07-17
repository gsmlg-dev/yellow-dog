defmodule YellowDog.Config.ManagerTest do
  use ExUnit.Case, async: false

  alias YellowDog.Config
  alias YellowDog.Config.Manager

  @digest String.duplicate("a", 64)
  @opaque_entry %{
    "key" => "enabled",
    "value" => %{"type" => "boolean", "value" => true}
  }

  setup do
    config = %{
      "dns" => %{
        "enabled" => true,
        "private_token" => "must-not-be-read"
      }
    }

    start_supervised!({Config, config})

    directory =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-config-manager-boundary-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)
    marker = Path.join(directory, "marker")
    File.write!(marker, "unchanged")

    handler_id = "config-manager-boundary-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:yellow_dog, :config, :loaded],
          [:yellow_dog, :config, :error]
        ],
        fn event, measurements, metadata, pid ->
          send(pid, {:config_telemetry, event, measurements, metadata})
        end,
        test_pid
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)
      File.rm_rf(directory)
    end)

    %{config: config, directory: directory}
  end

  test "all well-formed top-level operation shapes return stable typed unsupported" do
    assert Manager.effective("dns") == {:error, :unsupported}
    assert Manager.source("dns") == {:error, :unsupported}
    assert Manager.revision("dns") == {:error, :unsupported}
    assert Manager.validation("dns") == {:error, :unsupported}
    assert Manager.update("dns", []) == {:error, :unsupported}
    assert Manager.apply("dns") == {:error, :unsupported}
    assert Manager.reload("dns") == {:error, :unsupported}
    assert Manager.rollback("dns", @digest) == {:error, :unsupported}
  end

  test "every operation rejects only malformed or unbounded service identifiers" do
    invalid_services = [
      nil,
      :dns,
      "",
      "../dns",
      "dns/service",
      <<255>>,
      String.duplicate("a", 129)
    ]

    for service <- invalid_services do
      assert Manager.effective(service) == {:error, :invalid}
      assert Manager.source(service) == {:error, :invalid}
      assert Manager.revision(service) == {:error, :invalid}
      assert Manager.validation(service) == {:error, :invalid}
      assert Manager.update(service, [@opaque_entry]) == {:error, :invalid}
      assert Manager.apply(service) == {:error, :invalid}
      assert Manager.reload(service) == {:error, :invalid}
      assert Manager.rollback(service, @digest) == {:error, :invalid}
    end
  end

  test "service identifiers accept the bounded canonical edge" do
    service = String.duplicate("a", 128)

    assert Manager.effective(service) == {:error, :unsupported}
    assert Manager.update(service, []) == {:error, :unsupported}
  end

  test "update rejects wrong top-level containers and treats every list as opaque" do
    for payload <- [nil, %{}, "entries", 1, :entries] do
      assert Manager.update("dns", payload) == {:error, :invalid}
    end

    assert Manager.update("dns", [nil]) == {:error, :unsupported}
    assert Manager.update("dns", [@opaque_entry]) == {:error, :unsupported}
  end

  test "fixed-valid empty setting text is not independently rejected" do
    entries = [
      %{
        "key" => "label",
        "value" => %{"type" => "string", "value" => ""}
      }
    ]

    assert Manager.update("dns", entries) == {:error, :unsupported}
  end

  test "fixed-invalid semantic entry values remain opaque to the Manager" do
    fixed_invalid_entries = [
      %{"key" => "port", "value" => %{"type" => "integer", "value" => 53}},
      %{"key" => "path", "value" => %{"type" => "string", "value" => "/etc/shadow"}},
      %{
        "key" => "certificate_authority_uri",
        "value" => %{"type" => "string", "value" => "not-a-uri"}
      },
      %{
        "key" => "certificate",
        "value" => %{"type" => "string", "value" => "-----BEGIN CERTIFICATE-----"}
      },
      %{"key" => "enabled", "value" => %{"type" => "unknown", "value" => self()}},
      deeply_nested_value(2_000)
    ]

    assert Manager.update("dns", fixed_invalid_entries) == {:error, :unsupported}
  end

  test "large opaque entries return unsupported without payload traversal" do
    entries = List.duplicate(@opaque_entry, 250_000)
    {:reductions, before_call} = Process.info(self(), :reductions)

    assert Manager.update("dns", entries) == {:error, :unsupported}

    {:reductions, after_call} = Process.info(self(), :reductions)
    assert after_call - before_call < 500
  end

  test "rollback validates only the top-level reference type" do
    for revision <- [nil, 1, :revision, %{}, []] do
      assert Manager.rollback("dns", revision) == {:error, :invalid}
    end

    for revision <- ["", "not-a-digest", String.duplicate("A", 64), @digest] do
      assert Manager.rollback("dns", revision) == {:error, :unsupported}
    end
  end

  test "all calls leave files, Config Agent state, runtime processes, and telemetry untouched",
       ctx do
    files_before = directory_snapshot(ctx.directory)
    processes_before = MapSet.new(Process.list())

    results = [
      Manager.effective("dns"),
      Manager.source("dns"),
      Manager.revision("dns"),
      Manager.validation("dns"),
      Manager.update("dns", [%{"opaque" => ctx.config}]),
      Manager.apply("dns"),
      Manager.reload("dns"),
      Manager.rollback("dns", "opaque-reference")
    ]

    assert Enum.all?(results, &(&1 == {:error, :unsupported}))
    assert Config.get_all() == ctx.config
    assert directory_snapshot(ctx.directory) == files_before
    assert MapSet.new(Process.list()) == processes_before
    refute_receive {:config_telemetry, _, _, _}
    refute inspect(results) =~ "must-not-be-read"
  end

  test "the boundary has no process or storage owner" do
    refute function_exported?(Manager, :start_link, 1)
    refute function_exported?(Manager, :child_spec, 1)
    refute Code.ensure_loaded?(YellowDog.Config.Manager.Storage)
    refute is_pid(Process.whereis(Manager))
  end

  defp deeply_nested_value(depth) do
    Enum.reduce(1..depth, :leaf, fn _index, value -> [value] end)
  end

  defp directory_snapshot(directory) do
    directory
    |> File.ls!()
    |> Enum.sort()
    |> Map.new(fn name ->
      path = Path.join(directory, name)
      {name, File.read!(path)}
    end)
  end
end
