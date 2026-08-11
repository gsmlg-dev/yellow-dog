defmodule YellowDog.Console.FingerprintLiveTest do
  use YellowDog.Console.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias YellowDog.Console.TestManagementTransport
  alias YellowDog.ManagementCore

  setup do
    previous =
      Map.new([:data_dir, :transport_module, :request_timeout], fn key ->
        {key, Application.fetch_env(:yellow_dog_management_core, key)}
      end)

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-server-fingerprint-#{System.unique_integer([:positive, :monotonic])}"
      )

    Application.stop(:yellow_dog_management_core)
    Application.put_env(:yellow_dog_management_core, :data_dir, data_dir)
    Application.put_env(:yellow_dog_management_core, :transport_module, TestManagementTransport)
    Application.put_env(:yellow_dog_management_core, :request_timeout, 50)
    {:ok, _apps} = Application.ensure_all_started(:yellow_dog_management_core)
    start_supervised!(TestManagementTransport)

    assert {:ok, _server} =
             ManagementCore.register_server(%{
               id: "server-a",
               name: "Alpha Server",
               profile: :full,
               status: :online
             })

    :ok = TestManagementTransport.connect(:server, "server-a")

    on_exit(fn ->
      Application.stop(:yellow_dog_management_core)
      Enum.each(previous, fn {key, value} -> restore_env(key, value) end)
      {:ok, _apps} = Application.ensure_all_started(:yellow_dog_management_core)
      File.rm_rf(data_dir)
    end)

    :ok
  end

  test "Fingerprint pages are selected-Server scoped and make no unapproved runtime calls", %{
    conn: conn
  } do
    for {path, page_id} <- [
          {"devices", "fingerprint-devices"},
          {"devices/00%3A11%3A22%3A33%3A44%3A55", "fingerprint-device"},
          {"fingerprints", "fingerprint-fingerprints"}
        ] do
      {:ok, view, html} = live(conn, "/server/server-a/fingerprint/#{path}")
      assert html =~ "Alpha Server"
      assert html =~ "No approved Fingerprint management operation"
      assert has_element?(view, "##{page_id}")
    end

    assert request_envelopes() == []
  end

  defp request_envelopes do
    for {:request, envelope, _timeout} <- TestManagementTransport.recorded(), do: envelope
  end

  defp restore_env(key, {:ok, value}),
    do: Application.put_env(:yellow_dog_management_core, key, value)

  defp restore_env(key, :error), do: Application.delete_env(:yellow_dog_management_core, key)
end
