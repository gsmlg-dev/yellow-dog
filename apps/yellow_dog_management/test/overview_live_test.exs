defmodule YellowDog.Management.OverviewLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias YellowDog.Management.{Audit, Domain, Idempotency, Repo}

  @endpoint YellowDog.ManagementUI.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    %{conn: build_conn()}
  end

  test "empty overview renders designed resources without login, writes or runtime fabrication",
       %{
         conn: conn
       } do
    before_read = footprint()

    for path <- ["/", "/management"] do
      {:ok, view, html} = live(conn, path)
      assert has_element?(view, "#management-overview")
      assert has_element?(view, "#management-worker-count", "0")
      assert has_element?(view, "#management-netman-count", "0")
      assert has_element?(view, "#management-zone-count", "0")
      refute has_element?(view, "#management-profile-count")
      refute has_element?(view, "a[href='/management/profiles']")
      refute has_element?(view, "#management-overview h2", "Profiles")
      assert has_element?(view, "#management-recent-event-count", "0")
      assert has_element?(view, "#management-recent-events-empty", "No management events yet")
      refute has_element?(view, "#management-recent-events [data-event-id]")
      refute has_element?(view, "input[type='password'], #login")
      assert html =~ "Actual runtime state is unknown"
      refute html =~ "Read-only Server and Netman presets"

      for {path, label} <- [
            {"/management/servers", "Manage Servers"},
            {"/management/netman", "Manage Netman"},
            {"/management/zones", "Manage DNS Zones"},
            {"/management/config", "Manage Configuration"},
            {"/management/events", "View All Events"}
          ] do
        assert has_element?(view, "#management-overview a[href='#{path}']", label)
      end

      view |> element("#management-overview-refresh") |> render_click()
      assert footprint() == before_read
    end

    started = Enum.map(Application.started_applications(), &elem(&1, 0))

    for legacy <- [
          :yellow_dog_console,
          :yellow_dog_management_core,
          :yellow_dog_server_agent,
          :yellow_dog_netman_agent
        ] do
      refute legacy in started
    end
  end

  test "latest five mixed durable mutations exactly match source order and fields", %{conn: conn} do
    seed_mutations()
    events = Domain.list_audit()
    assert length(events) == 7
    assert events |> Enum.take(5) |> Enum.map(& &1["operation"]) |> Enum.uniq() |> length() > 1
    before_read = footprint()
    {:ok, view, _html} = live(conn, "/management")
    assert_recent(view)
    assert has_element?(view, "#management-worker-count", "2")
    assert has_element?(view, "#management-netman-count", "1")
    assert has_element?(view, "#management-zone-count", "1")
    refute has_element?(view, "#management-profile-count")
    assert has_element?(view, "#management-recent-event-count", "5")

    for event <- Enum.drop(events, 5) do
      refute has_element?(view, "#management-recent-events [data-event-id='#{event["id"]}']")
    end

    for worker <- Domain.list_workers(), do: assert(worker["actual_state"] == "unknown")
    for netman <- Domain.list_netmans(), do: assert(netman["actual_state"] == "unknown")
    assert footprint() == before_read
  end

  test "event operation and actor are escaped as text, not executable HTML", %{conn: conn} do
    event =
      audit(
        "<svg onload='alert(1)'> & operation",
        "<script>alert('actor')</script> & operator"
      )

    before_read = footprint()
    {:ok, view, html} = live(conn, "/management")
    assert_recent(view)

    assert has_element?(
             view,
             "#management-recent-events [data-event-id='#{event.id}']",
             event.operation
           )

    assert html =~ "&lt;svg"
    assert html =~ "&lt;script&gt;"
    assert html =~ "&amp; operator"
    refute has_element?(view, "#management-recent-events svg, #management-recent-events script")
    view |> element("#management-overview-refresh") |> render_click()
    assert_recent(view)
    assert footprint() == before_read
  end

  test "explicit refresh reloads every widget without creating or changing audit records", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, "/management")
    assert has_element?(view, "#management-recent-event-count", "0")
    seed_mutations()
    assert has_element?(view, "#management-worker-count", "0")
    assert has_element?(view, "#management-netman-count", "0")
    assert has_element?(view, "#management-zone-count", "0")
    before_refresh = footprint()
    view |> element("#management-overview-refresh") |> render_click()
    assert_recent(view)
    assert has_element?(view, "#management-worker-count", "2")
    assert has_element?(view, "#management-netman-count", "1")
    assert has_element?(view, "#management-zone-count", "1")
    refute has_element?(view, "#management-profile-count")
    refute has_element?(view, "#management-recent-events-empty")
    assert footprint() == before_refresh
    render_click(view, "refresh", %{"actor" => "forged", "operation" => "create_worker"})
    assert_recent(view)
    assert footprint() == before_refresh
  end

  test "fewer than five events use their actual count and refresh keeps source tie order", %{
    conn: conn
  } do
    timestamp = DateTime.utc_now()
    audit("first", "first-actor", timestamp)
    audit("second", "second-actor", timestamp)
    {:ok, view, _html} = live(conn, "/management")
    assert_recent(view)
    assert has_element?(view, "#management-recent-event-count", "2")

    for index <- 3..7, do: audit("operation-#{index}", "actor-#{index}", timestamp)
    before_refresh = footprint()
    view |> element("#management-overview-refresh") |> render_click()
    assert_recent(view)
    assert has_element?(view, "#management-recent-event-count", "5")
    assert footprint() == before_refresh
  end

  defp assert_recent(view) do
    expected = Enum.take(Domain.list_audit(), 5)
    assert :sys.get_state(view.pid).socket.assigns.recent_events == expected

    for {event, position} <- Enum.with_index(expected, 1) do
      selector = "#management-recent-events tbody > tr:nth-child(#{position})"
      assert has_element?(view, "#{selector}[data-event-id='#{event["id"]}']")
      assert has_element?(view, "#{selector} > td:nth-child(1)", event["operation"])
      assert has_element?(view, "#{selector} > td:nth-child(2)", event["actor"])
      assert has_element?(view, "#{selector} > td:nth-child(3)", event["inserted_at"])
    end

    refute has_element?(
             view,
             "#management-recent-events tbody > tr:nth-child(#{length(expected) + 1})"
           )
  end

  defp seed_mutations do
    worker =
      mutate("create_worker", %{
        "id" => "overview-worker",
        "name" => "Overview Worker",
        "expected_capabilities" => ["dns"]
      })

    mutate("update_worker", %{
      "id" => worker["id"],
      "name" => "Updated Worker",
      "expected_revision" => worker["revision"]
    })

    netman = mutate("create_netman", %{"id" => "overview-netman", "name" => "Overview Netman"})

    mutate("update_netman", %{
      "id" => netman["id"],
      "name" => "Updated Netman",
      "expected_revision" => netman["revision"]
    })

    zone =
      mutate("create_zone", %{
        "name" => "overview.test.",
        "records" => [
          %{
            "name" => "overview.test.",
            "type" => "SOA",
            "ttl" => 300,
            "data" => %{
              "mname" => "ns.overview.test.",
              "rname" => "hostmaster.overview.test.",
              "serial" => 1,
              "refresh" => 3600,
              "retry" => 600,
              "expire" => 86400,
              "minimum" => 300
            }
          },
          %{
            "name" => "overview.test.",
            "type" => "NS",
            "ttl" => 300,
            "data" => %{"host" => "ns.overview.test."}
          },
          %{
            "name" => "ns.overview.test.",
            "type" => "A",
            "ttl" => 300,
            "data" => %{"address" => "192.0.2.53"}
          }
        ]
      })

    mutate("confirm_zone", %{"id" => zone["id"], "expected_revision" => zone["revision"]})

    mutate("create_worker", %{
      "id" => "overview-second",
      "name" => "Second Worker",
      "expected_capabilities" => ["dns"]
    })
  end

  defp mutate(operation, params) do
    assert {:ok, result} = Domain.mutate(operation, params, "operator", Ecto.UUID.generate())
    result
  end

  defp audit(operation, actor, timestamp \\ DateTime.utc_now()) do
    Repo.insert!(%Audit{
      operation: operation,
      actor: actor,
      request: %{},
      result: %{},
      inserted_at: timestamp
    })
  end

  defp footprint do
    {
      Domain.list_workers(),
      Domain.list_netmans(),
      Domain.list_zones(),
      Domain.list_audit(),
      Repo.all(Audit) |> Enum.sort_by(& &1.id),
      Repo.all(Idempotency) |> Enum.sort_by(& &1.key),
      Repo.all(Oban.Job, prefix: "management_jobs") |> Enum.sort_by(& &1.id)
    }
  end
end
