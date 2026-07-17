defmodule YellowDog.Config.ManagerTest do
  use ExUnit.Case, async: false

  alias YellowDog.Config.Manager
  alias YellowDog.Config.Schema
  alias YellowDog.Config.TomlHelpers

  defmodule ActivationOwner do
    def activate(service, config, context) do
      current_agent = Agent.get(context.config_agent, & &1)
      send(context.test_pid, {:activation, service, config, current_agent, self()})

      response =
        Agent.get_and_update(context.responses, fn
          [response | rest] -> {response, rest}
          [] -> {:ok, []}
        end)

      case response do
        :block ->
          receive do
            :continue_activation -> :ok
          end

        response ->
          response
      end
    end
  end

  defmodule FileOps do
    def read(context, path), do: run(context, path, :read, fn -> File.read(path) end)
    def mkdir_p(_context, path), do: File.mkdir_p(path)
    def ls(_context, path), do: File.ls(path)
    def rm(_context, path), do: File.rm(path)
    def chmod(_context, path, mode), do: File.chmod(path, mode)

    def open(context, path, modes) do
      run(context, path, :open, fn ->
        case :file.open(path, modes) do
          {:ok, device} -> {:ok, {device, path}}
          error -> error
        end
      end)
    end

    def write(context, {device, path}, contents),
      do: run(context, path, :write, fn -> :file.write(device, contents) end)

    def sync(context, {device, path}),
      do: run(context, path, :sync, fn -> :file.sync(device) end)

    def close(context, {device, path}),
      do: run(context, path, :close, fn -> :file.close(device) end)

    def rename(context, source, target) do
      run(context, target, :rename, fn -> :file.rename(source, target) end)
    end

    def sync_directory(context, path) do
      run(context, Path.join(path, ".directory-sync"), :sync_directory, fn -> :unsupported end)
    end

    defp run(context, path, operation, function) do
      scope = if target_path?(context.config_path, path), do: :target, else: :history
      key = {scope, operation}

      result =
        Agent.get_and_update(context.state, fn state ->
          count = Map.get(state.counts, key, 0) + 1
          failure = Map.get(state.failures, {key, count})
          {{count, failure}, %{state | counts: Map.put(state.counts, key, count)}}
        end)

      {count, failure} = result
      send(context.test_pid, {:file_op, key, count, path})

      case failure do
        nil -> function.()
        reason -> {:error, reason}
      end
    end

    defp target_path?(config_path, path) do
      path == config_path or
        (Path.dirname(path) == Path.dirname(config_path) and
           String.starts_with?(Path.basename(path), ".#{Path.basename(config_path)}."))
    end
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-config-manager-#{System.unique_integer([:positive])}"
      )

    config_path = Path.join(root, "yellow-dog.toml")
    history_dir = Path.join(root, "history")

    original = """
    # exact original bytes must survive rollback
    data_dir = "custom-data"

    [core]
    dns = true

    [dns]
    listen = "127.0.0.1"
    port = 53
    api_token = "do-not-disclose"
    zone_file = "/etc/yellowdog/private.zone"
    """

    File.mkdir_p!(root)
    File.write!(config_path, original)
    {:ok, parsed} = TomlHelpers.parse_toml(original)
    initial_config = Schema.merge_defaults(parsed)
    {:ok, config_agent} = Agent.start_link(fn -> initial_config end)
    {:ok, responses} = Agent.start_link(fn -> [] end)
    {:ok, file_state} = Agent.start_link(fn -> %{counts: %{}, failures: %{}} end)

    test_pid = self()

    activation_context = %{
      config_agent: config_agent,
      responses: responses,
      test_pid: test_pid
    }

    file_context = %{
      config_path: config_path,
      state: file_state,
      test_pid: test_pid
    }

    manager = :"config_manager_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Manager,
       name: manager,
       config_path: config_path,
       history_dir: history_dir,
       config_agent: config_agent,
       activation_owners: %{"dns" => {ActivationOwner, activation_context}},
       file_ops: {FileOps, file_context}}
    )

    on_exit(fn -> File.rm_rf(root) end)

    %{
      manager: manager,
      config_path: config_path,
      history_dir: history_dir,
      original: original,
      initial_config: initial_config,
      config_agent: config_agent,
      responses: responses,
      file_state: file_state,
      activation_context: activation_context,
      file_context: file_context
    }
  end

  test "updates only one service through durable install, Agent replacement, and activation",
       ctx do
    assert {:ok, state} =
             Manager.update("dns", [integer_entry("port", 5353)], server: ctx.manager)

    assert state["state"] == "applied"
    assert state["version"] == 2
    assert state["applied_revision"] == state["digest"]
    assert state["previous_version"] == 1
    assert digest?(state["previous_revision"])

    assert_receive {:activation, "dns", activated, current_agent, _manager}
    assert activated["port"] == 5353
    assert get_in(current_agent, ["dns", "port"]) == 5353
    assert get_in(current_agent, ["mdns", "port"]) == 5353

    {:ok, installed} = File.read(ctx.config_path)
    refute installed == ctx.original
    assert {:ok, decoded} = TomlHelpers.parse_toml(installed)
    assert get_in(decoded, ["dns", "port"]) == 5353
    assert get_in(decoded, ["mdns", "port"]) == 5353
  end

  test "durable versions continue after Manager restart", ctx do
    assert {:ok, first} =
             Manager.update("dns", [integer_entry("port", 5353)], server: ctx.manager)

    stop_supervised!(ctx.manager)

    restarted = :"restarted_manager_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Manager,
       name: restarted,
       config_path: ctx.config_path,
       history_dir: ctx.history_dir,
       config_agent: ctx.config_agent,
       activation_owners: %{"dns" => {ActivationOwner, ctx.activation_context}},
       file_ops: {FileOps, ctx.file_context}}
    )

    assert {:ok, second} =
             Manager.update("dns", [integer_entry("port", 5454)], server: restarted)

    assert first["version"] == 2
    assert second["version"] == 3
    assert second["previous_version"] == 2
    assert second["previous_revision"] == first["digest"]
  end

  test "rejects stale expected revisions without writing or activating", ctx do
    stale_revision = String.duplicate("0", 64)

    assert {:error, :stale_revision} =
             Manager.update("dns", [integer_entry("port", 5353)],
               server: ctx.manager,
               expected_revision: stale_revision
             )

    assert File.read!(ctx.config_path) == ctx.original
    refute_receive {:activation, _, _, _, _}
  end

  test "rejects invalid TOML and full-schema invalid candidates before installation", ctx do
    assert :ok = File.write(ctx.config_path, "[dns\nport = 53\n")

    assert {:ok,
            %{
              "service" => "dns",
              "valid" => false,
              "errors" => [%{"field" => "config", "message" => "invalid TOML"}]
            }} = Manager.validation("dns", server: ctx.manager)

    assert {:error, :invalid_config} = Manager.update("dns", [], server: ctx.manager)

    assert :ok = File.write(ctx.config_path, ctx.original)

    assert {:ok, failed} =
             Manager.update("dns", [integer_entry("port", 70_000)], server: ctx.manager)

    assert failed["state"] == "failed"
    assert failed["failure"]["phase"] == "validation"
    assert failed["previous_version"] == nil
    assert failed["previous_revision"] == nil
    assert failed["rollback"] == nil
    assert File.read!(ctx.config_path) == ctx.original
    assert Agent.get(ctx.config_agent, & &1) == ctx.initial_config
    refute_receive {:activation, _, _, _, _}
  end

  test "restores exact bytes, prior Agent state, and prior runtime after activation failure",
       ctx do
    Agent.update(ctx.responses, fn _ -> [{:error, :activation_failed}, :ok] end)

    assert {:ok, failed} =
             Manager.update("dns", [integer_entry("port", 5353)], server: ctx.manager)

    assert failed["state"] == "failed"
    assert failed["failure"] == %{"phase" => "apply", "reason" => "activation failed"}

    assert failed["rollback"] == %{
             "succeeded" => true,
             "restored_version" => 1,
             "restored_revision" => failed["previous_revision"],
             "reason" => nil
           }

    assert File.read!(ctx.config_path) == ctx.original
    assert Agent.get(ctx.config_agent, & &1) == ctx.initial_config

    assert_receive {:activation, "dns", candidate, candidate_agent, _}
    assert candidate["port"] == 5353
    assert get_in(candidate_agent, ["dns", "port"]) == 5353

    assert_receive {:activation, "dns", restored, restored_agent, _}
    assert restored["port"] == 53
    assert restored_agent == ctx.initial_config
  end

  test "reports rollback_failed distinctly when prior runtime reactivation fails", ctx do
    Agent.update(ctx.responses, fn _ ->
      [{:error, :activation_failed}, {:error, :reactivation_failed}]
    end)

    assert {:error, {:rollback_failed, failed}} =
             Manager.update("dns", [integer_entry("port", 5353)], server: ctx.manager)

    assert failed["state"] == "failed"
    assert failed["failure"] == %{"phase" => "rollback", "reason" => "rollback failed"}

    assert failed["rollback"] == %{
             "succeeded" => false,
             "restored_version" => nil,
             "restored_revision" => nil,
             "reason" => "runtime reactivation failed"
           }

    assert File.read!(ctx.config_path) == ctx.original
    assert Agent.get(ctx.config_agent, & &1) == ctx.initial_config
  end

  test "failed versions remain immutable history but do not become the prior applied version",
       ctx do
    Agent.update(ctx.responses, fn _ -> [{:error, :activation_failed}, :ok, :ok] end)

    assert {:ok, failed} =
             Manager.update("dns", [integer_entry("port", 5353)], server: ctx.manager)

    assert failed["version"] == 2

    assert {:ok, applied} =
             Manager.update("dns", [integer_entry("port", 5454)], server: ctx.manager)

    assert applied["version"] == 3
    assert applied["previous_version"] == 1
    assert applied["previous_revision"] == failed["previous_revision"]

    assert {:error, :stale_revision} =
             Manager.rollback("dns", failed["digest"], server: ctx.manager)
  end

  for {operation, failure_count} <- [write: 1, sync: 1, close: 1, rename: 1, read: 2] do
    test "restores all prior state after target #{operation} failure", ctx do
      operation = unquote(operation)
      failure_count = unquote(failure_count)

      Agent.update(ctx.file_state, fn state ->
        put_in(state, [:failures, {{:target, operation}, failure_count}], :injected_failure)
      end)

      assert {:ok, failed} =
               Manager.update("dns", [integer_entry("port", 5353)], server: ctx.manager)

      assert failed["state"] == "failed"
      assert failed["rollback"]["succeeded"]
      assert File.read!(ctx.config_path) == ctx.original
      assert Agent.get(ctx.config_agent, & &1) == ctx.initial_config
      assert_receive {:activation, "dns", restored, restored_agent, _}
      assert restored["port"] == 53
      assert restored_agent == ctx.initial_config
      refute_receive {:activation, "dns", %{"port" => 5353}, _, _}
    end
  end

  test "rolls back a service to a durable target revision without reverting other services",
       ctx do
    assert {:ok, first} =
             Manager.update("dns", [integer_entry("port", 5353)], server: ctx.manager)

    Agent.update(ctx.config_agent, fn config ->
      put_in(config, ["mdns", "port"], 5454)
    end)

    installed = File.read!(ctx.config_path)
    {:ok, parsed} = TomlHelpers.parse_toml(installed)
    updated_file = put_in(parsed, ["mdns", "port"], 5454)
    :ok = YellowDog.Config.Writer.write_config(ctx.config_path, updated_file, header: nil)

    assert {:ok, second} =
             Manager.update("dns", [integer_entry("port", 5555)], server: ctx.manager)

    assert {:ok, rolled_back} =
             Manager.rollback("dns", first["digest"], server: ctx.manager)

    assert rolled_back["state"] == "applied"
    assert rolled_back["version"] == second["version"] + 1
    assert get_in(Agent.get(ctx.config_agent, & &1), ["dns", "port"]) == 5353
    assert get_in(Agent.get(ctx.config_agent, & &1), ["mdns", "port"]) == 5454

    assert {:error, :stale_revision} =
             Manager.rollback("dns", String.duplicate("f", 64), server: ctx.manager)
  end

  test "safe reads expose typed redacted entries without paths or raw TOML", ctx do
    assert {:ok, effective} = Manager.effective("dns", server: ctx.manager)
    assert effective["service"] == "dns"
    assert entry_value(effective["entries"], "port") == %{"type" => "integer", "value" => 53}

    assert entry_value(effective["entries"], "api_token") == %{
             "type" => "string",
             "value" => "[REDACTED]"
           }

    assert entry_value(effective["entries"], "zone_file") == %{
             "type" => "string",
             "value" => "[REDACTED]"
           }

    inspected = inspect(effective)
    refute inspected =~ ctx.config_path
    refute inspected =~ ctx.original
    refute inspected =~ "do-not-disclose"

    assert {:ok, %{"service" => "dns", "source" => "local"}} =
             Manager.source("dns", server: ctx.manager)

    assert {:ok, %{"service" => "dns", "revision" => revision}} =
             Manager.revision("dns", server: ctx.manager)

    assert digest?(revision)

    assert {:ok, %{"service" => "dns", "valid" => true, "errors" => []}} =
             Manager.validation("dns", server: ctx.manager)

    assert {:ok, _state} =
             Manager.update("dns", [integer_entry("port", 5353)], server: ctx.manager)

    assert {:ok, %{"source" => "managed"}} = Manager.source("dns", server: ctx.manager)
  end

  test "apply requires a concrete owner and generic reload is unsupported", ctx do
    unsupported = :"unsupported_manager_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Manager,
       name: unsupported,
       config_path: ctx.config_path,
       history_dir: Path.join(Path.dirname(ctx.history_dir), "unsupported-history"),
       config_agent: ctx.config_agent,
       activation_owners: %{}}
    )

    assert {:error, :unsupported} = Manager.apply("dns", server: unsupported)
    assert {:error, :unsupported} = Manager.update("dns", [], server: unsupported)

    assert {:error, :unsupported} =
             Manager.rollback("dns", String.duplicate("0", 64), server: unsupported)

    assert {:error, :unsupported} = Manager.reload("dns", server: unsupported)

    assert {:ok, applied} = Manager.apply("dns", server: ctx.manager)
    assert applied["state"] == "applied"
    assert applied["version"] == 2
    assert_receive {:activation, "dns", %{"port" => 53}, _, _}
  end

  test "parseable but schema-invalid installed files are rejected safely", ctx do
    assert :ok = File.write(ctx.config_path, "[dns]\nport = 70000\n")

    assert {:ok, validation} = Manager.validation("dns", server: ctx.manager)
    refute validation["valid"]
    assert [%{"field" => "dns.port"}] = validation["errors"]

    assert {:error, :invalid_config} =
             Manager.update("dns", [integer_entry("port", 5353)], server: ctx.manager)

    assert {:error, :invalid_config} = Manager.effective("dns", server: ctx.manager)
    refute_receive {:activation, _, _, _, _}
  end

  test "typed entries reject unsafe values and apply recursive object deletions", ctx do
    unsafe_path = %{
      "key" => "listen",
      "value" => %{"type" => "string", "value" => "/etc/yellowdog/config"}
    }

    assert {:error, :invalid_entries} =
             Manager.update("dns", [unsafe_path], server: ctx.manager)

    object_entry = %{
      "key" => "runtime",
      "value" => %{
        "type" => "object",
        "entries" => [
          %{"key" => "mode", "value" => %{"type" => "string", "value" => "strict"}},
          %{"key" => "obsolete", "value" => %{"type" => "null", "value" => nil}}
        ]
      }
    }

    assert {:ok, applied} = Manager.update("dns", [object_entry], server: ctx.manager)
    assert applied["state"] == "applied"

    runtime = get_in(Agent.get(ctx.config_agent, & &1), ["dns", "runtime"])
    assert runtime == %{"mode" => "strict"}
  end

  test "each target replacement uses a unique same-directory temporary path", ctx do
    assert {:ok, _state} =
             Manager.update("dns", [integer_entry("port", 5353)], server: ctx.manager)

    assert {:ok, _state} =
             Manager.update("dns", [integer_entry("port", 5454)], server: ctx.manager)

    target_staging_paths =
      collect_file_operations([])
      |> Enum.filter(fn
        {{:target, :open}, _count, path} -> path != ctx.config_path
        _event -> false
      end)
      |> Enum.map(fn {_key, _count, path} -> path end)

    assert length(target_staging_paths) >= 2
    assert length(Enum.uniq(target_staging_paths)) == length(target_staging_paths)
    assert Enum.all?(target_staging_paths, &(Path.dirname(&1) == Path.dirname(ctx.config_path)))
  end

  test "same-path concurrent mutations are serialized", ctx do
    Agent.update(ctx.responses, fn _ -> [:block, :ok] end)

    first =
      Task.async(fn ->
        Manager.update("dns", [integer_entry("port", 5353)], server: ctx.manager)
      end)

    assert_receive {:activation, "dns", %{"port" => 5353}, _, manager_pid}

    second =
      Task.async(fn ->
        Manager.update("dns", [integer_entry("port", 5454)], server: ctx.manager)
      end)

    refute_receive {:activation, "dns", %{"port" => 5454}, _, _}, 100
    send(manager_pid, :continue_activation)

    assert {:ok, first_state} = Task.await(first)
    assert {:ok, second_state} = Task.await(second)
    assert first_state["version"] == 2
    assert second_state["version"] == 3
    assert get_in(Agent.get(ctx.config_agent, & &1), ["dns", "port"]) == 5454
  end

  test "canonical-path locking serializes distinct Manager processes", ctx do
    second_manager = :"second_manager_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Manager,
       name: second_manager,
       config_path:
         Path.join([Path.dirname(ctx.config_path), ".", Path.basename(ctx.config_path)]),
       history_dir: ctx.history_dir,
       config_agent: ctx.config_agent,
       activation_owners: %{"dns" => {ActivationOwner, ctx.activation_context}},
       file_ops: {FileOps, ctx.file_context}}
    )

    Agent.update(ctx.responses, fn _ -> [:block, :ok] end)

    first =
      Task.async(fn ->
        Manager.update("dns", [integer_entry("port", 5353)], server: ctx.manager)
      end)

    assert_receive {:activation, "dns", %{"port" => 5353}, _, first_manager_pid}

    second =
      Task.async(fn ->
        Manager.update("dns", [integer_entry("port", 5454)], server: second_manager)
      end)

    refute_receive {:activation, "dns", %{"port" => 5454}, _, _}, 100
    send(first_manager_pid, :continue_activation)

    assert {:ok, first_state} = Task.await(first)
    assert {:ok, second_state} = Task.await(second)
    assert first_state["version"] == 2
    assert second_state["version"] == 3
  end

  test "the yellow_dog_config application supervises the production Manager" do
    assert is_pid(Process.whereis(Manager))
  end

  defp integer_entry(key, value) do
    %{"key" => key, "value" => %{"type" => "integer", "value" => value}}
  end

  defp entry_value(entries, key) do
    entries
    |> Enum.find(&(&1["key"] == key))
    |> Map.fetch!("value")
  end

  defp digest?(digest), do: is_binary(digest) and byte_size(digest) == 64

  defp collect_file_operations(acc) do
    receive do
      {:file_op, key, count, path} ->
        collect_file_operations([{key, count, path} | acc])
    after
      0 -> acc
    end
  end
end
