defmodule YellowDog.Management.EventsLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias YellowDog.Management.{Audit, Domain, Idempotency, Repo}

  @endpoint YellowDog.ManagementUI.Endpoint
  @worker_operations ~w(create_worker update_worker put_service assign unassign confirm_target)
  @netman_operations ~w(create_netman update_netman update_netman_config confirm_netman_config rollback_netman_config)

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    %{conn: build_conn()}
  end

  test "empty page is read-only, unauthenticated and explicit about its outcome limits", %{
    conn: conn
  } do
    before_read = footprint()
    {:ok, view, html} = live(conn, "/management/events")
    assert has_element?(view, "#management-events")
    assert has_element?(view, "#management-worker-events", "No Worker desired events")
    assert has_element?(view, "#management-netman-events", "No Netman desired events")
    assert has_element?(view, "#management-command-outcomes")
    refute has_element?(view, "#management-command-outcomes [data-event-id]")
    refute has_element?(view, "input[type='password'], #login")
    assert html =~ "latest 100 retained audit records"
    assert html =~ "Not all attempted or rejected requests are persisted"
    assert html =~ "not delivered/applied, remote or job-executor outcomes"
    view |> element("#management-events-refresh") |> render_click()
    assert footprint() == before_read
  end

  test "mixed actual domain mutations preserve audit order and explicit desired scope", %{
    conn: conn
  } do
    references = seed()
    source = Domain.list_audit()
    before_read = footprint()
    {:ok, view, _html} = live(conn, "/management/events")
    assert_source(view)

    workers = Enum.filter(source, &(&1["operation"] in @worker_operations))
    netmans = Enum.filter(source, &(&1["operation"] in @netman_operations))
    assert :sys.get_state(view.pid).socket.assigns.worker_events == workers
    assert :sys.get_state(view.pid).socket.assigns.netman_events == netmans

    for {events, group} <- [{workers, "worker"}, {netmans, "netman"}] do
      for {event, position} <- Enum.with_index(events, 1) do
        assert has_element?(
                 view,
                 "#management-#{group}-events-list > tr:nth-child(#{position}) button[phx-value-id='#{event["id"]}']"
               )
      end
    end

    for event <-
          Enum.reject(source, &(&1["operation"] in (@worker_operations ++ @netman_operations))) do
      refute has_element?(view, "#management-worker-events button[phx-value-id='#{event["id"]}']")
      refute has_element?(view, "#management-netman-events button[phx-value-id='#{event["id"]}']")
      assert has_element?(view, "#management-command-outcomes [data-event-id='#{event["id"]}']")
    end

    service = Enum.find(source, &(&1["operation"] == "put_service"))
    assert_target(view, service, "Worker events-worker")
    netman_version = Enum.find(source, &(&1["operation"] == "confirm_netman_config"))
    assert_target(view, netman_version, "Netman events-netman")
    zone_version = Enum.find(source, &(&1["operation"] == "confirm_zone"))
    assert_target(view, zone_version, "Zone #{references.zone["id"]}")

    refute has_element?(
             view,
             "#management-command-outcomes [data-event-id='#{zone_version["id"]}']",
             "Worker events-worker"
           )

    backup = Enum.find(source, &(&1["operation"] == "create_backup"))
    assert_target(view, backup, "Backup #{references.backup["id"]}")

    assert has_element?(
             view,
             "#management-command-outcomes [data-event-id='#{backup["id"]}'][data-outcome='committed']"
           )

    assert references.backup["state"] == "pending"
    assert Map.has_key?(backup["result"], "error")
    assert is_nil(backup["result"]["error"])
    assert_target(view, Enum.find(source, &(&1["operation"] == "update_task")), "Task ip_city")
    assert footprint() == before_read
  end

  test "persisted duplicate rejection exposes the actual code and selects the same safe JSON", %{
    conn: conn
  } do
    seed()
    source = Domain.list_audit()

    rejection =
      Enum.find(source, &(&1["operation"] == "create_worker" and is_map(&1["result"]["error"])))

    assert rejection["result"]["error"]["code"] == "conflict"
    before_read = footprint()
    {:ok, view, html} = live(conn, "/management/events")
    row = "#management-command-outcomes [data-event-id='#{rejection["id"]}']"

    assert has_element?(
             view,
             "#{row}[data-outcome='rejected'][data-operation='create_worker']",
             "conflict"
           )

    assert_target(view, rejection, "Worker events-worker")
    assert html =~ "&lt;script&gt;"
    refute has_element?(view, "#management-events script, #management-worker-events script")

    view
    |> element("#{row} button[phx-click='show'][phx-value-id='#{rejection["id"]}']")
    |> render_click()

    assert :sys.get_state(view.pid).socket.assigns.selected == rejection
    assert_details(view, rejection)
    assert render(view) =~ "&lt;script&gt;"
    refute has_element?(view, "#event-details script")
    assert footprint() == before_read
  end

  test "audited invalid target shapes remain inspectable without an invented identity", %{
    conn: conn
  } do
    assert {:error, %{code: "invalid_request"}} =
             Domain.mutate(
               "create_zone",
               %{"content" => "not an object"},
               "operator",
               Ecto.UUID.generate()
             )

    event = hd(Domain.list_audit())
    before_read = footprint()
    {:ok, view, _html} = live(conn, "/management/events")
    assert_source(view)
    assert_target(view, event, "Zone (unspecified target)")
    refute has_element?(view, "#management-worker-events button[phx-value-id='#{event["id"]}']")
    refute has_element?(view, "#management-netman-events button[phx-value-id='#{event["id"]}']")

    view
    |> element("#management-command-outcomes button[phx-value-id='#{event["id"]}']")
    |> render_click()

    assert_details(view, event)
    assert footprint() == before_read
  end

  test "unknown and other nonpersisted failures cannot invent command outcomes", %{conn: conn} do
    params = %{"id" => "events-replay", "name" => "Replay", "expected_capabilities" => ["dns"]}
    key = Ecto.UUID.generate()
    assert {:ok, created} = Domain.mutate("create_worker", params, "operator", key)
    before_attempt = footprint()
    assert {:ok, ^created} = Domain.mutate("create_worker", params, "operator", key)

    assert {:error, %{code: "idempotency_conflict"}} =
             Domain.mutate("create_worker", Map.put(params, "name", "Different"), "operator", key)

    assert {:error, %{code: "invalid_request"}} =
             Domain.mutate(
               "unknown_operation",
               %{"worker_id" => created["id"]},
               "operator",
               Ecto.UUID.generate()
             )

    assert {:error, %{code: "invalid_request"}} =
             Domain.mutate(
               "create_worker",
               params,
               String.duplicate("x", 129),
               Ecto.UUID.generate()
             )

    assert footprint() == before_attempt
    {:ok, view, _html} = live(conn, "/management/events")
    assert_source(view)
    refute has_element?(view, "#management-command-outcomes [data-outcome='rejected']")
    refute has_element?(view, "#management-command-outcomes [data-operation='unknown_operation']")
    assert footprint() == before_attempt
  end

  test "refresh reloads every group and clears details without mutating data", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/management/events")
    seed()
    refute has_element?(view, "#management-command-outcomes [data-event-id]")
    before_refresh = footprint()
    view |> element("#management-events-refresh") |> render_click()
    assert_source(view)
    selected = hd(Domain.list_audit())
    view |> element("#management-events tbody > tr:first-child button") |> render_click()
    assert_details(view, selected)
    render_click(view, "refresh", %{"operation" => "create_worker", "actor" => "forged"})
    refute has_element?(view, "#event-details")
    assert_source(view)

    for id <- [Ecto.UUID.generate(), %{"id" => selected["id"]}, [selected["id"]], nil] do
      render_click(view, "show", %{"id" => id})
      refute has_element?(view, "#event-details")
    end

    assert footprint() == before_refresh
  end

  test "only the latest hundred persisted audits populate all views and detail selection", %{
    conn: conn
  } do
    for index <- 1..103 do
      mutate("create_worker", %{
        "id" => "retained-#{index}",
        "name" => "Retained #{index}",
        "expected_capabilities" => ["dns"]
      })
    end

    source = Domain.list_audit()
    assert length(source) == 100

    outside =
      Enum.find(Repo.all(Audit), &(&1.id not in Enum.map(source, fn event -> event["id"] end)))

    before_read = footprint()
    {:ok, view, _html} = live(conn, "/management/events")
    assert_source(view)
    assert length(:sys.get_state(view.pid).socket.assigns.worker_events) == 100
    render_click(view, "show", %{"id" => outside.id})
    refute has_element?(view, "#event-details")
    view |> element("#management-events-refresh") |> render_click()
    assert_source(view)
    assert footprint() == before_read
  end

  defp assert_source(view) do
    source = Domain.list_audit()
    assert :sys.get_state(view.pid).socket.assigns.events == source

    for {event, position} <- Enum.with_index(source, 1) do
      row = "#management-events tbody > tr:nth-child(#{position})"
      assert has_element?(view, "#{row} > td:nth-child(1)", event["inserted_at"])
      assert has_element?(view, "#{row} > td:nth-child(2)", event["actor"])
      assert has_element?(view, "#{row} > td:nth-child(3)", event["operation"])

      assert has_element?(
               view,
               "#{row} > td:nth-child(4) button[phx-click='show'][phx-value-id='#{event["id"]}']"
             )

      outcome =
        case event["result"]["error"] do
          %{"code" => code, "message" => message} when is_binary(code) and is_binary(message) ->
            "rejected"

          _ ->
            "committed"
        end

      outcome_row = "#management-command-outcomes tbody > tr:nth-child(#{position})"

      assert has_element?(
               view,
               "#{outcome_row}[data-event-id='#{event["id"]}'][data-outcome='#{outcome}'][data-operation='#{event["operation"]}']"
             )

      assert has_element?(view, "#{outcome_row} > td:nth-child(1)", event["operation"])
      assert has_element?(view, "#{outcome_row} > td:nth-child(2)", outcome)
      assert has_element?(view, "#{outcome_row} > td:nth-child(4)", event["inserted_at"])
    end

    refute has_element?(
             view,
             "#management-command-outcomes tbody > tr:nth-child(#{length(source) + 1})"
           )
  end

  defp assert_details(view, event) do
    text =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#event-details")
      |> LazyHTML.text()

    assert text == Jason.encode!(event, pretty: true)
    assert Jason.decode!(text) == event
  end

  defp assert_target(view, event, target) do
    assert has_element?(
             view,
             "#management-command-outcomes [data-event-id='#{event["id"]}'] > td:nth-child(3)",
             target
           )
  end

  defp seed do
    worker =
      mutate("create_worker", %{
        "id" => "events-worker",
        "name" => "Worker",
        "expected_capabilities" => ["dns"]
      })

    mutate("create_worker", %{
      "id" => "events-other",
      "name" => "Other",
      "expected_capabilities" => ["dns"]
    })

    mutate("put_service", %{
      "worker_id" => worker["id"],
      "expected_revision" => worker["revision"],
      "instance_id" => "dns",
      "type" => "dns",
      "desired_state" => "stopped",
      "config" => %{"listen_address" => "127.0.0.1", "port" => 5300}
    })

    netman = mutate("create_netman", %{"id" => "events-netman", "name" => "Netman"})
    assert {:ok, draft} = Domain.get_netman_config(netman["id"])

    mutate("confirm_netman_config", %{
      "id" => netman["id"],
      "expected_revision" => draft["revision"]
    })

    zone =
      mutate("create_zone", %{
        "name" => "events.test.",
        "records" => [
          %{
            "name" => "events.test.",
            "type" => "SOA",
            "ttl" => 300,
            "data" => %{
              "mname" => "ns.events.test.",
              "rname" => "hostmaster.events.test.",
              "serial" => 1,
              "refresh" => 3600,
              "retry" => 600,
              "expire" => 86400,
              "minimum" => 300
            }
          },
          %{
            "name" => "events.test.",
            "type" => "NS",
            "ttl" => 300,
            "data" => %{"host" => "ns.events.test."}
          },
          %{
            "name" => "ns.events.test.",
            "type" => "A",
            "ttl" => 300,
            "data" => %{"address" => "192.0.2.53"}
          }
        ]
      })

    mutate("confirm_zone", %{"id" => zone["id"], "expected_revision" => zone["revision"]})
    backup = mutate("create_backup", %{"label" => "Events transaction"})
    assert {:ok, task} = Domain.get_task("ip_city")

    assert {:error, _error} =
             Domain.mutate(
               "update_task",
               %{
                 "key" => "ip_city",
                 "expected_revision" => task["revision"],
                 "enabled" => false,
                 "cron" => "invalid cron"
               },
               "operator",
               Ecto.UUID.generate()
             )

    actor = "<script>alert('actor')</script> & operator"

    assert {:error, %{code: "conflict"}} =
             Domain.mutate(
               "create_worker",
               %{"id" => worker["id"], "name" => "Duplicate", "expected_capabilities" => ["dns"]},
               actor,
               Ecto.UUID.generate()
             )

    %{zone: zone, backup: backup}
  end

  defp mutate(operation, params) do
    assert {:ok, result} = Domain.mutate(operation, params, "operator", Ecto.UUID.generate())
    result
  end

  defp footprint do
    {Domain.list_workers(), Domain.list_netmans(), Domain.list_zones(),
     Repo.all(Audit) |> Enum.sort_by(& &1.id), Repo.all(Idempotency) |> Enum.sort_by(& &1.key),
     Repo.all(Oban.Job, prefix: "management_jobs") |> Enum.sort_by(& &1.id)}
  end
end
