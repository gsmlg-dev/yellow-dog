defmodule YellowDog.Management.CloudDnsCloudflareTest do
  use ExUnit.Case, async: true

  alias YellowDog.Management.CloudDns.Cloudflare

  @zone_id String.duplicate("a", 32)
  @token "fixture-token"
  @credentials %{"api_token" => @token}
  @path "/zones/#{@zone_id}"
  @record_id String.duplicate("b", 32)
  @record_id_two String.duplicate("c", 32)
  @account_id String.duplicate("d", 32)
  @account_credentials Map.put(@credentials, "account_id", @account_id)

  test "lists zones across pages without requiring an account ID" do
    request = fn
      :get, "/zones?page=1&per_page=25", @token, nil ->
        page([Map.put(zone(), "account", %{"id" => @account_id})], 1, 2)

      :get, "/zones?page=2&per_page=25", @token, nil ->
        page(
          [%{"id" => @record_id, "name" => "Other.NET", "account" => %{"id" => @account_id}}],
          2,
          2
        )
    end

    assert {:ok, [%{id: @zone_id, name: "example.net."}, %{id: @record_id, name: "other.net."}]} =
             Cloudflare.list_zones(@credentials, request)
  end

  test "reads and normalizes a paginated zone while retaining protected records" do
    get = fn
      :get, @path, @token, nil ->
        ok(zone())

      :get,
      @path <> "/dns_records?page=1&per_page=100&include_shadow_metadata=true",
      @token,
      nil ->
        page(
          [
            record("WWW.Example.NET", "A", "192.0.2.1", %{"id" => @record_id}),
            record("Example.NET", "MX", "Mail.Example.NET", %{"priority" => 10}),
            record("Example.NET", "NS", "NS1.Example.NET")
          ],
          1,
          2
        )

      :get,
      @path <> "/dns_records?page=2&per_page=100&include_shadow_metadata=true",
      @token,
      nil ->
        page(
          [
            record("www.example.net", "A", "192.0.2.2", %{"id" => @record_id_two}),
            record("proxy.example.net", "CNAME", "WWW.example.net", %{"proxied" => true}),
            record("manual.example.net", "A", "192.0.2.3", %{"comment" => "manual"}),
            record("mixed.example.net", "A", "192.0.2.4", %{"ttl" => 60}),
            record("mixed.example.net", "A", "192.0.2.5", %{"ttl" => 120}),
            record("txt.example.net", "TXT", "v=verification"),
            record("_sip._tcp.example.net", "SRV", "1 2 5060 sip.example.net", %{"data" => %{}})
          ],
          2,
          2
        )
    end

    assert {:ok, %{name: "example.net.", name_servers: ["ns1.example.net."], rrsets: records}} =
             Cloudflare.fetch(@zone_id, @credentials, get)

    assert %{
             ttl: 1,
             values: ["192.0.2.1", "192.0.2.2"],
             protected: false,
             records: [%{id: @record_id}, %{id: @record_id_two}]
           } = records[{"www.example.net.", "A"}]

    assert %{values: ["10 mail.example.net."], protected: false} =
             records[{"example.net.", "MX"}]

    assert %{values: [~s("v=verification")], protected: false} =
             records[{"txt.example.net.", "TXT"}]

    for key <- [
          {"example.net.", "NS"},
          {"proxy.example.net.", "CNAME"},
          {"manual.example.net.", "A"},
          {"mixed.example.net.", "A"},
          {"_sip._tcp.example.net.", "SRV"}
        ] do
      assert records[key].protected
    end
  end

  test "sends one batch and retains unchanged record IDs when changing a record set" do
    changes = [
      %{
        key: {"existing.example.net.", "A"},
        before: %{
          ttl: 60,
          values: ["192.0.2.1", "192.0.2.2"],
          protected: false,
          records: [
            %{id: @record_id, ttl: 60, value: "192.0.2.1"},
            %{id: @record_id_two, ttl: 60, value: "192.0.2.2"}
          ]
        },
        after: %{ttl: 60, values: ["192.0.2.1", "192.0.2.3"]}
      },
      %{
        key: {"example.net.", "MX"},
        before: nil,
        after: %{ttl: 120, values: ["5 mail.example.net."]}
      },
      %{
        key: {"new.example.net.", "AAAA"},
        before: nil,
        after: %{ttl: 120, values: ["2001:0db8::1"]}
      },
      %{
        key: {"old.example.net.", "CNAME"},
        before: %{
          ttl: 60,
          values: ["existing.example.net."],
          protected: false,
          records: [%{id: String.duplicate("d", 32), ttl: 60, value: "existing.example.net."}]
        },
        after: nil
      }
    ]

    request = fn
      :get, @path, @token, nil ->
        ok(zone())

      :post, @path <> "/dns_records/batch", @token, body ->
        assert body.deletes == [%{id: String.duplicate("d", 32)}]

        assert body.patches == [
                 %{
                   id: @record_id_two,
                   name: "existing.example.net",
                   type: "A",
                   content: "192.0.2.3",
                   ttl: 60
                 }
               ]

        assert body.posts == [
                 %{
                   name: "example.net",
                   type: "MX",
                   ttl: 120,
                   priority: 5,
                   content: "mail.example.net"
                 },
                 %{
                   name: "new.example.net",
                   type: "AAAA",
                   ttl: 120,
                   proxied: false,
                   content: "2001:db8::1"
                 }
               ]

        ok(%{"deletes" => [], "patches" => [], "posts" => []})
    end

    assert :ok = Cloudflare.apply(@zone_id, @credentials, changes, request)
  end

  test "rejects protected records, duplicate changes, and apex nameserver writes" do
    request = fn :get, @path, @token, nil -> ok(zone()) end

    apex = %{
      key: {"example.net.", "NS"},
      before: nil,
      after: %{ttl: 60, values: ["ns2.example.net."]}
    }

    assert {:error, :cloudflare_protected_record} =
             Cloudflare.apply(@zone_id, @credentials, [apex], request)

    protected = %{
      key: {"proxy.example.net.", "A"},
      before: %{ttl: 1, values: ["192.0.2.1"], protected: true},
      after: nil
    }

    assert {:error, :cloudflare_protected_record} =
             Cloudflare.apply(@zone_id, @credentials, [protected], request)

    ordinary = %{
      key: {"www.example.net.", "A"},
      before: nil,
      after: %{ttl: 60, values: ["192.0.2.1"]}
    }

    assert {:error, :cloudflare_invalid_changes} =
             Cloudflare.apply(@zone_id, @credentials, [ordinary, ordinary], request)
  end

  test "maps API errors to safe reasons and rejects invalid identifiers before a request" do
    request = fn :get, @path, @token, nil ->
      {:ok, 403, %{"success" => false, "errors" => [%{"message" => @token}]}}
    end

    assert {:error, :cloudflare_auth_failed} = Cloudflare.fetch(@zone_id, @credentials, request)

    assert {:error, :cloudflare_invalid_configuration} =
             Cloudflare.fetch("../zones", @credentials, request)

    assert {:error, :cloudflare_invalid_configuration} =
             Cloudflare.fetch(@zone_id, %{"api_token" => "\r\n"}, request)
  end

  test "fails closed when a later page is inconsistent" do
    request = fn
      :get, @path, @token, nil ->
        ok(zone())

      :get,
      @path <> "/dns_records?page=1&per_page=100&include_shadow_metadata=true",
      @token,
      nil ->
        page([record("www.example.net", "A", "192.0.2.1")], 1, 2)

      :get,
      @path <> "/dns_records?page=2&per_page=100&include_shadow_metadata=true",
      @token,
      nil ->
        page([], 1, 2)
    end

    assert {:error, :cloudflare_invalid_response} =
             Cloudflare.fetch(@zone_id, @credentials, request)
  end

  test "checks the exact name in the selected account before creating a full zone" do
    request = fn
      :get, "/zones?" <> query, @token, nil ->
        assert URI.decode_query(query) == %{
                 "account.id" => @account_id,
                 "name" => "example.net",
                 "match" => "all",
                 "type" => "full,partial,secondary,internal",
                 "page" => "1",
                 "per_page" => "25"
               }

        page([], 1, 0)

      :post, "/zones", @token, body ->
        assert body == %{account: %{id: @account_id}, name: "example.net", type: "full"}
        ok(account_zone())
    end

    assert {:ok, @zone_id} =
             Cloudflare.create_zone("Example.NET.", @account_credentials, "intent-1", request)
  end

  test "does not POST when an exact zone already exists on a later page" do
    request = fn :get, "/zones?" <> query, @token, nil ->
      case URI.decode_query(query)["page"] do
        "1" ->
          page([%{account_zone() | "account" => %{"id" => String.duplicate("e", 32)}}], 1, 2)

        "2" ->
          page([account_zone()], 2, 2)
      end
    end

    assert {:error, :remote_zone_exists} =
             Cloudflare.create_zone("example.net", @account_credentials, "intent-1", request)
  end

  test "requires an account ID and never retries an uncertain creation" do
    request = fn
      :get, "/zones?" <> _, @token, nil ->
        page([], 1, 0)

      :post, "/zones", @token, _body ->
        send(self(), :posted)
        {:error, :timeout}
    end

    assert {:error, :cloudflare_invalid_configuration} =
             Cloudflare.create_zone("example.net.", @credentials, "intent-1", request)

    refute_received :posted

    assert {:error, :cloudflare_transport_failed} =
             Cloudflare.create_zone("example.net.", @account_credentials, "intent-1", request)

    assert_received :posted
    refute_received :posted
  end

  defp account_zone, do: Map.put(zone(), "account", %{"id" => @account_id})

  defp zone,
    do: %{"id" => @zone_id, "name" => "Example.NET", "name_servers" => ["NS1.Example.NET"]}

  defp ok(result), do: {:ok, 200, %{"success" => true, "result" => result}}

  defp page(result, page, pages) do
    {:ok, 200,
     %{
       "success" => true,
       "result" => result,
       "result_info" => %{"page" => page, "total_pages" => pages}
     }}
  end

  defp record(name, type, content, fields \\ %{}) do
    Map.merge(
      %{
        "id" => :crypto.hash(:md5, name <> type <> content) |> Base.encode16(case: :lower),
        "name" => name,
        "type" => type,
        "content" => content,
        "ttl" => 1
      },
      fields
    )
  end
end
