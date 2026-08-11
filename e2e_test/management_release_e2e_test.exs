Code.compile_file("support/management_release.ex", __DIR__)

defmodule E2ETest.ManagementReleaseE2ETest do
  use ExUnit.Case, async: false

  alias E2ETest.ManagementRelease

  @moduletag :e2e
  @moduletag :management
  @moduletag :tmp_dir

  test "requires every coordinated release binary", %{tmp_dir: tmp_dir} do
    paths =
      ManagementRelease.release_binaries(tmp_dir)
      |> Map.put(:yellow_dog_netman, Path.join(tmp_dir, "missing-netman"))

    assert {:error,
            {:missing_release_binaries,
             [:yellow_dog_management_core, :yellow_dog_netman, :yellow_dog_server]}} =
             ManagementRelease.validate_release_binaries(paths)
  end

  @tag timeout: :infinity
  test "boots management, Server, and Netman releases as one verified control plane", %{
    tmp_dir: tmp_dir
  } do
    root = Path.expand("..", __DIR__)
    leaked_ra_dirs_before = leaked_ra_dirs(root)

    assert :ok = ManagementRelease.build_releases(root)

    assert :ok =
             root
             |> ManagementRelease.release_binaries()
             |> ManagementRelease.validate_release_binaries()

    assert {:ok, evidence} = ManagementRelease.run(root, tmp_dir)
    assert evidence =~ "untrusted management certificate rejected"
    assert evidence =~ "trusted management certificate accepted"

    assert evidence =~
             "server and netman release agents booted without SECRET_KEY_BASE and rejected untrusted management certificate"

    assert evidence =~ "untrusted server and netman release agents stopped cleanly"
    assert evidence =~ "server and netman release agents registered"
    assert evidence =~ "offline desired configuration applied"
    assert evidence =~ "failed activation restored known-good configuration"
    assert evidence =~ "management restart preserved durable control-plane state"
    assert leaked_ra_dirs(root) == leaked_ra_dirs_before
  end

  defp leaked_ra_dirs(root) do
    [root, Path.join(root, "data")]
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "yd_*_e2e_*@*")))
    |> Enum.filter(&File.dir?/1)
    |> Enum.sort()
  end
end
