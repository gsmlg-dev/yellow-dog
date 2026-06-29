defmodule YellowDog.Tasks.RegionData.StoreTest do
  use ExUnit.Case, async: true

  alias YellowDog.Tasks.RegionData.Store

  @moduletag :tmp_dir

  test "syncs country data from the default provider", %{tmp_dir: tmp_dir} do
    assert {:ok, info} = Store.sync(data_dir: tmp_dir)
    assert info.source == "geo-ip-countries"
    assert info.record_count > 0
    assert File.exists?(Path.join([tmp_dir, "region", "regions.json"]))
    assert File.exists?(Path.join([tmp_dir, "region", "metadata.json"]))

    countries = Store.list_countries(data_dir: tmp_dir)
    assert Enum.any?(countries, &(&1["code"] == "US"))
  end

  test "lists countries, regions, and lookup results from persisted data", %{tmp_dir: tmp_dir} do
    assert {:ok, _info} = Store.sync(data_dir: tmp_dir)

    assert {:ok, %{"code" => "US", "name" => "United States", "regions" => []}} =
             Store.lookup("US", nil, data_dir: tmp_dir)

    assert Store.lookup("XX", nil, data_dir: tmp_dir) == :error
    assert Store.lookup("US", "CA", data_dir: tmp_dir) == :error
    assert Store.list_regions("US", data_dir: tmp_dir) == []
  end

  test "preserves existing region data when provider fails", %{tmp_dir: tmp_dir} do
    assert {:ok, _info} = Store.sync(data_dir: tmp_dir)
    before_failure = File.read!(Path.join([tmp_dir, "region", "regions.json"]))

    assert {:error, :unavailable} =
             Store.sync(data_dir: tmp_dir, provider: YellowDog.Tasks.RegionData.FailingProvider)

    assert File.read!(Path.join([tmp_dir, "region", "regions.json"])) == before_failure
  end

  test "uses YellowDog config data dir when no data_dir option is provided", %{tmp_dir: tmp_dir} do
    previous_data_dir = Application.get_env(:yellow_dog, :data_dir)
    Application.put_env(:yellow_dog, :data_dir, tmp_dir)

    try do
      assert {:ok, _info} = Store.sync()
      assert File.exists?(Path.join([tmp_dir, "region", "regions.json"]))
    after
      if previous_data_dir do
        Application.put_env(:yellow_dog, :data_dir, previous_data_dir)
      else
        Application.delete_env(:yellow_dog, :data_dir)
      end
    end
  end
end

defmodule YellowDog.Tasks.RegionData.FailingProvider do
  @behaviour YellowDog.Tasks.RegionData.Provider

  @impl true
  def list_countries, do: {:error, :unavailable}
end
