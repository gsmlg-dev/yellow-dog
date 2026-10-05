defmodule YellowDog.Management.ToolsLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint YellowDog.ManagementUI.Endpoint

  alias YellowDog.Management.MacDatabase

  setup do
    %{conn: build_conn()}
  end

  test "MAC lookup retains the original form and renders vendor data", %{conn: conn} do
    test_pid = self()

    put_lookup(:mac_lookup, fn mac ->
      send(test_pid, {:mac_lookup, mac})
      {:ok, "Example", "Example Manufacturer"}
    end)

    {:ok, view, html} = live(conn, "/tool/mac")
    assert html =~ "MAC Address Lookup"
    assert html =~ "Enter a MAC address to identify its manufacturer"

    view
    |> form("#mac-lookup-form", mac: " 00:00:0A:BB:28:FC ")
    |> render_submit()

    assert_receive {:mac_lookup, "00:00:0A:BB:28:FC"}
    assert has_element?(view, "#mac-lookup-result", "Example Manufacturer")
    assert has_element?(view, "#mac-lookup-result", "Example")
    assert has_element?(view, "#mac-lookup-result", "00:00:0A:BB:28:FC")
  end

  test "unknown MAC addresses show an error and blank input clears it", %{conn: conn} do
    test_pid = self()

    put_lookup(:mac_lookup, fn mac ->
      send(test_pid, {:mac_lookup, mac})
      :error
    end)

    {:ok, view, _html} = live(conn, "/tool/mac")
    html = view |> form("#mac-lookup-form", mac: "not-a-mac") |> render_submit()
    assert html =~ "No vendor found for this MAC address"
    assert_receive {:mac_lookup, "not-a-mac"}

    html = view |> form("#mac-lookup-form", mac: " ") |> render_submit()
    refute html =~ "No vendor found"
    refute has_element?(view, "#mac-lookup-result")
    assert has_element?(view, "input[name='mac'][value='']")
    refute_receive {:mac_lookup, _mac}
  end

  test "MAC tool uses the real compiled runtime database and distinguishes invalid input", %{
    conn: conn
  } do
    server = start_supervised!({MacDatabase, name: nil})
    put_lookup(:mac_database_server, server)
    {:ok, view, _html} = live(conn, "/tool/mac")

    view |> form("#mac-lookup-form", mac: "00:00:0A:BB:28:FC") |> render_submit()
    assert has_element?(view, "#mac-lookup-result", "Omron Tateisi Electronics Co.")

    assert view |> form("#mac-lookup-form", mac: "not-a-mac") |> render_submit() =~
             "Invalid MAC address"

    refute has_element?(view, "#mac-lookup-result")
  end

  test "MAC tool follows real file reloads and retains the valid snapshot after failure", %{
    conn: conn
  } do
    directory =
      Path.join(System.tmp_dir!(), "management-mac-tool-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    path = Path.join(directory, "manuf.txt")
    File.write!(path, "02:01:02\tOriginal\tOriginal Test Vendor\n")
    server = start_supervised!({MacDatabase, name: nil, path: path})
    await_mac_file(server)
    put_lookup(:mac_database_server, server)
    {:ok, view, _html} = live(conn, "/tool/mac")

    view |> form("#mac-lookup-form", mac: "02:01:02:03:04:05") |> render_submit()
    assert has_element?(view, "#mac-lookup-result", "Original Test Vendor")

    File.write!(path, "02:01:02\tUpdated\tUpdated Test Vendor\n")
    assert :ok = MacDatabase.reload(server)
    view |> form("#mac-lookup-form", mac: "02:01:02:03:04:05") |> render_submit()
    assert has_element?(view, "#mac-lookup-result", "Updated Test Vendor")

    File.write!(path, "not a manufacturer database\n")
    assert {:error, _reason} = MacDatabase.reload(server)
    view |> form("#mac-lookup-form", mac: "02:01:02:03:04:05") |> render_submit()
    assert has_element?(view, "#mac-lookup-result", "Updated Test Vendor")
  end

  test "WHOIS lookup runs asynchronously and renders escaped records", %{conn: conn} do
    test_pid = self()

    put_lookup(:whois_lookup, fn query ->
      send(test_pid, {:whois_lookup, query, self()})

      receive do
        :finish ->
          {:ok, [{"whois.example.test", "Domain: example.test\n<script>unsafe</script>"}]}
      end
    end)

    {:ok, view, html} = live(conn, "/tool/whois")
    assert html =~ "Enter a domain or IP address to query WHOIS records"

    view
    |> form("#whois-lookup-form", query: " example.test ")
    |> render_submit()

    assert_receive {:whois_lookup, "example.test", lookup_pid}
    assert lookup_pid != view.pid
    assert Process.alive?(view.pid)
    assert has_element?(view, "input[name='query'][disabled]")
    assert has_element?(view, "[role='status']")
    send(lookup_pid, :finish)

    html = render_async(view)
    assert has_element?(view, "#whois-lookup-result", "whois.example.test")
    assert html =~ "Domain: example.test"
    assert html =~ "&lt;script&gt;unsafe&lt;/script&gt;"
    refute has_element?(view, "input[name='query'][disabled]")
  end

  test "WHOIS connection failures retain a usable form", %{conn: conn} do
    put_lookup(:whois_lookup, fn query ->
      case query do
        "timeout.test" -> {:error, :timeout}
        "closed.test" -> {:error, :closed}
        "error.test" -> {:error, :unavailable}
      end
    end)

    {:ok, view, _html} = live(conn, "/tool/whois")

    for {query, message} <- [
          {"timeout.test", "Connection timed out"},
          {"closed.test", "Connection closed unexpectedly"},
          {"error.test", "Lookup failed: :unavailable"}
        ] do
      view |> form("#whois-lookup-form", query: query) |> render_submit()
      assert render_async(view) =~ message
      assert Process.alive?(view.pid)
      refute has_element?(view, "input[name='query'][disabled]")
    end
  end

  test "a stalled WHOIS lookup reaches a deadline, closes its task and permits retry", %{
    conn: conn
  } do
    test_pid = self()
    put_lookup(:whois_lookup_deadline_ms, 500)
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_address, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    put_lookup(:whois_lookup, fn query ->
      if query == "slow.test" do
        {:ok, connection} =
          :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)

        send(test_pid, {:stalled_whois, self()})
        :gen_tcp.recv(connection, 0)
      else
        {:ok, [{"whois.example.test", "Domain: retry.test"}]}
      end
    end)

    {:ok, view, _html} = live(conn, "/tool/whois")
    view |> form("#whois-lookup-form", query: "slow.test") |> render_submit()
    {:ok, peer} = :gen_tcp.accept(listener, 1_000)
    assert_receive {:stalled_whois, lookup_pid}
    monitor = Process.monitor(lookup_pid)
    assert_receive {:DOWN, ^monitor, :process, ^lookup_pid, _reason}, 1_000
    assert :gen_tcp.recv(peer, 0, 1_000) == {:error, :closed}
    :gen_tcp.close(peer)
    assert has_element?(view, "#whois-lookup-error", "Lookup deadline exceeded")
    assert has_element?(view, "input[name='query'][value='slow.test']")
    refute has_element?(view, "input[name='query'][disabled]")
    assert Process.alive?(view.pid)

    view |> form("#whois-lookup-form", query: "retry.test") |> render_submit()
    assert render_async(view) =~ "Domain: retry.test"
    refute has_element?(view, "#whois-lookup-error")
  end

  @tag capture_log: true
  test "a crashed WHOIS lookup does not terminate the page", %{conn: conn} do
    put_lookup(:whois_lookup, fn _query -> exit(:lookup_crashed) end)
    {:ok, view, _html} = live(conn, "/tool/whois")
    view |> form("#whois-lookup-form", query: "example.test") |> render_submit()

    assert render_async(view) =~ "Lookup failed: :lookup_crashed"
    assert Process.alive?(view.pid)
    refute has_element?(view, "input[name='query'][disabled]")
  end

  test "stale WHOIS deadlines cannot cancel a replacement query or erase a result", %{conn: conn} do
    test_pid = self()
    put_lookup(:whois_lookup_deadline_ms, 5_000)

    put_lookup(:whois_lookup, fn query ->
      send(test_pid, {:whois_task, query, self()})

      receive do
        :finish -> {:ok, [{"whois.example.test", "Domain: #{query}"}]}
      end
    end)

    {:ok, view, _html} = live(conn, "/tool/whois")
    view |> form("#whois-lookup-form", query: "old.test") |> render_submit()
    assert_receive {:whois_task, "old.test", old_pid}
    old_token = :sys.get_state(view.pid).socket.assigns.lookup_token
    old_monitor = Process.monitor(old_pid)

    render_submit(view, "lookup", %{"query" => "new.test"})
    assert_receive {:whois_task, "new.test", new_pid}
    assert_receive {:DOWN, ^old_monitor, :process, ^old_pid, _reason}
    new_state = :sys.get_state(view.pid).socket.assigns
    send(view.pid, {:whois_deadline, old_token})
    assert has_element?(view, "input[name='query'][value='new.test'][disabled]")
    assert Process.alive?(new_pid)
    refute has_element?(view, "#whois-lookup-error")

    send(new_pid, :finish)
    assert render_async(view) =~ "Domain: new.test"
    assert Process.read_timer(new_state.lookup_timer) == false
    send(view.pid, {:whois_deadline, new_state.lookup_token})
    assert has_element?(view, "#whois-lookup-result", "Domain: new.test")
    refute has_element?(view, "#whois-lookup-error")
  end

  test "clearing a pending WHOIS query cancels the task and its timer", %{conn: conn} do
    test_pid = self()
    put_lookup(:whois_lookup_deadline_ms, 5_000)

    put_lookup(:whois_lookup, fn _query ->
      send(test_pid, {:pending_whois, self()})

      receive do
        :finish -> {:ok, []}
      end
    end)

    {:ok, view, _html} = live(conn, "/tool/whois")
    view |> form("#whois-lookup-form", query: "pending.test") |> render_submit()
    assert_receive {:pending_whois, lookup_pid}
    monitor = Process.monitor(lookup_pid)
    timer = :sys.get_state(view.pid).socket.assigns.lookup_timer
    render_submit(view, "lookup", %{"query" => " "})
    assert_receive {:DOWN, ^monitor, :process, ^lookup_pid, _reason}
    assert Process.read_timer(timer) == false
    assert has_element?(view, "input[name='query'][value='']")
    refute has_element?(view, "input[name='query'][disabled]")
    refute has_element?(view, "#whois-lookup-result")
    refute has_element?(view, "#whois-lookup-error")
  end

  test "normal WHOIS page shutdown cancels the pending task and deadline", %{conn: conn} do
    test_pid = self()
    put_lookup(:whois_lookup_deadline_ms, 5_000)

    put_lookup(:whois_lookup, fn _query ->
      send(test_pid, {:pending_whois, self()})

      receive do
        :finish -> {:ok, []}
      end
    end)

    {:ok, view, _html} = live(conn, "/tool/whois")
    view |> form("#whois-lookup-form", query: "pending.test") |> render_submit()
    assert_receive {:pending_whois, lookup_pid}
    monitor = Process.monitor(lookup_pid)
    timer = :sys.get_state(view.pid).socket.assigns.lookup_timer
    on_exit(fn -> if Process.alive?(lookup_pid), do: Process.exit(lookup_pid, :kill) end)

    GenServer.stop(view.pid, :normal)
    assert_receive {:DOWN, ^monitor, :process, ^lookup_pid, _reason}, 1_000
    assert Process.read_timer(timer) == false
  end

  test "blank WHOIS input never invokes the external lookup", %{conn: conn} do
    test_pid = self()
    put_lookup(:whois_lookup, fn query -> send(test_pid, {:unexpected_lookup, query}) end)
    {:ok, view, _html} = live(conn, "/tool/whois")
    view |> form("#whois-lookup-form", query: " ") |> render_submit()

    assert_push_event(view, "reset_form", %{id: "whois-lookup-form"})
    assert has_element?(view, "#whois-lookup-form[phx-hook='ResetForm']")
    assert has_element?(view, "input[name='query'][value='']")
    refute has_element?(view, "#whois-lookup-result")
    refute_receive {:unexpected_lookup, _query}
  end

  defp await_mac_file(server, remaining \\ 100)
  defp await_mac_file(_server, 0), do: flunk("MAC fixture did not load")

  defp await_mac_file(server, remaining) do
    if MacDatabase.info(server).source == :file do
      :ok
    else
      Process.sleep(10)
      await_mac_file(server, remaining - 1)
    end
  end

  defp put_lookup(key, lookup) do
    previous = Application.fetch_env(:yellow_dog_management, key)
    Application.put_env(:yellow_dog_management, key, lookup)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:yellow_dog_management, key, value)
        :error -> Application.delete_env(:yellow_dog_management, key)
      end
    end)
  end
end
