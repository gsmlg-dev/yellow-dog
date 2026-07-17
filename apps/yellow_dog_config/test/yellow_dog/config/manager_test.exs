defmodule YellowDog.Config.ManagerTest do
  use ExUnit.Case, async: false

  alias YellowDog.Config
  alias YellowDog.Config.Manager

  @digest String.duplicate("a", 64)
  @entry %{
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

  test "all well-formed Settings owner operations return stable typed unsupported" do
    assert Manager.effective("dns") == {:error, :unsupported}
    assert Manager.source("dns") == {:error, :unsupported}
    assert Manager.revision("dns") == {:error, :unsupported}
    assert Manager.validation("dns") == {:error, :unsupported}
    assert Manager.update("dns", [@entry]) == {:error, :unsupported}
    assert Manager.apply("dns") == {:error, :unsupported}
    assert Manager.reload("dns") == {:error, :unsupported}
    assert Manager.rollback("dns", @digest) == {:error, :unsupported}
  end

  test "every operation rejects malformed or unbounded service identifiers" do
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
      assert Manager.update(service, [@entry]) == {:error, :invalid}
      assert Manager.apply(service) == {:error, :invalid}
      assert Manager.reload(service) == {:error, :invalid}
      assert Manager.rollback(service, @digest) == {:error, :invalid}
    end
  end

  test "service identifiers accept the bounded canonical edge" do
    service = String.duplicate("a", 128)

    assert Manager.effective(service) == {:error, :unsupported}
    assert Manager.apply(service) == {:error, :unsupported}
  end

  test "update validates bounded recursively typed entry payloads" do
    invalid_payloads = [
      nil,
      %{},
      [nil],
      [%{"key" => "enabled"}],
      [%{"key" => "Enabled", "value" => %{"type" => "boolean", "value" => true}}],
      [%{"key" => "enabled", "value" => %{"type" => "boolean", "value" => "true"}}],
      [%{"key" => "enabled", "value" => %{"type" => "unknown", "value" => true}}],
      List.duplicate(@entry, 101)
    ]

    for payload <- invalid_payloads do
      assert Manager.update("dns", payload) == {:error, :invalid}
    end

    nested = %{
      "key" => "options",
      "value" => %{
        "type" => "object",
        "entries" => [
          %{
            "key" => "mode",
            "value" => %{"type" => "string", "value" => "strict"}
          },
          %{
            "key" => "attempts",
            "value" => %{"type" => "list", "items" => [1, 2, 3]}
          }
        ]
      }
    }

    assert Manager.update("dns", [nested]) == {:error, :unsupported}
  end

  test "update rejects oversized text and excessive nesting" do
    oversized = %{
      "key" => "label",
      "value" => %{"type" => "string", "value" => String.duplicate("a", 1_025)}
    }

    assert Manager.update("dns", [oversized]) == {:error, :invalid}
    assert Manager.update("dns", [nested_entry(9)]) == {:error, :invalid}
  end

  test "rollback requires a canonical digest" do
    invalid_revisions = [
      nil,
      "",
      String.duplicate("a", 63),
      String.duplicate("a", 65),
      String.duplicate("A", 64),
      String.duplicate("g", 64)
    ]

    for revision <- invalid_revisions do
      assert Manager.rollback("dns", revision) == {:error, :invalid}
    end

    assert Manager.rollback("dns", @digest) == {:error, :unsupported}
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
      Manager.update("dns", [@entry]),
      Manager.apply("dns"),
      Manager.reload("dns"),
      Manager.rollback("dns", @digest)
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

  defp nested_entry(depth) do
    value =
      Enum.reduce(1..depth, %{"type" => "boolean", "value" => true}, fn index, value ->
        %{
          "type" => "object",
          "entries" => [%{"key" => "level_#{index}", "value" => value}]
        }
      end)

    %{"key" => "options", "value" => value}
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
