defmodule YellowDogIdentity.SupervisorTest do
  use ExUnit.Case, async: false

  alias YellowDogIdentity.Supervisor, as: IdentitySup

  # ---------------------------------------------------------------------------
  # init/1 return value (no running supervisor needed)
  # ---------------------------------------------------------------------------

  describe "init/1 return value" do
    test "returns {:ok, supervisor_spec} tuple" do
      assert {:ok, {sup_flags, children}} = IdentitySup.init([])
      assert is_map(sup_flags)
      assert is_list(children)
    end

    test "uses one_for_one strategy" do
      {:ok, {sup_flags, _children}} = IdentitySup.init([])
      assert sup_flags.strategy == :one_for_one
    end

    test "starts children in correct order: Registry, LeaseCache, post_init" do
      {:ok, {_sup_flags, children}} = IdentitySup.init([])

      assert length(children) == 3

      [first, second, third] = children

      assert first.start ==
               {YellowDogIdentity.Registry, :start_link, [[data_dir: "data/identity"]]}

      assert second.start == {YellowDogIdentity.Trust.DHCP.LeaseCache, :start_link, [[]]}
      assert third.id == :post_init
      assert third.restart == :temporary
    end

    test "uses default data_dir when no option is provided" do
      {:ok, {_sup_flags, [registry_spec | _]}} = IdentitySup.init([])

      {YellowDogIdentity.Registry, :start_link, [opts]} = registry_spec.start
      assert Keyword.get(opts, :data_dir) == "data/identity"
    end

    test "uses custom data_dir when provided" do
      {:ok, {_sup_flags, [registry_spec | _]}} =
        IdentitySup.init(data_dir: "/tmp/custom_identity")

      {YellowDogIdentity.Registry, :start_link, [opts]} = registry_spec.start
      assert Keyword.get(opts, :data_dir) == "/tmp/custom_identity"
    end

    test "LeaseCache child receives empty opts" do
      {:ok, {_sup_flags, [_registry, lease_cache_spec | _]}} = IdentitySup.init([])

      assert lease_cache_spec.start ==
               {YellowDogIdentity.Trust.DHCP.LeaseCache, :start_link, [[]]}
    end
  end

  # ---------------------------------------------------------------------------
  # Supervisor lifecycle (requires starting the process)
  #
  # The supervisor registers under a fixed name (__MODULE__), so only one
  # instance can exist at a time.  We use a single test that exercises all
  # lifecycle assertions, then cleanly shuts the supervisor down.
  # ---------------------------------------------------------------------------

  describe "start_link/1" do
    setup do
      stop_identity_supervisor()
      :ok
    end

    test "starts successfully with running children" do
      tmp_dir = make_tmp_dir()

      {:ok, pid} = start_identity_sup(tmp_dir)

      try do
        # Supervisor is alive
        assert Process.alive?(pid)

        # Has at least the core children (Registry + LeaseCache + post_init task)
        children = Supervisor.which_children(pid)
        assert length(children) >= 2

        # Core children are the correct modules
        child_ids = Enum.map(children, fn {id, _pid, _type, _modules} -> id end)
        assert YellowDogIdentity.Registry in child_ids
        assert YellowDogIdentity.Trust.DHCP.LeaseCache in child_ids

        # Core children are workers and alive (temporary tasks may be :undefined)
        core_children =
          Enum.filter(children, fn {id, _pid, _type, _mods} ->
            id in [YellowDogIdentity.Registry, YellowDogIdentity.Trust.DHCP.LeaseCache]
          end)

        Enum.each(core_children, fn {_id, child_pid, type, _modules} ->
          assert type == :worker
          assert is_pid(child_pid)
          assert Process.alive?(child_pid)
        end)
      after
        Supervisor.stop(pid, :normal)
        File.rm_rf!(tmp_dir)
      end
    end

    test "creates data_dir structure for Registry" do
      tmp_dir = make_tmp_dir()

      {:ok, pid} = start_identity_sup(tmp_dir)

      try do
        # The Registry should have created its subdirectories
        assert File.dir?(Path.join(tmp_dir, "hosts"))
        assert File.dir?(Path.join(tmp_dir, "tokens"))
      after
        Supervisor.stop(pid, :normal)
        File.rm_rf!(tmp_dir)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Config validation (exercised indirectly via init/1)
  # ---------------------------------------------------------------------------

  describe "validate_config graceful handling" do
    test "init succeeds when YellowDog.Config is not loaded" do
      # YellowDog.Config may not be available in the test environment,
      # and validate_config/0 handles this via Code.ensure_loaded check.
      assert {:ok, {_sup_flags, _children}} = IdentitySup.init([])
    end

    test "init always returns a valid supervisor spec regardless of config state" do
      # validate_config rescues exceptions from YellowDog.Config.get_all/0,
      # so init should always return a usable spec.
      assert {:ok, {sup_flags, children}} = IdentitySup.init([])
      assert sup_flags.strategy == :one_for_one
      assert length(children) == 3
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp make_tmp_dir do
    dir = Path.join(System.tmp_dir!(), "yd_sup_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp stop_identity_supervisor do
    # Terminate and delete identity from the core supervisor to prevent restart
    if Process.whereis(YellowDog.Supervisor) do
      Supervisor.terminate_child(YellowDog.Supervisor, YellowDogIdentity)
      Supervisor.delete_child(YellowDog.Supervisor, YellowDogIdentity)
    end

    # Stop and wait for the supervisor process to fully exit
    if sup = Process.whereis(YellowDogIdentity.Supervisor) do
      ref = Process.monitor(sup)
      Supervisor.stop(sup, :normal)

      receive do
        {:DOWN, ^ref, :process, ^sup, _} -> :ok
      after
        1000 -> :ok
      end
    end
  end

  # Starts the identity supervisor, retrying if the name is still registered
  defp start_identity_sup(tmp_dir, retries \\ 5)

  defp start_identity_sup(_tmp_dir, 0),
    do: raise("Could not start identity supervisor after retries")

  defp start_identity_sup(tmp_dir, retries) do
    case IdentitySup.start_link(data_dir: tmp_dir) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, _}} ->
        stop_identity_supervisor()
        start_identity_sup(tmp_dir, retries - 1)
    end
  end
end
