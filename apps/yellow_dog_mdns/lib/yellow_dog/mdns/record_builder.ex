defmodule YellowDog.Mdns.RecordBuilder do
  @moduledoc """
  Builds DNS resource records for mDNS services.

  Constructs PTR, SRV, TXT, A, and AAAA records according to RFC 6763
  (DNS-Based Service Discovery) and RFC 6762 (mDNS).
  """

  alias DNS.Message.{Record, Question}

  @type service :: YellowDog.Mdns.ServiceRegistry.service()

  # RFC 6762 §10: TTL values for mDNS
  @default_service_ttl 4500
  # 75 minutes for PTR, SRV, TXT
  @default_host_ttl 120
  # 2 minutes for A/AAAA

  @doc """
  Builds all DNS records for a service.

  Returns a map containing different record types that can be used
  in various sections of DNS responses.

  ## Parameters
  - `service` - Service definition from registry

  ## Returns
  Map with keys:
  - `:ptr` - PTR record for service type enumeration
  - `:srv` - SRV record with host and port
  - `:txt` - TXT record with service metadata
  - `:a` - List of A records (IPv4 addresses)
  - `:aaaa` - List of AAAA records (IPv6 addresses)
  """
  @spec build_all_records(service()) :: map()
  def build_all_records(service) do
    %{
      ptr: build_ptr_record(service),
      srv: build_srv_record(service),
      txt: build_txt_record(service),
      a: build_a_records(service),
      aaaa: build_aaaa_records(service)
    }
  end

  @doc """
  Builds a PTR record for service type enumeration.

  PTR records map from service type to service instance name.
  Format: _service._proto.domain -> instance._service._proto.domain

  ## Example
      # Query: _http._tcp.local
      # Answer: _http._tcp.local PTR My-Web-Server._http._tcp.local
  """
  @spec build_ptr_record(service()) :: Record.t()
  def build_ptr_record(service) do
    # PTR record name is the service type
    name = "#{service.type}.#{service.domain}"
    # PTR record data points to the service instance
    data = service.fqdn

    %Record{
      name: name,
      type: :PTR,
      class: :IN,
      ttl: service.ttl || @default_service_ttl,
      data: data
    }
  end

  @doc """
  Builds an SRV record with host and port information.

  SRV records provide the hostname and port for a service instance.
  Format: priority weight port target

  ## Example
      # My-Web-Server._http._tcp.local SRV 0 0 8080 myhost.local
  """
  @spec build_srv_record(service()) :: Record.t()
  def build_srv_record(service) do
    %Record{
      name: service.fqdn,
      type: :SRV,
      class: :IN,
      ttl: service.ttl || @default_service_ttl,
      data: %{
        priority: service.priority,
        weight: service.weight,
        port: service.port,
        target: service.host
      }
    }
  end

  @doc """
  Builds a TXT record with service metadata.

  TXT records contain key=value pairs with service information.
  Empty TXT record is included even if no metadata (RFC 6763 §6).

  ## Example
      # My-Web-Server._http._tcp.local TXT "path=/api" "version=1.0"
  """
  @spec build_txt_record(service()) :: Record.t()
  def build_txt_record(service) do
    txt_data =
      if map_size(service.txt_records) > 0 do
        # Convert map to list of "key=value" strings
        Enum.map(service.txt_records, fn {key, value} ->
          "#{key}=#{value}"
        end)
      else
        # Empty TXT record (RFC 6763 §6.1)
        [""]
      end

    %Record{
      name: service.fqdn,
      type: :TXT,
      class: :IN,
      ttl: service.ttl || @default_service_ttl,
      data: txt_data
    }
  end

  @doc """
  Builds A records for IPv4 addresses.

  Returns a list of A records, one for each IPv4 address.

  ## Example
      # myhost.local A 192.168.1.100
  """
  @spec build_a_records(service()) :: [Record.t()]
  def build_a_records(service) do
    for ip <- service.addresses, is_ipv4?(ip) do
      %Record{name: service.host, type: :A, class: :IN, ttl: @default_host_ttl, data: ip}
    end
  end

  @doc """
  Builds AAAA records for IPv6 addresses.

  Returns a list of AAAA records, one for each IPv6 address.

  ## Example
      # myhost.local AAAA fe80::1
  """
  @spec build_aaaa_records(service()) :: [Record.t()]
  def build_aaaa_records(service) do
    for ip <- service.addresses, is_ipv6?(ip) do
      %Record{name: service.host, type: :AAAA, class: :IN, ttl: @default_host_ttl, data: ip}
    end
  end

  @doc """
  Builds records matching a specific question.

  Returns appropriate records based on the question type and name.

  ## Parameters
  - `service` - Service definition
  - `question` - DNS question from query

  ## Returns
  Map with `:answers`, `:authority`, and `:additional` sections
  """
  @spec build_records_for_question(service(), Question.t()) :: map()
  def build_records_for_question(service, question) do
    qname = to_string(question.name) |> String.downcase() |> String.trim_trailing(".")
    qtype = question.type

    service_fqdn = String.downcase(service.fqdn) |> String.trim_trailing(".")

    service_type =
      String.downcase("#{service.type}.#{service.domain}") |> String.trim_trailing(".")

    service_host = String.downcase(service.host) |> String.trim_trailing(".")

    cond do
      # PTR query for service type enumeration
      qname == service_type and qtype == :PTR ->
        ptr = build_ptr_record(service)
        srv = build_srv_record(service)
        txt = build_txt_record(service)
        a_records = build_a_records(service)
        aaaa_records = build_aaaa_records(service)

        %{
          answers: [ptr],
          authority: [],
          additional: [srv, txt] ++ a_records ++ aaaa_records
        }

      # SRV query for specific service instance
      qname == service_fqdn and qtype in [:SRV, :ANY] ->
        srv = build_srv_record(service)
        txt = build_txt_record(service)
        a_records = build_a_records(service)
        aaaa_records = build_aaaa_records(service)

        %{
          answers: [srv],
          authority: [],
          additional: [txt] ++ a_records ++ aaaa_records
        }

      # TXT query for specific service instance
      qname == service_fqdn and qtype == :TXT ->
        txt = build_txt_record(service)
        srv = build_srv_record(service)
        a_records = build_a_records(service)
        aaaa_records = build_aaaa_records(service)

        %{
          answers: [txt],
          authority: [],
          additional: [srv] ++ a_records ++ aaaa_records
        }

      # A record query for host
      qname == service_host and qtype in [:A, :ANY] ->
        a_records = build_a_records(service)

        %{
          answers: a_records,
          authority: [],
          additional: []
        }

      # AAAA record query for host
      qname == service_host and qtype in [:AAAA, :ANY] ->
        aaaa_records = build_aaaa_records(service)

        %{
          answers: aaaa_records,
          authority: [],
          additional: []
        }

      true ->
        %{answers: [], authority: [], additional: []}
    end
  end

  @doc """
  Builds goodbye records for a service being unregistered.

  Goodbye records have TTL=0 to signal service removal (RFC 6762 §10.1).
  """
  @spec build_goodbye_records(service()) :: [Record.t()]
  def build_goodbye_records(service) do
    ptr = %{build_ptr_record(service) | ttl: 0}
    srv = %{build_srv_record(service) | ttl: 0}
    txt = %{build_txt_record(service) | ttl: 0}
    a_records = Enum.map(build_a_records(service), &%{&1 | ttl: 0})
    aaaa_records = Enum.map(build_aaaa_records(service), &%{&1 | ttl: 0})

    [ptr, srv, txt] ++ a_records ++ aaaa_records
  end

  # Private helper functions

  defp is_ipv4?({_, _, _, _}), do: true
  defp is_ipv4?(_), do: false

  defp is_ipv6?({_, _, _, _, _, _, _, _}), do: true
  defp is_ipv6?(_), do: false

  @doc """
  Validates that DNS records can be built for a service.

  Checks that the service has the minimum required information.
  """
  @spec validate_service_for_records(service()) :: :ok | {:error, String.t()}
  def validate_service_for_records(service) do
    cond do
      is_nil(service.fqdn) or service.fqdn == "" ->
        {:error, "Service FQDN is required"}

      is_nil(service.host) or service.host == "" ->
        {:error, "Service host is required"}

      not is_integer(service.port) or service.port < 1 or service.port > 65535 ->
        {:error, "Valid port number is required"}

      true ->
        :ok
    end
  end

  @doc """
  Calculates the total size of DNS records for a service.

  Useful for ensuring responses fit within mDNS MTU limits (1232 bytes).
  """
  @spec calculate_record_size(service()) :: integer()
  def calculate_record_size(service) do
    records = build_all_records(service)

    ptr_size = record_size(records.ptr)
    srv_size = record_size(records.srv)
    txt_size = record_size(records.txt)
    a_size = Enum.sum_by(records.a, &record_size/1)
    aaaa_size = Enum.sum_by(records.aaaa, &record_size/1)

    ptr_size + srv_size + txt_size + a_size + aaaa_size
  end

  defp record_size(%Record{name: name, data: data}) do
    # Approximate size: name length + type (2) + class (2) + ttl (4) + rdlength (2) + data
    name_size = byte_size(to_string(name))

    data_size =
      case data do
        s when is_binary(s) -> byte_size(s)
        list when is_list(list) -> Enum.sum_by(list, fn item -> byte_size(to_string(item)) end)
        {_, _, _, _} -> 4
        {_, _, _, _, _, _, _, _} -> 16
        %{} -> 20
        _ -> 0
      end

    name_size + 10 + data_size
  end
end
