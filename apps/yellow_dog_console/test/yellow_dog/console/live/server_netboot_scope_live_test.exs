defmodule YellowDog.Console.ServerNetbootScopeLiveTest do
  use YellowDog.Console.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias YellowDog.Console.ServerManagement
  alias YellowDog.Console.TestManagementTransport
  alias YellowDog.ManagementCore
  alias YellowDog.Sync.Digest

  @collection_revision String.duplicate("c", 64)
  @result_revision String.duplicate("d", 64)
  @observed_at "2026-08-11T03:04:05Z"

  setup do
    previous =
      Map.new([:data_dir, :transport_module, :request_timeout], fn key ->
        {key, Application.fetch_env(:yellow_dog_management_core, key)}
      end)

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-console-server-netboot-#{System.unique_integer([:positive])}"
      )

    Application.stop(:yellow_dog_management_core)
    Application.put_env(:yellow_dog_management_core, :data_dir, data_dir)
    Application.put_env(:yellow_dog_management_core, :transport_module, TestManagementTransport)
    Application.put_env(:yellow_dog_management_core, :request_timeout, 50)
    {:ok, _apps} = Application.ensure_all_started(:yellow_dog_management_core)
    start_supervised!(TestManagementTransport)

    register_server("server-a", "Alpha Server", :online)
    register_server("server-b", "Beta Server", :online)
    :ok = TestManagementTransport.connect(:server, "server-a")
    :ok = TestManagementTransport.connect(:server, "server-b")

    on_exit(fn ->
      Application.stop(:yellow_dog_management_core)
      Enum.each(previous, fn {key, value} -> restore_env(key, value) end)
      {:ok, _apps} = Application.ensure_all_started(:yellow_dog_management_core)
      File.rm_rf(data_dir)
    end)

    :ok
  end

  test "overview reads only the selected Server and preserves scoped navigation", %{conn: conn} do
    {:ok, alpha, _html} = mount_overview(conn, "server-a", "alpha")
    alpha_html = render(alpha)
    assert alpha_html =~ "Alpha Server"
    assert alpha_html =~ "alpha-profile"
    assert alpha_html =~ "alpha.bin"
    refute alpha_html =~ "beta-profile"

    for destination <- ["devices", "profiles", "tftp", "log"] do
      assert has_element?(alpha, "a[href='/server/server-a/netboot/#{destination}']")
    end

    assert has_element?(
             alpha,
             "a[href='/server/server-a/netboot/devices/02%3A00%3A00%3A00%3A00%3A0A']"
           )

    {:ok, beta, _html} = mount_overview(conn, "server-b", "beta")
    beta_html = render(beta)
    assert beta_html =~ "Beta Server"
    assert beta_html =~ "beta-profile"
    refute beta_html =~ "alpha-profile"

    assert Enum.map(request_envelopes(), & &1.target_id) ==
             List.duplicate("server-a", 4) ++ List.duplicate("server-b", 4)
  end

  test "profile put and delete use typed commands, UUIDs, and exact item digests", %{conn: conn} do
    profile = profile("alpha")

    :ok =
      TestManagementTransport.script_request([
        profile_list("alpha"),
        device_list("alpha"),
        {:ok, deleted("netboot_profile", "alpha-profile", %{"profile_id" => "alpha-profile"})}
      ])

    {:ok, profiles, _html} = live(conn, "/server/server-a/netboot/profiles")

    assert render_click(profiles, "delete_profile", %{"profile_id" => "alpha-profile"}) =~
             "Profile deleted"

    :ok =
      TestManagementTransport.script_request([
        profile_list("alpha"),
        asset_list("alpha"),
        device_list("alpha"),
        {:ok, revisioned("netboot_profile", "alpha-profile", profile)}
      ])

    {:ok, editor, _html} =
      live(conn, "/server/server-a/netboot/profiles/alpha-profile/edit")

    assert render_submit(editor, "save", %{
             "profile" => %{
               "profile_id" => "ignored-on-edit",
               "name" => "Alpha installer",
               "boot_asset_id" => "alpha-asset",
               "arguments" => "console=ttyS0\nip=dhcp"
             }
           }) =~ "Profile saved"

    command_envelopes =
      request_envelopes()
      |> Enum.filter(
        &(&1.operation in [
            "server.netboot.profiles.put",
            "server.netboot.profiles.delete"
          ])
      )

    assert Enum.map(command_envelopes, & &1.operation) == [
             "server.netboot.profiles.delete",
             "server.netboot.profiles.put"
           ]

    assert Enum.all?(command_envelopes, &(&1.target_id == "server-a"))
    assert Enum.all?(command_envelopes, &match?({:ok, _}, Ecto.UUID.cast(&1.idempotency_key)))
    assert command_envelopes |> Enum.map(& &1.idempotency_key) |> Enum.uniq() |> length() == 2
    assert Enum.all?(command_envelopes, &(&1.expected_revision == digest!(profile)))
    refute Enum.any?(command_envelopes, &(&1.expected_revision == @collection_revision))
  end

  test "new profile uses nil CAS while device update and delete use its exact digest", %{
    conn: conn
  } do
    new_profile = %{
      "profile_id" => "new-profile",
      "name" => "New profile",
      "boot_asset_id" => "alpha-asset",
      "arguments" => []
    }

    :ok =
      TestManagementTransport.script_request([
        profile_list("alpha"),
        asset_list("alpha"),
        device_list("alpha"),
        {:ok, revisioned("netboot_profile", "new-profile", new_profile)}
      ])

    {:ok, new_editor, _html} = live(conn, "/server/server-a/netboot/profiles/new")

    assert render_submit(new_editor, "save", %{
             "profile" => %{
               "profile_id" => "new-profile",
               "name" => "New profile",
               "boot_asset_id" => "alpha-asset",
               "arguments" => ""
             }
           }) =~ "Profile saved"

    device = device("alpha")
    updated = %{device | "profile_id" => "new-profile"}

    :ok =
      TestManagementTransport.script_request([
        device_list("alpha"),
        profile_list("alpha"),
        {:ok, revisioned("netboot_device", device["device_id"], updated)},
        {:ok,
         deleted("netboot_device", device["device_id"], %{"device_id" => device["device_id"]})}
      ])

    {:ok, devices, _html} = live(conn, "/server/server-a/netboot/devices")

    assert render_change(devices, "assign_profile", %{
             "device_id" => device["device_id"],
             "profile_id" => "new-profile"
           }) =~ "Device profile updated"

    assert render_click(devices, "delete_device", %{"device_id" => device["device_id"]}) =~
             "Device deleted"

    envelopes = request_envelopes()
    create = Enum.find(envelopes, &(&1.operation == "server.netboot.profiles.put"))
    update = Enum.find(envelopes, &(&1.operation == "server.netboot.devices.put"))
    delete = Enum.find(envelopes, &(&1.operation == "server.netboot.devices.delete"))

    assert create.expected_revision == nil
    assert update.expected_revision == digest!(device)
    assert delete.expected_revision == digest!(updated)
    refute update.expected_revision == @collection_revision
    refute delete.expected_revision == @collection_revision
  end

  test "TFTP mutations without an exact owner revision are unavailable and issue no call", %{
    conn: conn
  } do
    :ok = TestManagementTransport.script_request([asset_list("alpha"), transfer_list("alpha")])
    {:ok, tftp, _html} = live(conn, "/server/server-a/netboot/tftp")

    assert has_element?(tftp, "#asset-upload-unavailable[disabled]")
    assert has_element?(tftp, "#asset-rescan-unavailable[disabled]")
    assert has_element?(tftp, "button[phx-click='delete_asset'][disabled]")
    assert render(tftp) =~ "exact owner revision"

    before = length(request_envelopes())
    assert render_click(tftp, "rescan", %{}) =~ "unavailable"
    assert render_click(tftp, "delete_asset", %{"asset_id" => "alpha-asset"}) =~ "unavailable"
    assert render_submit(tftp, "upload_asset", %{}) =~ "unavailable"
    assert length(request_envelopes()) == before
  end

  test "device detail and log pages stay within their selected Server", %{conn: conn} do
    for {server_id, prefix, mac} <- [
          {"server-a", "alpha", "02%3A00%3A00%3A00%3A00%3A0A"},
          {"server-b", "beta", "02%3A00%3A00%3A00%3A00%3A0B"}
        ] do
      :ok = TestManagementTransport.script_request([device_list(prefix), profile_list(prefix)])
      {:ok, detail, _html} = live(conn, "/server/#{server_id}/netboot/devices/#{mac}")
      detail_html = render(detail)
      assert detail_html =~ "#{prefix}-device"
      assert detail_html =~ "#{prefix}-profile"
      assert has_element?(detail, "a[href='/server/#{server_id}/netboot/devices']")

      :ok = TestManagementTransport.script_request([log_list(prefix)])
      {:ok, log, _html} = live(conn, "/server/#{server_id}/netboot/log")
      log_html = render(log)
      assert log_html =~ "#{prefix} booted"
      refute log_html =~ "#{other_prefix(prefix)} booted"
      assert has_element?(log, "a[href='/server/#{server_id}/netboot']")
    end

    assert Enum.all?(request_envelopes(), &(&1.target_id in ["server-a", "server-b"]))
    assert Enum.count(request_envelopes(), &(&1.operation == "server.netboot.logs.list")) == 2
  end

  test "offline cached snapshots render while profile and device mutations make no call", %{
    conn: conn
  } do
    :ok = TestManagementTransport.script_request([profile_list("alpha"), device_list("alpha")])
    assert %{status: :ok} = ServerManagement.netboot_profiles_list("server-a")
    assert %{status: :ok} = ServerManagement.netboot_devices_list("server-a")

    :ok = TestManagementTransport.disconnect(:server, "server-a")
    assert {:ok, _server} = ManagementCore.update_server_status("server-a", :offline)
    before = length(TestManagementTransport.recorded())

    {:ok, profiles, _html} = live(conn, "/server/server-a/netboot/profiles")
    assert render(profiles) =~ "Offline cached snapshot"
    assert render(profiles) =~ "alpha-profile"
    assert has_element?(profiles, "button[phx-click='delete_profile'][disabled]")

    assert render_click(profiles, "delete_profile", %{"profile_id" => "alpha-profile"}) =~
             "offline"

    {:ok, devices, _html} = live(conn, "/server/server-a/netboot/devices")
    assert render(devices) =~ "Offline cached snapshot"
    assert render(devices) =~ "02:00:00:00:00:0A"
    assert has_element?(devices, "button[phx-click='delete_device'][disabled]")

    assert render_change(devices, "assign_profile", %{
             "device_id" => "alpha-device",
             "profile_id" => "alpha-profile"
           }) =~ "offline"

    assert length(TestManagementTransport.recorded()) == before
  end

  defp mount_overview(conn, server_id, prefix) do
    :ok =
      TestManagementTransport.script_request([
        profile_list(prefix),
        device_list(prefix),
        asset_list(prefix),
        transfer_list(prefix)
      ])

    live(conn, "/server/#{server_id}/netboot")
  end

  defp register_server(id, name, status) do
    assert {:ok, _server} =
             ManagementCore.register_server(%{
               id: id,
               name: name,
               profile: :custom,
               status: status,
               last_seen_at: ~U[2026-08-11 03:04:05Z]
             })
  end

  defp profile_list(prefix), do: {:ok, list_result([profile(prefix)])}
  defp device_list(prefix), do: {:ok, list_result([device(prefix)])}
  defp asset_list(prefix), do: {:ok, list_result([asset(prefix)])}
  defp transfer_list(prefix), do: {:ok, list_result([transfer(prefix)])}
  defp log_list(prefix), do: {:ok, list_result([log_entry(prefix)])}

  defp profile(prefix) do
    %{
      "profile_id" => "#{prefix}-profile",
      "name" => "#{String.capitalize(prefix)} installer",
      "boot_asset_id" => "#{prefix}-asset",
      "arguments" => ["console=ttyS0", "ip=dhcp"]
    }
  end

  defp device(prefix) do
    %{
      "device_id" => "#{prefix}-device",
      "profile_id" => "#{prefix}-profile",
      "mac" => if(prefix == "alpha", do: "02:00:00:00:00:0A", else: "02:00:00:00:00:0B")
    }
  end

  defp asset(prefix) do
    %{
      "asset_id" => "#{prefix}-asset",
      "filename" => "#{prefix}.bin",
      "size" => if(prefix == "alpha", do: 1_024, else: 2_048),
      "blob_digest" => String.duplicate(if(prefix == "alpha", do: "a", else: "b"), 64)
    }
  end

  defp transfer(prefix) do
    %{
      "transfer_id" => "#{prefix}-transfer",
      "asset_id" => "#{prefix}-asset",
      "device_id" => "#{prefix}-device",
      "state" => "completed"
    }
  end

  defp log_entry(prefix) do
    %{
      "log_id" => "#{prefix}-log",
      "device_id" => "#{prefix}-device",
      "message" => "#{prefix} booted",
      "occurred_at" => @observed_at
    }
  end

  defp other_prefix("alpha"), do: "beta"
  defp other_prefix(_prefix), do: "alpha"

  defp list_result(items) do
    %{"items" => items, "revision" => @collection_revision, "observed_at" => @observed_at}
  end

  defp revisioned(resource_type, resource_id, resource) do
    %{
      "resource_type" => resource_type,
      "resource_id" => resource_id,
      "resource" => resource,
      "revision" => @result_revision
    }
  end

  defp deleted(resource_type, resource_id, resource_ref) do
    %{
      "resource_type" => resource_type,
      "resource_id" => resource_id,
      "resource_ref" => resource_ref,
      "revision" => @result_revision
    }
  end

  defp request_envelopes do
    for {:request, envelope, _timeout} <- TestManagementTransport.recorded(), do: envelope
  end

  defp digest!(resource) do
    assert {:ok, revision} = Digest.calculate(resource)
    revision
  end

  defp restore_env(key, {:ok, value}),
    do: Application.put_env(:yellow_dog_management_core, key, value)

  defp restore_env(key, :error), do: Application.delete_env(:yellow_dog_management_core, key)
end
