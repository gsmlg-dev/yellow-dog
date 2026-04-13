defmodule YellowDog.DnsProvider.Provider.VultrTest do
  use ExUnit.Case, async: true

  alias YellowDog.DnsProvider.Provider.Vultr

  describe "init/1" do
    test "succeeds with api_key" do
      assert {:ok, state} = Vultr.init(%{api_key: "vultr-key-123", req: Req.new()})
      assert %{req: _} = state
    end

    test "fails without api_key" do
      assert {:error, :missing_api_key} = Vultr.init(%{})
    end

    test "fails with non-binary api_key" do
      assert {:error, :missing_api_key} = Vultr.init(%{api_key: 123})
    end
  end

  describe "parse_domains/1" do
    test "parses domain list with trailing dots" do
      domains = [
        %{"domain" => "example.com"},
        %{"domain" => "other.org"}
      ]

      assert [
               %{name: "example.com.", id: "example.com"},
               %{name: "other.org.", id: "other.org"}
             ] = Vultr.parse_domains(domains)
    end

    test "handles empty list" do
      assert [] = Vultr.parse_domains([])
    end
  end

  describe "parse_records/2" do
    test "parses records with subdomain name" do
      records = [
        %{"id" => "r1", "type" => "A", "name" => "www", "data" => "1.2.3.4", "ttl" => 300}
      ]

      assert [%{owner: "www.example.com.", type: "A", ttl: 300, rdata: "1.2.3.4"}] =
               Vultr.parse_records(records, "example.com.")
    end

    test "maps empty name to zone apex" do
      records = [
        %{"id" => "r2", "type" => "A", "name" => "", "data" => "10.0.0.1", "ttl" => 600}
      ]

      assert [%{owner: "example.com.", rdata: "10.0.0.1"}] =
               Vultr.parse_records(records, "example.com.")
    end

    test "handles missing ttl" do
      records = [%{"id" => "r3", "type" => "TXT", "name" => "", "data" => "v=spf1 ..."}]

      assert [%{ttl: 0}] = Vultr.parse_records(records, "example.com.")
    end
  end

  describe "vultr_name_to_owner/2" do
    test "empty string maps to zone apex" do
      assert "example.com." = Vultr.vultr_name_to_owner("", "example.com.")
    end

    test "subdomain is prepended to zone" do
      assert "www.example.com." = Vultr.vultr_name_to_owner("www", "example.com.")
    end

    test "handles zone without trailing dot" do
      assert "mail.example.com." = Vultr.vultr_name_to_owner("mail", "example.com")
    end
  end

  describe "owner_to_vultr_name/2" do
    test "zone apex maps to empty string" do
      assert "" = Vultr.owner_to_vultr_name("example.com.", "example.com.")
    end

    test "subdomain owner strips zone suffix" do
      assert "www" = Vultr.owner_to_vultr_name("www.example.com.", "example.com.")
    end

    test "@ maps to empty string" do
      assert "" = Vultr.owner_to_vultr_name("@", "example.com.")
    end

    test "handles zone without trailing dot" do
      assert "mail" = Vultr.owner_to_vultr_name("mail.example.com.", "example.com")
    end

    test "handles owner without trailing dot" do
      assert "sub" = Vultr.owner_to_vultr_name("sub.example.com", "example.com.")
    end
  end
end
