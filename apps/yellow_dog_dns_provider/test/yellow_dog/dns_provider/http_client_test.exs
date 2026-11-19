defmodule YellowDog.DnsProvider.HTTPClientTest do
  use ExUnit.Case, async: true

  alias YellowDog.DnsProvider.{HTTPClient, HTTPServer}
  alias YellowDog.DnsProvider.Provider.{Aws, Cloudflare, Gcp, IanaRoot, Vultr}

  test "Cloudflare paginates with encoded queries and preserves bearer authentication" do
    owner = self()

    server =
      start_supervised!(
        {HTTPServer,
         fn request ->
           send(owner, request)
           page = URI.decode_query(request.url.query)["page"]

           record = %{
             "name" => "example.com",
             "type" => "A",
             "ttl" => 60,
             "content" => "192.0.2.#{page}"
           }

           %{body: %{"result" => [record], "result_info" => %{"total_pages" => 2}}}
         end}
      )

    {:ok, state} =
      Cloudflare.init(%{api_token: "token", base_url: HTTPServer.base_url(server, "/client/v4")})

    assert {:ok, records, ^state} = Cloudflare.get_records(%{id: "zone-id"}, state)
    assert Enum.map(records, & &1.rdata) == ["192.0.2.1", "192.0.2.2"]

    for page <- ["1", "2"] do
      assert_receive %{method: :get, url: url, headers: headers}
      assert url.path == "/client/v4/zones/zone-id/dns_records"
      assert URI.decode_query(url.query) == %{"page" => page, "per_page" => "100"}
      assert headers["authorization"] == "Bearer token"
    end
  end

  test "Cloudflare deletion filters encode the bare owner and record type" do
    owner = self()

    server =
      start_supervised!(
        {HTTPServer,
         fn request ->
           send(owner, request)
           %{body: %{"result" => []}}
         end}
      )

    {:ok, state} = Cloudflare.init(%{api_token: "token", base_url: HTTPServer.base_url(server)})
    record = %{owner: "a b.example.com.", type: "TXT", ttl: 60, rdata: "text"}

    assert {:ok, ^state} =
             Cloudflare.apply_changeset(
               %{id: "zone"},
               %{deletions: [record], additions: []},
               state
             )

    assert_receive %{url: url}
    assert URI.decode_query(url.query) == %{"name" => "a b.example.com", "type" => "TXT"}
  end

  test "GCP and Vultr send JSON changes with bearer authentication" do
    owner = self()

    server =
      start_supervised!(
        {HTTPServer,
         fn request ->
           send(owner, request)
           %{status: 201, body: %{}}
         end}
      )

    record = %{owner: "www.example.com.", type: "A", ttl: 60, rdata: "192.0.2.1"}
    changes = %{additions: [record], deletions: []}

    {:ok, gcp} =
      Gcp.init(%{
        project_id: "project",
        access_token: "gcp-token",
        base_url: HTTPServer.base_url(server, "/dns/v1")
      })

    assert {:ok, ^gcp} = Gcp.apply_changeset(%{id: "zone"}, changes, gcp)

    assert_receive %{
      method: :post,
      url: %{path: "/dns/v1/projects/project/managedZones/zone/changes"},
      body: gcp_body,
      headers: gcp_headers
    }

    assert gcp_headers["authorization"] == "Bearer gcp-token"
    assert gcp_headers["content-type"] == "application/json"

    assert Jason.decode!(gcp_body) == %{
             "deletions" => [],
             "additions" => [
               %{"name" => record.owner, "type" => "A", "ttl" => 60, "rrdatas" => [record.rdata]}
             ]
           }

    {:ok, vultr} =
      Vultr.init(%{api_key: "vultr-token", base_url: HTTPServer.base_url(server, "/v2")})

    assert {:ok, ^vultr} = Vultr.apply_changeset(%{name: "example.com."}, changes, vultr)

    assert_receive %{
      method: :post,
      url: %{path: "/v2/domains/example.com/records"},
      body: vultr_body,
      headers: vultr_headers
    }

    assert vultr_headers["authorization"] == "Bearer vultr-token"

    assert Jason.decode!(vultr_body) == %{
             "name" => "www",
             "type" => "A",
             "ttl" => 60,
             "data" => record.rdata
           }
  end

  test "AWS receives and sends raw XML with its existing date-only auth stub" do
    owner = self()

    server =
      start_supervised!(
        {HTTPServer,
         fn request ->
           send(owner, request)

           %{
             body:
               "<HostedZones><HostedZone><Id>/hostedzone/Z1</Id><Name>example.com.</Name></HostedZone></HostedZones>",
             headers: [{"content-type", "text/xml"}]
           }
         end}
      )

    {:ok, state} =
      Aws.init(%{
        access_key_id: "AK",
        secret_access_key: "SK",
        base_url: HTTPServer.base_url(server, "/2013-04-01")
      })

    assert {:ok, [%{name: "example.com.", id: "Z1"}], ^state} = Aws.list_zones(state)
    assert_receive %{method: :get, url: %{path: "/2013-04-01/hostedzone"}, headers: headers}
    assert headers["x-amz-date"] =~ ~r/^\d{8}T\d{6}Z$/
    assert headers["content-type"] == "text/xml"

    changes = %{
      additions: [%{owner: "example.com.", type: "A", ttl: 60, rdata: "192.0.2.1"}],
      deletions: []
    }

    assert {:ok, ^state} = Aws.apply_changeset(%{id: "Z1"}, changes, state)
    assert_receive %{method: :post, body: body}
    assert body == Aws.build_change_batch_xml(changes)
  end

  test "Vultr resolves and deletes the matching remote record and reads SOA serial" do
    owner = self()

    server =
      start_supervised!(
        {HTTPServer,
         fn request ->
           send(owner, request)

           case {request.method, request.url.path} do
             {:get, "/domains/example.com/records"} ->
               %{
                 body: %{
                   "records" => [
                     %{
                       "id" => "record-id",
                       "name" => "www",
                       "type" => "A",
                       "ttl" => 60,
                       "data" => "192.0.2.1"
                     }
                   ]
                 }
               }

             {:delete, "/domains/example.com/records/record-id"} ->
               %{status: 204}

             {:get, "/domains/example.com/soa"} ->
               %{body: %{"dns_soa" => %{"nserial" => 123}}}
           end
         end}
      )

    {:ok, state} = Vultr.init(%{api_key: "key", base_url: HTTPServer.base_url(server)})
    record = %{owner: "www.example.com.", type: "A", ttl: 60, rdata: "192.0.2.1"}

    assert {:ok, ^state} =
             Vultr.apply_changeset(
               %{name: "example.com."},
               %{deletions: [record], additions: []},
               state
             )

    assert_receive %{method: :delete, url: %{path: "/domains/example.com/records/record-id"}}
    assert {:ok, 123, ^state} = Vultr.zone_serial(%{name: "example.com."}, state)
  end

  test "GCP reads managed zones and rrsets over HTTP" do
    server =
      start_supervised!(
        {HTTPServer,
         fn request ->
           case request.url.path do
             "/projects/project/managedZones" ->
               %{body: %{"managedZones" => [%{"name" => "zone", "dnsName" => "example.com."}]}}

             "/projects/project/managedZones/zone/rrsets" ->
               %{
                 body: %{
                   "rrsets" => [
                     %{
                       "name" => "www.example.com.",
                       "type" => "A",
                       "ttl" => 60,
                       "rrdatas" => ["192.0.2.1"]
                     }
                   ]
                 }
               }
           end
         end}
      )

    {:ok, state} = Gcp.init(%{project_id: "project", base_url: HTTPServer.base_url(server)})
    assert {:ok, [%{name: "example.com.", id: "zone"}], ^state} = Gcp.list_zones(state)

    assert {:ok, [%{owner: "www.example.com.", type: "A", ttl: 60, rdata: "192.0.2.1"}], ^state} =
             Gcp.get_records(%{id: "zone"}, state)
  end

  test "IANA parses plain text root zone and serial over HTTP" do
    zone = ". 86400 IN SOA a.root. admin.root. 2026010101 1 2 3 4\n. 86400 IN NS a.root.\n"
    server = start_supervised!({HTTPServer, fn _ -> %{body: zone} end})
    {:ok, state} = IanaRoot.init(%{url: HTTPServer.base_url(server, "/root.zone")})

    assert {:ok, [%{owner: ".", type: "NS", rdata: "a.root."}], updated} =
             IanaRoot.get_records(%{name: "."}, state)

    assert updated.cached_records != nil
    assert {:ok, 2_026_010_101, ^state} = IanaRoot.zone_serial(%{name: "."}, state)
  end

  test "JSON decoding follows content type and malformed JSON returns an error" do
    server =
      start_supervised!(
        {HTTPServer,
         fn request ->
           case request.url.path do
             "/plain" ->
               %{body: "{raw text}"}

             "/json" ->
               %{
                 body: "{",
                 headers: [{"content-type", "application/problem+json; charset=utf-8"}]
               }

             "/failure/zones" ->
               %{status: 403, body: %{"error" => "denied"}}
           end
         end}
      )

    client = HTTPClient.new(HTTPServer.base_url(server))
    assert {:ok, %{body: "{raw text}"}} = HTTPClient.request(client, :get, "/plain")

    assert {:error, {:invalid_json, %Jason.DecodeError{}}} =
             HTTPClient.request(client, :get, "/json")

    assert {:ok, state} =
             Cloudflare.init(%{
               api_token: "token",
               base_url: HTTPServer.base_url(server, "/failure")
             })

    assert {:error, {:api_error, 403, %{"error" => "denied"}}, ^state} =
             Cloudflare.list_zones(state)
  end

  test "transport failure returns an error and requests have a finite timeout" do
    server =
      start_supervised!(
        {HTTPServer,
         fn _ ->
           Process.sleep(100)
           %{body: "late"}
         end}
      )

    client = HTTPClient.new(HTTPServer.base_url(server), [], 10)
    assert {:error, _reason} = HTTPClient.request(client, :get, "/slow")
    url = HTTPServer.base_url(server)
    stop_supervised!(HTTPServer)
    assert {:error, _reason} = HTTPClient.request(HTTPClient.new(url, [], 100), :get, "/closed")
  end

  test "streamed truncation and body timeout return errors instead of raising" do
    server =
      start_supervised!(
        {HTTPServer,
         fn request ->
           %{
             raw: fn socket ->
               :ok =
                 :gen_tcp.send(
                   socket,
                   "HTTP/1.1 200 OK\r\ncontent-length: 6000000\r\ncontent-type: text/plain\r\n\r\npartial"
                 )

               if request.url.path == "/timeout", do: Process.sleep(200)
             end
           }
         end}
      )

    client = HTTPClient.new(HTTPServer.base_url(server), [], 100)
    assert {:error, _reason} = HTTPClient.request(client, :get, "/truncated")
    assert {:error, _reason} = HTTPClient.request(client, :get, "/timeout")
  end

  test "API redirects fail before forwarding authenticated requests" do
    owner = self()

    server =
      start_supervised!(
        {HTTPServer,
         fn request ->
           send(owner, request.url.path)
           %{status: 302, headers: [{"location", "/forwarded"}], body: ""}
         end}
      )

    client = HTTPClient.new(HTTPServer.base_url(server), [{"authorization", "Bearer token"}])
    assert {:error, _reason} = HTTPClient.request(client, :post, "/original", json: %{})
    assert_receive "/original"
    refute_receive "/forwarded"
  end
end
