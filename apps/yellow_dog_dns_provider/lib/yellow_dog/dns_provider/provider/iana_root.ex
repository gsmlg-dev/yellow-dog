defmodule YellowDog.DnsProvider.Provider.IanaRoot do
  @moduledoc """
  Read-only provider that fetches the IANA root zone from HTTPS.
  Default source: https://www.internic.net/domain/root.zone
  """

  @behaviour YellowDog.DnsProvider.Provider

  @default_url "https://www.internic.net/domain/root.zone"

  @impl true
  def init(config) do
    url = Map.get(config, :url, @default_url)
    {:ok, %{url: url, cached_records: nil, last_fetch: nil}}
  end

  @impl true
  def list_zones(state), do: {:ok, [%{name: ".", id: nil}], state}

  @impl true
  def get_records(%{name: "."}, state) do
    case fetch_root_zone(state.url) do
      {:ok, body} ->
        records = parse_root_zone(body)

        {:ok, records,
         %{state | cached_records: records, last_fetch: System.system_time(:second)}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  def get_records(_zone_ref, state), do: {:error, :zone_not_found, state}

  @impl true
  def apply_changeset(_zone_ref, _changeset, state), do: {:error, :read_only, state}

  @impl true
  def zone_serial(%{name: "."}, state) do
    case fetch_root_zone(state.url) do
      {:ok, body} -> {:ok, extract_soa_serial(body), state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def zone_serial(_zone_ref, state), do: {:error, :zone_not_found, state}

  @doc false
  def parse_root_zone(zone_text) do
    zone_text
    |> String.split("\n")
    |> Enum.reject(fn line ->
      trimmed = String.trim(line)
      trimmed == "" or String.starts_with?(trimmed, ";")
    end)
    |> Enum.flat_map(&parse_line/1)
  end

  @doc false
  def extract_soa_serial(zone_text) do
    zone_text
    |> String.split("\n")
    |> Enum.find_value(0, fn line ->
      if String.contains?(line, "SOA") do
        parts = String.split(line, ~r/\s+/, trim: true)

        case Enum.drop(parts, 6) do
          [serial_str | _] ->
            case Integer.parse(serial_str) do
              {n, _} -> n
              :error -> nil
            end

          _ ->
            nil
        end
      end
    end)
  end

  defp parse_line(line) do
    parts = String.split(line, ~r/\s+/, trim: true)

    case parts do
      [owner, ttl_str, "IN", type | rdata_parts] ->
        type_upper = String.upcase(type)

        if type_upper == "SOA" do
          []
        else
          [
            %{
              owner: normalize_owner(owner),
              type: type_upper,
              ttl: parse_ttl(ttl_str),
              rdata: Enum.join(rdata_parts, " ")
            }
          ]
        end

      _ ->
        []
    end
  end

  defp normalize_owner(owner) do
    case String.trim_trailing(owner, ".") do
      "" -> "."
      other -> other <> "."
    end
  end

  defp parse_ttl(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> 3600
    end
  end

  defp fetch_root_zone(url) do
    case Req.get(url, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
