defmodule YellowDog.Management.CloudDns.Route53Test do
  use ExUnit.Case, async: true

  alias YellowDog.Management.CloudDns.Route53

  @credentials %{
    "access_key_id" => "AKIDEXAMPLE",
    "secret_access_key" => "SecretFixture",
    "session_token" => "token/+="
  }
  @path "https://route53.amazonaws.com/2013-04-01/hostedzone/Z123"
  @list "https://route53.amazonaws.com/2013-04-01/hostedzonesbyname?dnsname=example.test.&maxitems=100"
  @create "https://route53.amazonaws.com/2013-04-01/hostedzone"
  @zone """
  <GetHostedZoneResponse>
    <HostedZone><Id>/hostedzone/Z123</Id><Name>Example.Test.</Name></HostedZone>
  </GetHostedZoneResponse>
  """

  test "lists hosted zones across pages and preserves the provider IDs" do
    request = fn
      "GET", @create, _headers, "" ->
        {:ok, 200,
         """
         <ListHostedZonesResponse>
           <HostedZones><HostedZone><Name>Example.Test.</Name><Id>/hostedzone/Z123</Id>
             <CallerReference>first</CallerReference></HostedZone></HostedZones>
           <IsTruncated>true</IsTruncated><NextMarker>next&amp;2</NextMarker>
         </ListHostedZonesResponse>
         """}

      "GET", @create <> "?marker=next%262", _headers, "" ->
        {:ok, 200,
         """
         <ListHostedZonesResponse>
           <HostedZones><HostedZone><Name>Example.Test.</Name><Id>/hostedzone/Z456</Id>
             <CallerReference>second</CallerReference></HostedZone></HostedZones>
           <IsTruncated>false</IsTruncated>
         </ListHostedZonesResponse>
         """}
    end

    assert {:ok, [%{id: "Z123", name: "example.test."}, %{id: "Z456", name: "example.test."}]} =
             Route53.list_zones(@credentials, request)
  end

  test "signs canonical requests in the Route 53 signing region with the session token" do
    assert {:ok, headers} =
             Route53.signed_headers(
               @credentials,
               "GET",
               "/2013-04-01/hostedzone/Z123/rrset",
               "identifier=blue%20green&name=www.example.test.&type=A",
               "",
               ~U[2026-11-22 12:34:56Z]
             )

    assert {"x-amz-security-token", "token/+="} in headers

    assert {"authorization",
            "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20261122/us-east-1/route53/aws4_request, " <>
              "SignedHeaders=host;x-amz-content-sha256;x-amz-date;x-amz-security-token, " <>
              "Signature=c4258369dfe85bee1e83e7b6eefa0c9ee1753bfe9bf59ebdf5a90aebcc2b8043"} in headers
  end

  test "fetches all pages with encoded continuation and protects alias and routed sets" do
    request = fn "GET", url, headers, "" ->
      assert {"host", "route53.amazonaws.com"} in headers
      assert {"x-amz-security-token", "token/+="} in headers

      case url do
        @path ->
          {:ok, 200, @zone}

        @path <> "/rrset" ->
          {:ok, 200,
           """
           <ListResourceRecordSetsResponse>
             <ResourceRecordSets>
               <ResourceRecordSet><Name>example.test.</Name><Type>SOA</Type><TTL>900</TTL>
                 <ResourceRecords><ResourceRecord><Value>ns.example.test. host.example.test. 1 2 3 4 5</Value></ResourceRecord></ResourceRecords>
               </ResourceRecordSet>
               <ResourceRecordSet><Name>example.test.</Name><Type>NS</Type><TTL>300</TTL>
                 <ResourceRecords><ResourceRecord><Value>ns.example.test.</Value></ResourceRecord></ResourceRecords>
               </ResourceRecordSet>
               <ResourceRecordSet><Name>www.example.test.</Name><Type>A</Type>
                 <AliasTarget><HostedZoneId>ZALIAS</HostedZoneId><DNSName>cloud.example.test.</DNSName></AliasTarget>
               </ResourceRecordSet>
               <ResourceRecordSet><Name>api.example.test.</Name><Type>A</Type>
                 <SetIdentifier>first</SetIdentifier><Weight>25</Weight><TTL>300</TTL>
                 <ResourceRecords><ResourceRecord><Value>192.0.2.4</Value></ResourceRecord></ResourceRecords>
               </ResourceRecordSet>
             </ResourceRecordSets>
             <IsTruncated>true</IsTruncated>
             <NextRecordName>api.example.test.</NextRecordName><NextRecordType>A</NextRecordType>
             <NextRecordIdentifier>blue &amp; green</NextRecordIdentifier>
           </ListResourceRecordSetsResponse>
           """}

        @path <> "/rrset?identifier=blue%20%26%20green&name=api.example.test.&type=A" ->
          {:ok, 200,
           """
           <ListResourceRecordSetsResponse>
             <ResourceRecordSets>
               <ResourceRecordSet><Name>api.example.test.</Name><Type>A</Type>
                 <SetIdentifier>blue &amp; green</SetIdentifier><Weight>75</Weight><TTL>300</TTL>
                 <ResourceRecords><ResourceRecord><Value>192.0.2.5</Value></ResourceRecord></ResourceRecords>
               </ResourceRecordSet>
               <ResourceRecordSet><Name>TXT.Example.Test.</Name><Type>TXT</Type><TTL>60</TTL>
                 <ResourceRecords><ResourceRecord><Value>&quot;hello &#38; &lt;world&#x3e;&quot;</Value></ResourceRecord></ResourceRecords>
               </ResourceRecordSet>
             </ResourceRecordSets>
             <IsTruncated>false</IsTruncated>
           </ListResourceRecordSetsResponse>
           """}
      end
    end

    assert {:ok, %{name: "example.test.", rrsets: records}} =
             Route53.fetch("/hostedzone/Z123", @credentials, request)

    assert %{protected: true, values: ["ns.example.test."]} = records[{"example.test.", "NS"}]
    assert %{protected: true} = records[{"example.test.", "SOA"}]
    assert %{protected: true, values: []} = records[{"www.example.test.", "A"}]

    assert %{protected: true, values: ["192.0.2.4", "192.0.2.5"], provider_details: [_, _]} =
             records[{"api.example.test.", "A"}]

    assert %{protected: false, ttl: 60, values: ["\"hello & <world>\""]} =
             records[{"txt.example.test.", "TXT"}]
  end

  test "replaces and deletes exact old sets within one atomic batch" do
    request = fn
      "GET", @path, _, "" ->
        {:ok, 200, @zone}

      "POST", @path <> "/rrset", headers, body ->
        assert {"x-amz-content-sha256", Base.encode16(:crypto.hash(:sha256, body), case: :lower)} in headers

        assert Regex.scan(~r/<Action>([^<]+)<\/Action>/, body, capture: :all_but_first) ==
                 [["DELETE"], ["DELETE"], ["CREATE"], ["CREATE"]]

        assert body =~ "<Value>&quot;old &amp; value&quot;</Value>"
        assert body =~ "<Value>&quot;new &lt; value&quot;</Value>"
        assert body =~ "<Value>192.0.2.6</Value>"

        {:ok, 200,
         "<ChangeResourceRecordSetsResponse><ChangeInfo><Id>/change/C123</Id><Status>PENDING</Status></ChangeInfo></ChangeResourceRecordSetsResponse>"}
    end

    changes = [
      change({"text.example.test.", "TXT"}, set("\"old & value\""), set("\"new < value\"")),
      change({"gone.example.test.", "A"}, set("192.0.2.5"), nil),
      change({"new.example.test.", "A"}, nil, set("192.0.2.6"))
    ]

    assert :ok = Route53.apply("Z123", @credentials, changes, request)
  end

  test "fails closed for protected mutations, malformed pages, and ambiguous writes" do
    route = fn "GET", @path, _, "" -> {:ok, 200, @zone} end

    assert {:error, :invalid_route53_change_batch} =
             Route53.apply(
               "Z123",
               @credentials,
               [change({"example.test.", "NS"}, nil, set("ns.other.test."))],
               route
             )

    assert {:error, :invalid_route53_change_batch} =
             Route53.apply(
               "Z123",
               @credentials,
               [change({"www.example.test.", "A"}, %{set("192.0.2.4") | protected: true}, nil)],
               route
             )

    malformed = fn
      "GET", @path, _, "" -> {:ok, 200, @zone}
      "GET", @path <> "/rrset", _, "" -> {:ok, 200, "<IsTruncated>false</IsTruncated>"}
    end

    assert {:error, :invalid_route53_response} = Route53.fetch("Z123", @credentials, malformed)

    ambiguous = fn
      "GET", @path, _, "" -> {:ok, 200, @zone}
      "POST", @path <> "/rrset", _, _body -> {:error, :timeout}
    end

    assert {:error, :route53_write_unconfirmed} =
             Route53.apply(
               "Z123",
               @credentials,
               [change({"www.example.test.", "A"}, nil, set("192.0.2.4"))],
               ambiguous
             )

    unexpected_success = fn
      "GET", @path, _, "" -> {:ok, 200, @zone}
      "POST", @path <> "/rrset", _, _body -> {:ok, 200, "<UnexpectedResponse/>"}
    end

    assert {:error, :route53_write_unconfirmed} =
             Route53.apply(
               "Z123",
               @credentials,
               [change({"www.example.test.", "A"}, nil, set("192.0.2.4"))],
               unexpected_success
             )
  end

  test "creates an absent zone once and reuses it for the same caller reference" do
    request = fn
      "GET", @list, _, "" ->
        hosted_zones(Process.get(:created_route53_zone, ""))

      "POST", @create, _, body ->
        assert Process.get(:created_route53_zone) == nil
        assert body =~ "<Name>example.test.</Name>"

        [_, reference] =
          Regex.run(~r/<CallerReference>(yellow-dog-[0-9a-f]{64})<\/CallerReference>/, body)

        zone = hosted_zone("Z123", "example.test.", reference)
        Process.put(:created_route53_zone, zone)
        {:ok, 201, "<CreateHostedZoneResponse>#{zone}</CreateHostedZoneResponse>"}
    end

    assert {:ok, "Z123"} = Route53.create_zone("EXAMPLE.Test", @credentials, "request-1", request)

    assert {:ok, "Z123"} =
             Route53.create_zone("example.test.", @credentials, "request-1", request)

    assert {:error, :remote_zone_exists} =
             Route53.create_zone("example.test.", @credentials, "request-2", request)
  end

  test "recovers an accepted create after the response is lost" do
    request = fn
      "GET", @list, _, "" ->
        hosted_zones(Process.get(:created_route53_zone, ""))

      "POST", @create, _, body ->
        [_, reference] = Regex.run(~r/<CallerReference>([^<]+)<\/CallerReference>/, body)
        Process.put(:created_route53_zone, hosted_zone("Z123", "example.test.", reference))
        {:error, :timeout}
    end

    assert {:ok, "Z123"} =
             Route53.create_zone("example.test.", @credentials, "request-1", request)
  end

  test "scans exact name continuations before writing and rejects an existing zone" do
    request = fn
      "GET", @list, _, "" ->
        {:ok, 200,
         """
         <ListHostedZonesByNameResponse>
           <HostedZones/>
           <IsTruncated>true</IsTruncated>
           <NextDNSName>example.test.</NextDNSName><NextHostedZoneId>Z123</NextHostedZoneId>
         </ListHostedZonesByNameResponse>
         """}

      "GET",
      "https://route53.amazonaws.com/2013-04-01/hostedzonesbyname?dnsname=example.test.&hostedzoneid=Z123&maxitems=100",
      _,
      "" ->
        hosted_zones(hosted_zone("Z123", "example.test.", "another-request"))
    end

    assert {:error, :remote_zone_exists} =
             Route53.create_zone("example.test.", @credentials, "request-1", request)
  end

  defp change(key, before, next), do: %{key: key, before: before, after: next}
  defp set(value), do: %{ttl: 300, values: [value], protected: false}

  defp hosted_zone(id, name, reference) do
    "<HostedZone><Id>/hostedzone/#{id}</Id><Name>#{name}</Name><CallerReference>#{reference}</CallerReference></HostedZone>"
  end

  defp hosted_zones(entries) do
    {:ok, 200,
     "<ListHostedZonesByNameResponse><HostedZones>#{entries}</HostedZones><IsTruncated>false</IsTruncated></ListHostedZonesByNameResponse>"}
  end
end
