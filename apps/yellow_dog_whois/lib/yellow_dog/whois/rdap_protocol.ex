defmodule YellowDog.Whois.RDAPProtocol do
  @moduledoc """
  RDAP lookup protocol (RFC 9082, RFC 9083).

  Queries the `rdap.org` bootstrap server, which 302-redirects to the
  authoritative RDAP service. The redirect is followed automatically by
  the HTTP client, returning the final JSON response from the registry.

  Supported object types:

  - `:domain` — domain name (e.g. `"example.com"`)
  - `:ip`     — IPv4 or IPv6 address (e.g. `"8.8.8.8"`, `"2001:db8::1"`)
  - `:asn`    — autonomous system number (e.g. `"64496"` or `64496`)

  Returns the parsed JSON map as returned by the authoritative RDAP server.
  The response structure follows RFC 9083 (JSON Responses for RDAP).

  ## Examples

      {:ok, data} = YellowDog.Whois.RDAPProtocol.lookup("example.com", :domain)
      {:ok, data} = YellowDog.Whois.RDAPProtocol.lookup("8.8.8.8", :ip)
      {:ok, data} = YellowDog.Whois.RDAPProtocol.lookup("64496", :asn)
  """

  require Logger

  @base_url "https://rdap.org"

  @type rdap_type :: :domain | :ip | :asn
  @type result :: {:ok, map()} | {:error, term()}

  @doc """
  Performs an RDAP lookup for the given object and type.

  The `:asn` type maps to the `autnum` path segment as per RFC 9082.
  """
  @spec lookup(binary() | integer(), rdap_type()) :: result()
  def lookup(object, type \\ :domain) do
    url = build_url(object, type)
    Logger.debug("RDAP lookup #{type} #{object} via #{url}")

    response = HTTP.fetch(url) |> HTTP.Promise.await()

    case response do
      %HTTP.Response{ok: true} = resp ->
        HTTP.Response.json(resp)

      %HTTP.Response{status: status} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.debug("RDAP lookup #{object} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_url(object, :asn) do
    "#{@base_url}/autnum/#{object}"
  end

  defp build_url(object, type) do
    "#{@base_url}/#{type}/#{object}"
  end
end
