defmodule YellowDog.Management.ConfigLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias YellowDog.Management.{Domain, Repo}

  @endpoint YellowDog.ManagementUI.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    %{conn: build_conn()}
  end

  test "empty version history remains a real read-only page without login", %{conn: conn} do
    assert Domain.list_target_history() == []
    {:ok, view, html} = live(conn, "/management/config")
    assert has_element?(view, "#management-config-empty", "No configuration versions")
    assert has_element?(view, "#management-config-versions")
    assert html =~ "not delivered or applied"
    refute has_element?(view, "[data-netman-id], a[href^='/netman']")
    refute has_element?(view, "input[type='password']")
    assert has_element?(view, "a[href='/management/config']", "Config")
  end

  test "the table lists every immutable target version with genuine digests and unknown state", %{
    conn: conn
  } do
    create_worker("history-one", "<script>Worker One</script>")
    first = confirm("history-one", 1)
    second = confirm("history-one", 2)
    create_worker("history-two", "Worker Two")
    third = confirm("history-two", 1)
    targets = Domain.list_target_history()
    assert length(targets) == 3
    assert Enum.all?(targets, &(&1["status"] == "prepared" && &1["actual_state"] == "unknown"))
    assert Enum.all?(targets, &(not Map.has_key?(&1, "plan")))
    assert Enum.map(targets, & &1["id"]) == [third["id"], second["id"], first["id"]]

    {:ok, view, html} = live(conn, "/management/config")

    for target <- [first, second, third] do
      assert has_element?(view, "#config-version-#{target["id"]}", target["digest"])
      assert has_element?(view, "#config-version-#{target["id"]}[data-actual-state='unknown']")
    end

    assert html =~ "&lt;script&gt;Worker One&lt;/script&gt;"
    refute html =~ "<script>Worker One</script>"

    assert has_element?(
             view,
             "#management-config-versions a[href='/server/history-one/dashboard']"
           )
  end

  test "refresh discovers new confirmations without changing historical targets or audits", %{
    conn: conn
  } do
    create_worker("refresh-history", "Refresh Worker")
    original = confirm("refresh-history", 1)
    {:ok, view, _html} = live(conn, "/management/config")
    later = confirm("refresh-history", 2)
    before_read = Domain.list_audit()
    refute has_element?(view, "#config-version-#{later["id"]}")
    view |> element("#management-config-refresh") |> render_click()
    assert has_element?(view, "#config-version-#{later["id"]}", later["digest"])
    assert {:ok, original} == Domain.get_target("refresh-history", 1)
    assert Domain.list_audit() == before_read
  end

  defp create_worker(id, name) do
    mutate("create_worker", %{"id" => id, "name" => name, "expected_capabilities" => ["dns"]})
  end

  defp confirm(id, revision) do
    mutate("confirm_target", %{"worker_id" => id, "expected_revision" => revision})
    |> Map.delete("worker_revision")
  end

  defp mutate(operation, params) do
    {:ok, result} = Domain.mutate(operation, params, "operator", Ecto.UUID.generate())
    result
  end
end
