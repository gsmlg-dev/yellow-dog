defmodule YellowDog.DnsProvider.Provider.CloudflareTest do
  use ExUnit.Case, async: true

  alias YellowDog.DnsProvider.Provider.Cloudflare

  describe "init/1" do
    test "succeeds with api_token" do
      assert {:ok, %{req: %Req.Request{}}} = Cloudflare.init(%{api_token: "cf-tok-123"})
    end

    test "fails without api_token" do
      assert {:error, :missing_api_token} = Cloudflare.init(%{})
    end

    test "fails with nil api_token" do
      assert {:error, :missing_api_token} = Cloudflare.init(%{api_token: nil})
    end

    test "accepts injected :req for testing" do
      req = Req.new(base_url: "http://test")
      assert {:ok, %{req: ^req}} = Cloudflare.init(%{api_token: "tok", req: req})
    end
  end

  describe "parse_dns_records/1" do
    test "parses A record" do
      records = [
        %{"name" => "example.com", "type" => "A", "ttl" => 300, "content" => "1.2.3.4"}
      ]

      assert [%{owner: "example.com.", type: "A", ttl: 300, rdata: "1.2.3.4"}] =
               Cloudflare.parse_dns_records(records)
    end

    test "parses AAAA record" do
      records = [
        %{
          "name" => "example.com.",
          "type" => "AAAA",
          "ttl" => 600,
          "content" => "2001:db8::1"
        }
      ]

      assert [%{owner: "example.com.", type: "AAAA", ttl: 600, rdata: "2001:db8::1"}] =
               Cloudflare.parse_dns_records(records)
    end

    test "parses MX record with priority" do
      records = [
        %{
          "name" => "example.com",
          "type" => "MX",
          "ttl" => 3600,
          "content" => "mail.example.com",
          "priority" => 10
        }
      ]

      assert [%{owner: "example.com.", type: "MX", rdata: "10 mail.example.com"}] =
               Cloudflare.parse_dns_records(records)
    end

    test "parses CNAME record with trailing dot" do
      records = [
        %{
          "name" => "www.example.com",
          "type" => "CNAME",
          "ttl" => 300,
          "content" => "example.com"
        }
      ]

      assert [%{owner: "www.example.com.", type: "CNAME", rdata: "example.com"}] =
               Cloudflare.parse_dns_records(records)
    end

    test "parses multiple records" do
      records = [
        %{"name" => "a.example.com", "type" => "A", "ttl" => 60, "content" => "1.1.1.1"},
        %{"name" => "b.example.com", "type" => "A", "ttl" => 60, "content" => "2.2.2.2"}
      ]

      result = Cloudflare.parse_dns_records(records)
      assert length(result) == 2
      assert Enum.at(result, 0).owner == "a.example.com."
      assert Enum.at(result, 1).owner == "b.example.com."
    end
  end

  describe "build_create_body/1" do
    test "builds body for A record" do
      body =
        Cloudflare.build_create_body(%{
          type: "A",
          owner: "example.com.",
          ttl: 300,
          rdata: "1.2.3.4"
        })

      assert body["type"] == "A"
      assert body["name"] == "example.com"
      assert body["ttl"] == 300
      assert body["content"] == "1.2.3.4"
    end

    test "builds body for MX record with priority" do
      body =
        Cloudflare.build_create_body(%{
          type: "MX",
          owner: "example.com.",
          ttl: 3600,
          rdata: "10 mail.example.com"
        })

      assert body["type"] == "MX"
      assert body["content"] == "mail.example.com"
      assert body["priority"] == 10
    end

    test "strips trailing dot from owner" do
      body =
        Cloudflare.build_create_body(%{
          type: "CNAME",
          owner: "www.example.com.",
          ttl: 300,
          rdata: "example.com"
        })

      assert body["name"] == "www.example.com"
    end
  end

  describe "parse_soa_serial/1" do
    test "extracts serial from SOA content" do
      content = "ns1.example.com admin.example.com 2024010100 3600 900 1209600 86400"
      assert 2_024_010_100 = Cloudflare.parse_soa_serial(content)
    end

    test "returns 0 for malformed content" do
      assert 0 = Cloudflare.parse_soa_serial("only two")
    end
  end
end
