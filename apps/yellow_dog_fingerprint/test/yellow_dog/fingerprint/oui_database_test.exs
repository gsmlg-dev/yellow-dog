defmodule YellowDog.Fingerprint.OuiDatabaseTest do
  use ExUnit.Case, async: false

  alias YellowDog.Fingerprint.OuiDatabase

  @moduletag :tmp_dir

  test "downloads with a provided fetcher and reloads the lookup table", %{tmp_dir: tmp_dir} do
    fetcher = fn _url -> %{ok: true, body: "00:00:0A\tTEST\tTest Vendor\n"} end

    start_supervised!({OuiDatabase, data_dir: tmp_dir})

    assert {:ok, path} = OuiDatabase.download(fetcher: fetcher)
    assert File.exists?(path)
    assert {:ok, "TEST", "Test Vendor"} = OuiDatabase.lookup("00:00:0A:00:00:01")
  end

  test "preserves the loaded database when downloaded data is invalid", %{tmp_dir: tmp_dir} do
    manuf_path = Path.join(tmp_dir, "manuf.txt")
    File.write!(manuf_path, "00:00:0A\tOLD\tOld Vendor\n")

    fetcher = fn _url -> %{ok: true, body: "not a manuf database\n"} end

    start_supervised!({OuiDatabase, data_dir: tmp_dir})

    assert {:ok, "OLD", "Old Vendor"} = OuiDatabase.lookup("00:00:0A:00:00:01")
    assert {:error, :empty_database} = OuiDatabase.download(fetcher: fetcher)
    assert File.read!(manuf_path) == "00:00:0A\tOLD\tOld Vendor\n"
    assert {:ok, "OLD", "Old Vendor"} = OuiDatabase.lookup("00:00:0A:00:00:01")
  end
end
