defmodule GeoIpDb.CountriesTest do
  use ExUnit.Case, async: true

  alias GeoIpDb.Countries

  describe "list/0" do
    test "returns all 249 countries" do
      countries = Countries.list()
      assert length(countries) == 249
    end

    test "each country has code and name keys" do
      for country <- Countries.list() do
        assert Map.has_key?(country, :code)
        assert Map.has_key?(country, :name)
        assert is_binary(country.code)
        assert is_binary(country.name)
      end
    end

    test "codes are 2-letter uppercase strings" do
      for %{code: code} <- Countries.list() do
        assert String.length(code) == 2
        assert code == String.upcase(code)
      end
    end

    test "list is sorted by code" do
      codes = Enum.map(Countries.list(), & &1.code)
      assert codes == Enum.sort(codes)
    end

    test "first country is Andorra (AD)" do
      assert hd(Countries.list()) == %{code: "AD", name: "Andorra"}
    end

    test "last country is Zimbabwe (ZW)" do
      assert List.last(Countries.list()) == %{code: "ZW", name: "Zimbabwe"}
    end
  end

  describe "codes/0" do
    test "returns 249 codes" do
      assert length(Countries.codes()) == 249
    end

    test "all codes are strings" do
      for code <- Countries.codes() do
        assert is_binary(code)
      end
    end

    test "includes well-known codes" do
      codes = Countries.codes()
      assert "US" in codes
      assert "GB" in codes
      assert "CN" in codes
      assert "JP" in codes
      assert "DE" in codes
      assert "FR" in codes
      assert "AU" in codes
      assert "BR" in codes
    end

    test "no duplicates" do
      codes = Countries.codes()
      assert length(codes) == length(Enum.uniq(codes))
    end
  end

  describe "get/1" do
    test "returns country for valid code" do
      assert {:ok, %{code: "US", name: "United States"}} = Countries.get("US")
    end

    test "returns error for invalid code" do
      assert {:error, :not_found} = Countries.get("XX")
    end

    test "is case-sensitive (lowercase fails)" do
      assert {:error, :not_found} = Countries.get("us")
    end

    test "returns error for empty string" do
      assert {:error, :not_found} = Countries.get("")
    end

    test "returns error for 3-letter code" do
      assert {:error, :not_found} = Countries.get("USA")
    end

    test "returns correct name for various countries" do
      assert {:ok, %{name: "Japan"}} = Countries.get("JP")
      assert {:ok, %{name: "Germany"}} = Countries.get("DE")
      assert {:ok, %{name: "Brazil"}} = Countries.get("BR")
      assert {:ok, %{name: "Australia"}} = Countries.get("AU")
    end

    test "handles countries with special characters in name" do
      assert {:ok, %{name: "Côte d'Ivoire"}} = Countries.get("CI")
      assert {:ok, %{name: "Curaçao"}} = Countries.get("CW")
      assert {:ok, %{name: "Réunion"}} = Countries.get("RE")
      assert {:ok, %{name: "São Tomé and Príncipe"}} = Countries.get("ST")
      assert {:ok, %{name: "Åland Islands"}} = Countries.get("AX")
    end
  end

  describe "name/1" do
    test "returns name for valid code" do
      assert {:ok, "United States"} = Countries.name("US")
    end

    test "returns error for invalid code" do
      assert {:error, :not_found} = Countries.name("XX")
    end

    test "returns correct name for UK" do
      assert {:ok, "United Kingdom"} = Countries.name("GB")
    end

    test "returns correct name for China" do
      assert {:ok, "China"} = Countries.name("CN")
    end
  end

  describe "valid?/1" do
    test "returns true for valid codes" do
      assert Countries.valid?("US")
      assert Countries.valid?("GB")
      assert Countries.valid?("CN")
      assert Countries.valid?("JP")
    end

    test "returns false for invalid codes" do
      refute Countries.valid?("XX")
      refute Countries.valid?("ZZ")
      refute Countries.valid?("")
    end

    test "is case-sensitive" do
      refute Countries.valid?("us")
      refute Countries.valid?("Us")
    end

    test "returns false for 3-letter codes" do
      refute Countries.valid?("USA")
      refute Countries.valid?("GBR")
    end
  end

  describe "search/1" do
    test "finds countries by partial name (case-insensitive)" do
      results = Countries.search("united")
      codes = Enum.map(results, & &1.code)
      assert "AE" in codes
      assert "GB" in codes
      assert "US" in codes
    end

    test "search is case-insensitive" do
      assert Countries.search("JAPAN") == Countries.search("japan")
      assert Countries.search("Japan") == Countries.search("japan")
    end

    test "returns empty list for no matches" do
      assert Countries.search("zzzzzzz") == []
    end

    test "finds single character match" do
      results = Countries.search("z")
      # Zimbabwe, Zambia, Azerbaijan, Mozambique, etc.
      assert length(results) > 0
      codes = Enum.map(results, & &1.code)
      assert "ZW" in codes
    end

    test "finds countries with special characters using exact accent" do
      results = Countries.search("tomé")
      assert length(results) >= 1
      assert Enum.any?(results, fn c -> c.code == "ST" end)
    end

    test "search without accent does not match accented names" do
      # "tome" doesn't match "Tomé" — search is byte-level, not Unicode-normalized
      results = Countries.search("tome")
      refute Enum.any?(results, fn c -> c.code == "ST" end)
    end

    test "empty query returns all countries" do
      assert length(Countries.search("")) == 249
    end

    test "finds 'new' countries" do
      results = Countries.search("new")
      codes = Enum.map(results, & &1.code)
      assert "NZ" in codes
      assert "NC" in codes
    end

    test "search results maintain alphabetical order by code" do
      results = Countries.search("land")
      codes = Enum.map(results, & &1.code)
      assert codes == Enum.sort(codes)
    end
  end
end
