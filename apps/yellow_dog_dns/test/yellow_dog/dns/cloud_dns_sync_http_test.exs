defmodule YellowDog.Dns.CloudDnsSyncHTTPTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dns.CloudDnsSync

  defmodule Store do
    use Agent

    def start_link(opts), do: Agent.start_link(fn -> Map.new(opts) end, name: __MODULE__)
    def get_zone(_, _), do: Agent.get(__MODULE__, &{:ok, &1.zone})
    def get_config(_), do: Agent.get(__MODULE__, &{:ok, &1.provider})
    def records, do: Agent.get(__MODULE__, &Map.get(&1, :records))

    def replace_records(_, _, records) do
      Agent.update(__MODULE__, &Map.put(&1, :records, records))
      {:ok, %{previous: [], changed_count: length(records)}}
    end

    def reload_zone(_, :auth, _, []), do: :ok
  end

  test "Cloudflare lookup and pagination use JSON over the default HTTP transport" do
    configure_store(:cloudflare, "")

    {api, server} =
      start_http_server([
        fn request ->
          assert request.target == "/zones?name=gsmlg.dev&per_page=1"
          assert request.headers["authorization"] == "Bearer test-token"
          json(%{success: true, result: [%{id: "zone-id"}]})
        end,
        fn request ->
          assert request.target == "/zones/zone-id/dns_records?per_page=100&page=1"

          json(%{
            success: true,
            result: [%{type: "A", name: "www.gsmlg.dev", content: "192.0.2.10", ttl: 120}],
            result_info: %{total_pages: 2}
          })
        end,
        fn request ->
          assert request.target == "/zones/zone-id/dns_records?per_page=100&page=2"

          json(%{
            success: true,
            result: [%{type: "TXT", name: "gsmlg.dev", content: "cloud mirror", ttl: 1}],
            result_info: %{total_pages: 2}
          })
        end
      ])

    assert {:ok, %{provider: :cloudflare, records_synced: 2}} =
             sync("gsmlg.dev", cloudflare_api: api)

    assert %{owner: "www.gsmlg.dev", type: :a, rrset: [%{address: "192.0.2.10", ttl: 120}]} in Store.records()

    assert %{owner: "gsmlg.dev", type: :txt, rrset: [%{txtdata: "cloud mirror", ttl: 300}]} in Store.records()

    Task.await(server)
  end

  test "Route 53 XML pages retain signed canonical target bytes and the actual Host" do
    configure_store(:route53, "Z123")

    targets = [
      "/2013-04-01/hostedzone/Z123/rrset?maxitems=100",
      "/2013-04-01/hostedzone/Z123/rrset?identifier=weighted%20%2B%20blue&maxitems=100&name=%2A.gsmlg.net.&type=A"
    ]

    {api, server} =
      start_http_server(
        for {target, index} <- Enum.with_index(targets) do
          fn request ->
            assert request.target == target
            assert request.headers["x-amz-date"] == "20260624T000000Z"
            assert request.headers["authorization"] == signature(target, request.authority)
            assert request.headers["host"] == request.authority

            pagination =
              if index == 0 do
                """
                <IsTruncated>true</IsTruncated><NextRecordName>*.gsmlg.net.</NextRecordName>
                <NextRecordType>A</NextRecordType><NextRecordIdentifier>weighted + blue</NextRecordIdentifier>
                """
              else
                "<IsTruncated>false</IsTruncated>"
              end

            owner = if index == 0, do: "www.gsmlg.net.", else: "*.gsmlg.net."

            body = """
            <ListResourceRecordSetsResponse><ResourceRecordSets><ResourceRecordSet>
            <Name>#{owner}</Name><Type>A</Type><TTL>60</TTL><ResourceRecords>
            <ResourceRecord><Value>192.0.2.10</Value></ResourceRecord></ResourceRecords>
            </ResourceRecordSet></ResourceRecordSets>#{pagination}</ListResourceRecordSetsResponse>
            """

            {200, [{"content-type", "application/xml"}], body}
          end
        end
      )

    assert {:ok, %{provider: :route53, records_synced: 2}} =
             sync("gsmlg.net", route53_api: api, request_time: ~U[2026-06-24 00:00:00Z])

    assert Enum.sort(Enum.map(Store.records(), & &1.owner)) == ["*.gsmlg.net", "www.gsmlg.net"]
    Task.await(server)
  end

  test "Cloudflare JSON HTTP and API errors are returned before any replacement" do
    configure_store(:cloudflare, "zone-id")

    for {status, expected} <- [
          {429, {:cloudflare_http_error, 429, ["rate limited"]}},
          {200, {:cloudflare_api_error, ["rate limited"]}}
        ] do
      {api, server} =
        start_http_server([
          fn _request ->
            json(%{success: false, errors: [%{message: "rate limited"}]}, status)
          end
        ])

      assert {:error, ^expected} = sync("gsmlg.dev", cloudflare_api: api)
      assert Store.records() == nil
      Task.await(server)
    end
  end

  test "Route 53 XML HTTP errors are retained" do
    configure_store(:route53, "Z123")

    {api, server} =
      start_http_server([
        fn _request ->
          {403, [{"content-type", "application/xml"}],
           "<ErrorResponse><Error><Message>Denied</Message></Error></ErrorResponse>"}
        end
      ])

    assert {:error, {:route53_http_error, 403, ["Denied"]}} = sync("gsmlg.net", route53_api: api)
    assert Store.records() == nil
    Task.await(server)
  end

  test "malformed JSON is a request error and does not replace records" do
    configure_store(:cloudflare, "zone-id")

    {api, server} =
      start_http_server([fn _ -> {200, [{"content-type", "application/json"}], "{invalid"} end])

    assert {:error, {:cloudflare_request_failed, %Jason.DecodeError{}}} =
             sync("gsmlg.dev", cloudflare_api: api)

    assert Store.records() == nil
    Task.await(server)
  end

  test "request deadlines terminate a stalled transport" do
    configure_store(:cloudflare, "zone-id")

    {api, server} =
      start_http_server([
        fn _ ->
          receive do
            :close -> :close
          end
        end
      ])

    assert {:error, {:cloudflare_request_failed, :timeout}} =
             sync("gsmlg.dev", cloudflare_api: api, timeout: 100)

    assert Store.records() == nil
    send(server.pid, :close)
    Task.await(server)
  end

  test "redirects are refused before credentials can be replayed" do
    configure_store(:cloudflare, "zone-id")

    {api, server} =
      start_http_server([
        fn _ -> {302, [{"location", "http://127.0.0.1:1/credentials"}], ""} end
      ])

    assert {:error, {:cloudflare_request_failed, :redirect}} =
             sync("gsmlg.dev", cloudflare_api: api)

    assert Store.records() == nil
    Task.await(server)
  end

  defp configure_store(provider, zone_id) do
    credentials =
      case provider do
        :cloudflare -> %{api_token: "test-token"}
        :route53 -> %{access_key_id: "AKIATEST", secret_access_key: "route53-secret"}
      end

    start_supervised!(
      {Store,
       zone: %{cloud_mirror: %{enabled: true, connector_name: "test", zone_id: zone_id}},
       provider: %{type: provider, credentials: credentials, enabled: true}}
    )
  end

  defp sync(zone, opts) do
    CloudDnsSync.sync_zone_from_cloud(
      "default",
      zone,
      Keyword.merge(
        [
          zone_store: Store,
          provider_store: Store,
          zone_controller: Store,
          cache_invalidator: fn _, _ -> :ok end
        ],
        opts
      )
    )
  end

  defp json(body, status \\ 200),
    do: {status, [{"content-type", "application/json"}], Jason.encode!(body)}

  defp start_http_server(handlers) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    authority = "127.0.0.1:#{port}"

    server =
      Task.async(fn ->
        Enum.each(handlers, fn handler ->
          {:ok, socket} = :gen_tcp.accept(listener, 2_000)
          request = receive_request(socket, "") |> Map.put(:authority, authority)
          assert request.method == "GET"

          case handler.(request) do
            {status, headers, body} ->
              headers = [{"content-length", byte_size(body)}, {"connection", "close"} | headers]
              head = Enum.map(headers, fn {name, value} -> "#{name}: #{value}\r\n" end)
              :ok = :gen_tcp.send(socket, ["HTTP/1.1 #{status} Response\r\n", head, "\r\n", body])

            :close ->
              :ok
          end

          :gen_tcp.close(socket)
        end)
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(server.pid), do: Process.exit(server.pid, :kill)
    end)

    {"http://#{authority}", server}
  end

  defp receive_request(socket, bytes) do
    if String.contains?(bytes, "\r\n\r\n") do
      [line | headers] = String.split(bytes, "\r\n", trim: true)
      [method, target, _version] = String.split(line, " ")

      headers =
        Map.new(headers, fn line ->
          [name, value] = String.split(line, ":", parts: 2)
          {String.downcase(name), String.trim(value)}
        end)

      %{method: method, target: target, headers: headers}
    else
      {:ok, chunk} = :gen_tcp.recv(socket, 0, 2_000)
      receive_request(socket, bytes <> chunk)
    end
  end

  defp signature(target, authority) do
    [path, query] = String.split(target, "?", parts: 2)
    payload = Base.encode16(:crypto.hash(:sha256, ""), case: :lower)
    names = "host;x-amz-content-sha256;x-amz-date"
    headers = "host:#{authority}\nx-amz-content-sha256:#{payload}\nx-amz-date:20260624T000000Z\n"
    canonical = Enum.join(["GET", path, query, headers, names, payload], "\n")
    digest = Base.encode16(:crypto.hash(:sha256, canonical), case: :lower)
    scope = "20260624/us-east-1/route53/aws4_request"
    to_sign = Enum.join(["AWS4-HMAC-SHA256", "20260624T000000Z", scope, digest], "\n")

    key =
      Enum.reduce(["20260624", "us-east-1", "route53", "aws4_request"], "AWS4route53-secret", fn
        input, key -> :crypto.mac(:hmac, :sha256, key, input)
      end)

    signature = Base.encode16(:crypto.mac(:hmac, :sha256, key, to_sign), case: :lower)

    "AWS4-HMAC-SHA256 Credential=AKIATEST/#{scope}, SignedHeaders=#{names}, Signature=#{signature}"
  end
end
