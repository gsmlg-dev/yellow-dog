defmodule YellowDog.Store.RpzTest do
  use ExUnit.Case

  alias YellowDog.Store.Rpz

  @moduletag :store_integration

  @tag :skip
  test "put and get a rule" do
    zone = "blocklist"
    trigger = "bad.example.com"
    rule = %{action: :nxdomain, reason: "malware", created_by: "admin", enabled: true}

    assert :ok = Rpz.put(zone, trigger, rule)
    {:ok, result} = Rpz.get(zone, trigger)

    assert result.action == :nxdomain
    assert result.reason == "malware"
  end

  @tag :skip
  test "list returns all rules in a zone" do
    Rpz.put("testzone", "evil1.com", %{
      action: :nxdomain,
      reason: "test1",
      created_by: "admin",
      enabled: true
    })

    Rpz.put("testzone", "evil2.com", %{
      action: :redirect,
      reason: "test2",
      created_by: "admin",
      enabled: true
    })

    {:ok, entries} = Rpz.list("testzone")
    assert length(entries) >= 2
  end

  @tag :skip
  test "delete removes a rule" do
    Rpz.put("delzone", "target.com", %{
      action: :nodata,
      reason: "temp",
      created_by: "admin",
      enabled: true
    })

    assert :ok = Rpz.delete("delzone", "target.com")
    assert {:error, :not_found} = Rpz.get("delzone", "target.com")
  end

  @tag :skip
  test "zones returns unique zone names" do
    Rpz.put("zone_a", "a.com", %{
      action: :nxdomain,
      reason: "r",
      created_by: "admin",
      enabled: true
    })

    Rpz.put("zone_b", "b.com", %{
      action: :nxdomain,
      reason: "r",
      created_by: "admin",
      enabled: true
    })

    {:ok, zone_names} = Rpz.zones()
    assert "zone_a" in zone_names
    assert "zone_b" in zone_names
    assert zone_names == Enum.uniq(zone_names)
  end

  @tag :skip
  test "get returns :not_found for unknown trigger" do
    assert {:error, :not_found} = Rpz.get("nonexistent", "unknown.com")
  end
end
