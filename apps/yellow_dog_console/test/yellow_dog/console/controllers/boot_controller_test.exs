defmodule YellowDog.Console.BootControllerTest do
  use YellowDog.Console.ConnCase, async: false

  setup do
    # Clear device registry between tests
    if :ets.info(:netboot_device_registry) != :undefined do
      :ets.delete_all_objects(:netboot_device_registry)
    end

    :ok
  end

  describe "GET /boot/ipxe" do
    test "returns iPXE script without params", %{conn: conn} do
      conn = get(conn, "/boot/ipxe")
      body = response(conn, 200)

      assert get_resp_header(conn, "content-type") |> hd() =~ "text/plain"
      assert body =~ "#!ipxe"
    end

    test "returns iPXE script with mac param", %{conn: conn} do
      conn = get(conn, "/boot/ipxe?mac=AA:BB:CC:DD:EE:FF")
      body = response(conn, 200)

      assert body =~ "#!ipxe"
    end

    test "returns iPXE script with arch param", %{conn: conn} do
      conn = get(conn, "/boot/ipxe?mac=AA:BB:CC:DD:EE:FF&arch=x86_64")
      body = response(conn, 200)

      assert body =~ "#!ipxe"
    end

    test "registers device when mac provided", %{conn: conn} do
      get(conn, "/boot/ipxe?mac=AA:BB:CC:DD:EE:FF&arch=x86_64&uuid=test-uuid")

      assert {:ok, device} = YellowDog.Netboot.Device.Registry.get("AA:BB:CC:DD:EE:FF")
      assert device.arch == :x86_64
      assert device.uuid == "test-uuid"
    end
  end

  describe "GET /boot/assets/*path" do
    test "returns 404 for missing asset", %{conn: conn} do
      conn = get(conn, "/boot/assets/nonexistent.bin")
      assert response(conn, 404) =~ "Not found"
    end

    test "rejects path traversal", %{conn: conn} do
      conn = get(conn, "/boot/assets/../../../etc/passwd")
      assert response(conn, 400) =~ "Invalid path"
    end
  end

  describe "GET /boot/manifest/:device_id" do
    test "returns 404 for unknown device", %{conn: conn} do
      conn = get(conn, "/boot/manifest/FF:FF:FF:FF:FF:FF")
      assert json_response(conn, 404)["error"] == "no manifest found"
    end

    test "returns 404 for device with no profile", %{conn: conn} do
      YellowDog.Netboot.Device.Registry.register("AA:BB:CC:DD:EE:01")
      conn = get(conn, "/boot/manifest/AA:BB:CC:DD:EE:01")
      assert json_response(conn, 404)["error"] == "no manifest found"
    end
  end

  describe "POST /boot/register" do
    test "registers a new device", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/boot/register", %{mac: "AA:BB:CC:DD:EE:02", hostname: "test-host"})

      resp = json_response(conn, 200)
      assert resp["status"] == "ok"
      assert resp["mac"] == "AA:BB:CC:DD:EE:02"
    end

    test "returns error without mac", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/boot/register", %{hostname: "test"})

      assert json_response(conn, 400)["error"] == "mac required"
    end

    test "registers device with arch", %{conn: conn} do
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/boot/register", %{mac: "AA:BB:CC:DD:EE:03", arch: "x86_64"})

      assert {:ok, device} = YellowDog.Netboot.Device.Registry.get("AA:BB:CC:DD:EE:03")
      assert device.arch == :x86_64
    end
  end

  describe "POST /boot/status" do
    test "updates device status", %{conn: conn} do
      YellowDog.Netboot.Device.Registry.register("AA:BB:CC:DD:EE:04")

      # Move to booting first (discovered → booting is valid)
      YellowDog.Netboot.Device.Registry.update_state("AA:BB:CC:DD:EE:04", :booting)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/boot/status", %{mac: "AA:BB:CC:DD:EE:04", status: "installing"})

      resp = json_response(conn, 200)
      assert resp["status"] == "ok"
      assert resp["state"] == "installing"
    end

    test "returns error without mac", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/boot/status", %{status: "installed"})

      assert json_response(conn, 400)["error"] == "mac and status required"
    end

    test "returns error without status", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/boot/status", %{mac: "AA:BB:CC:DD:EE:05"})

      assert json_response(conn, 400)["error"] == "mac and status required"
    end
  end
end
