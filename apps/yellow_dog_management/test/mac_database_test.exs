defmodule YellowDog.Management.MacDatabaseTest do
  use ExUnit.Case, async: true

  alias YellowDog.Management.MacDatabase

  @artifact """
  # Synthetic Wireshark manuf fixture
  02:11:22	Fixture24	Fixture 24-bit Vendor
  02:22:33:40:00:00/28	Fixture28	Fixture 28-bit Vendor
  02:22:33:50:00:00/28	Other28	Other 28-bit Vendor
  02:33:44:55:60:00/36	Fixture36	Fixture 36-bit Vendor
  """

  setup do
    directory =
      Path.join(System.tmp_dir!(), "management-mac-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory, path: Path.join(directory, "manuf.txt")}
  end

  test "default is the actual compiled GSMLG table and reload requires a configured artifact" do
    server = start_database()
    info = MacDatabase.info(server)
    assert info.source == :compiled
    assert info.status == :loaded
    assert info.entry_count == GSMLG.MAC.Vendor.entries()
    assert info.entry_count > 0
    assert %DateTime{} = info.loaded_at
    assert info.path == nil && !info.configured
    assert info.file_info == nil && info.last_error == nil

    assert MacDatabase.lookup("00:00:0A:BB:28:FC", server) ==
             GSMLG.MAC.Vendor.lookup("00:00:0A:BB:28:FC")

    assert {:error, :unconfigured} = MacDatabase.reload(server)
  end

  test "compiled 24, 28 and 36-bit entries retain library lookup semantics" do
    server = start_database()
    records = packaged_records()

    for width <- [24, 28, 36] do
      prefix =
        Enum.find_value(records, fn
          {prefix, _vendor} when bit_size(prefix) == width -> prefix
          _record -> nil
        end)

      assert is_bitstring(prefix)
      address = <<prefix::bits, 0::size(48 - bit_size(prefix))>> |> Base.encode16()
      assert {:ok, _short, _full} = expected = GSMLG.MAC.Vendor.lookup(address)
      assert MacDatabase.lookup(address, server) == expected
    end
  end

  test "unavailable service is distinct from a genuine missing vendor" do
    server = start_database()
    stop_supervised!(MacDatabase)
    assert {:error, :unavailable} = MacDatabase.lookup("00:00:0A:BB:28:FC", server)

    assert {:error, :unavailable} =
             MacDatabase.lookup("00:00:0A:BB:28:FC", :nonexistent_management_mac_database_test)

    assert {:error, :invalid_mac} = MacDatabase.lookup("bad mac", server)
  end

  test "packaged GSMLG manuf artifact reload preserves source parity" do
    path = Application.app_dir(:gsmlg_mac, "priv/manuf.txt")

    records = packaged_records() |> Enum.uniq_by(&elem(&1, 0))
    expected_count = length(records)
    assert expected_count == GSMLG.MAC.Vendor.entries()
    assert expected_count == GSMLG.MAC.Compiler.count_entries(GSMLG.MAC.Vendor.mac_lookup_table())

    server = start_database(path: path)
    # Allow the packaged source the loader's 30-second budget plus observation time.
    info = wait_loaded(server, 3_100)
    assert info.status == :loaded
    assert info.source == :file
    assert info.entry_count == expected_count
    assert :ok = MacDatabase.reload(server)

    for {prefix, _vendor} <- records do
      address = <<prefix::bits, 0::size(48 - bit_size(prefix))>> |> Base.encode16()
      assert {:ok, _short, _full} = expected = GSMLG.MAC.Vendor.lookup(address)
      assert MacDatabase.lookup(address, server) == expected
    end
  end

  test "configured real manuf artifact supports 24, 28 and 36-bit records", %{path: path} do
    File.write!(path, @artifact)
    server = start_database(path: path)
    info = wait_loaded(server)

    assert %{
             source: :file,
             status: :loaded,
             entry_count: 4,
             path: ^path,
             configured: true,
             last_error: nil
           } = info

    assert %{size: size, mtime: modified} = info.file_info
    assert size == byte_size(@artifact)
    assert is_integer(modified)

    assert {:ok, "Fixture24", "Fixture 24-bit Vendor"} =
             MacDatabase.lookup("02:11:22:FF:EE:DD", server)

    assert {:ok, "Fixture28", "Fixture 28-bit Vendor"} =
             MacDatabase.lookup("02:22:33:4F:AA:BB", server)

    assert {:ok, "Other28", "Other 28-bit Vendor"} =
             MacDatabase.lookup("02:22:33:50:AA:BB", server)

    assert {:ok, "Fixture36", "Fixture 36-bit Vendor"} =
             MacDatabase.lookup("02:33:44:55:6F:AB", server)

    assert :error = MacDatabase.lookup("02:22:33:6F:AA:BB", server)
    assert :error = MacDatabase.lookup("02:33:44:55:7F:AB", server)
  end

  test "reload changes the shared runtime lookup and metadata", %{path: path} do
    File.write!(path, @artifact)
    server = start_database(path: path)
    original = wait_loaded(server)
    replacement = "02:11:22\tChanged\tChanged Runtime Vendor\n"
    File.write!(path, replacement)
    assert :ok = MacDatabase.reload(server)

    assert {:ok, "Changed", "Changed Runtime Vendor"} =
             MacDatabase.lookup("02:11:22:01:02:03", server)

    assert :error = MacDatabase.lookup("02:22:33:40:00:00", server)

    assert %{source: :file, status: :loaded, entry_count: 1, last_error: nil} =
             info = MacDatabase.info(server)

    assert info.file_info.size == byte_size(replacement)
    assert DateTime.compare(info.loaded_at, original.loaded_at) != :lt
  end

  test "standard MAC separators and case are supported but malformed inputs are rejected", %{
    path: path
  } do
    File.write!(path, @artifact)
    server = start_database(path: path)
    wait_loaded(server)

    for address <- [
          "02:11:22:aa:bb:cc",
          "02-11-22-AA-BB-CC",
          "0211.22AA.BBCC",
          "021122AABBCC",
          " 02:11:22:AA:BB:CC "
        ] do
      assert {:ok, "Fixture24", "Fixture 24-bit Vendor"} = MacDatabase.lookup(address, server)
    end

    for address <- [
          nil,
          42,
          <<255>>,
          "",
          "02:11:22",
          "02:11:22:AA:BB:CC/24",
          "02:11:22:GG:BB:CC",
          "xx021122aabbcc",
          "02:11-22:aa:bb:cc",
          String.duplicate("0", 65)
        ] do
      assert {:error, :invalid_mac} = MacDatabase.lookup(address, server)
    end

    assert Process.alive?(server)
  end

  test "missing configured file preserves compiled baseline and recovers when created", %{
    path: path
  } do
    server = start_database(path: path)
    info = wait_loaded(server)

    assert %{
             source: :compiled,
             status: :error,
             configured: true,
             last_error: :enoent,
             file_info: nil
           } = info

    assert info.entry_count == GSMLG.MAC.Vendor.entries()
    assert {:ok, _short, _full} = MacDatabase.lookup("00:00:0A:BB:28:FC", server)
    File.write!(path, @artifact)
    assert :ok = MacDatabase.reload(server)
    assert %{source: :file, status: :loaded, last_error: nil} = MacDatabase.info(server)
  end

  test "malformed UTF8, records and masked prefixes preserve the last valid snapshot", %{
    path: path
  } do
    File.write!(path, @artifact)
    server = start_database(path: path)
    original = wait_loaded(server)

    for contents <- [
          <<255>>,
          "garbage\n",
          "02:11:22\t\n",
          "02:11:22/28\tBad\tToo few bits\n",
          "02:11:22:33:44:55/49\tBad\tToo many bits\n",
          "02:11:22/8\tBad\tToo short\n",
          "02:11:22:33:44:55/nope\tBad\tBad mask\n",
          "# comments only\n",
          "",
          @artifact <> "bad line\n"
        ] do
      File.write!(path, contents)
      assert {:error, _reason} = MacDatabase.reload(server)
      assert_snapshot(server, original)
    end

    File.rm!(path)
    assert {:error, :enoent} = MacDatabase.reload(server)
    assert_snapshot(server, original)
  end

  test "overlapping prefix widths retain longest-prefix lookup and broader fallbacks", %{
    path: path
  } do
    File.write!(path, @artifact)
    server = start_database(path: path)
    wait_loaded(server)

    records = [
      "02:11:22\tBroad24\tBroad 24-bit Vendor\n",
      "02:11:22:30:00:00/28\tBroad28\tBroad 28-bit Vendor\n",
      "02:11:22:33:40:00/36\tPrecise36\tPrecise 36-bit Vendor\n"
    ]

    for contents <- [Enum.join(records), records |> Enum.reverse() |> Enum.join()] do
      File.write!(path, contents)
      assert :ok = MacDatabase.reload(server)

      assert %{source: :file, status: :loaded, entry_count: 3, last_error: nil} =
               MacDatabase.info(server)

      assert {:ok, "Precise36", "Precise 36-bit Vendor"} =
               MacDatabase.lookup("02:11:22:33:4F:AA", server)

      assert {:ok, "Broad28", "Broad 28-bit Vendor"} =
               MacDatabase.lookup("02:11:22:3F:AA:BB", server)

      assert {:ok, "Broad24", "Broad 24-bit Vendor"} =
               MacDatabase.lookup("02:11:22:4F:AA:BB", server)

      assert :error = MacDatabase.lookup("02:11:23:33:4F:AA", server)
    end
  end

  test "nonregular and oversized files are rejected without crashing", %{
    directory: directory,
    path: path
  } do
    server = start_database(path: directory)

    assert %{source: :compiled, status: :error, last_error: :not_regular_file} =
             wait_loaded(server)

    stop_supervised!(MacDatabase)

    File.open!(path, [:write, :binary], fn file ->
      {:ok, _position} = :file.position(file, 64 * 1024 * 1024)
      :ok = :file.write(file, <<0>>)
    end)

    server = start_database(path: path)
    assert %{source: :compiled, status: :error, last_error: :too_large} = wait_loaded(server)
    assert {:error, :too_large} = MacDatabase.reload(server)
    assert Process.alive?(server)
  end

  test "blank configuration and unsolicited messages cannot change the snapshot" do
    server = start_database(path: "")
    original = MacDatabase.info(server)
    send(server, {:load_result, make_ref(), {:error, :forged}})
    send(server, {:load_timeout, make_ref()})
    assert {:error, :invalid_request} = GenServer.call(server, {:reload, "/etc/passwd"})
    assert MacDatabase.info(server) == original
  end

  defp start_database(opts \\ []),
    do: start_supervised!({MacDatabase, Keyword.put(opts, :name, nil)})

  defp packaged_records do
    :gsmlg_mac
    |> Application.app_dir("priv/manuf.txt")
    |> File.read!()
    |> GSMLG.MAC.Parser.parse_file()
  end

  defp wait_loaded(server, attempts \\ 200)
  defp wait_loaded(_server, 0), do: raise("MAC artifact did not finish loading")

  defp wait_loaded(server, attempts) do
    case MacDatabase.info(server) do
      %{status: :loading} ->
        Process.sleep(10)
        wait_loaded(server, attempts - 1)

      info ->
        info
    end
  end

  defp assert_snapshot(server, original) do
    info = MacDatabase.info(server)
    assert info.status == :error
    assert info.source == original.source
    assert info.entry_count == original.entry_count
    assert info.loaded_at == original.loaded_at
    assert info.file_info == original.file_info

    assert {:ok, "Fixture24", "Fixture 24-bit Vendor"} =
             MacDatabase.lookup("02:11:22:AA:BB:CC", server)

    assert Process.alive?(server)
  end
end
