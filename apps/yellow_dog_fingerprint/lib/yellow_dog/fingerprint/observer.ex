defmodule YellowDog.Fingerprint.Observer do
  @moduledoc """
  Telemetry event handler for DHCP fingerprinting.

  Subscribes to DHCPv4 and DHCPv6 message events, extracts fingerprint
  signals, runs the match pipeline, and updates the device registry.

  Processing is synchronous within the telemetry handler for ETS-backed
  operations (cheap). Fingerbank API fallbacks spawn async Tasks.
  """

  use GenServer

  alias YellowDog.Fingerprint.{Database, DeviceRegistry, Matcher, OUI}
  alias YellowDog.Fingerprint.Parser

  require Logger

  @dhcpv4_event [:yellow_dog, :dhcpv4, :message, :received]
  @dhcpv6_event [:yellow_dog, :dhcpv6, :message, :received]

  # --- Public API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    :telemetry.attach_many(
      "fingerprint-observer",
      [@dhcpv4_event, @dhcpv6_event],
      &__MODULE__.handle_event/4,
      nil
    )

    {:ok, %{}}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach("fingerprint-observer")
    :ok
  end

  # --- Telemetry Handler ---

  @doc false
  def handle_event(@dhcpv4_event, _measurements, metadata, _config) do
    process_dhcpv4(metadata)
  rescue
    error ->
      Logger.warning("Fingerprint observer DHCPv4 error: #{inspect(error)}")
  end

  def handle_event(@dhcpv6_event, _measurements, metadata, _config) do
    process_dhcpv6(metadata)
  rescue
    error ->
      Logger.warning("Fingerprint observer DHCPv6 error: #{inspect(error)}")
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  # --- Private ---

  defp process_dhcpv4(metadata) do
    case Parser.V4.extract(metadata) do
      {:ok, fingerprint} ->
        Database.record_fingerprint(fingerprint)
        mac = extract_mac_v4(metadata)
        process_match(fingerprint, mac, metadata)

      :skip ->
        :ok
    end
  end

  defp process_dhcpv6(metadata) do
    case Parser.V6.extract(metadata) do
      {:ok, fingerprint} ->
        Database.record_fingerprint(fingerprint)
        mac = extract_mac_v6(metadata)
        process_match(fingerprint, mac, metadata)

      :skip ->
        :ok
    end
  end

  defp process_match(fingerprint, nil, _metadata), do: emit_unknown(fingerprint)

  defp process_match(fingerprint, mac, metadata) do
    oui_vendor =
      case OUI.lookup(mac) do
        {:ok, vendor} -> vendor
        :not_found -> nil
      end

    case Matcher.match(fingerprint) do
      {:ok, profile_id, confidence, _source} ->
        DeviceRegistry.update_device(mac, %{
          fingerprint: fingerprint,
          profile_id: profile_id,
          profile_confidence: confidence,
          oui_vendor: oui_vendor,
          hostname: Map.get(metadata, :option_12) || Map.get(metadata, :option_39),
          source_ip: Map.get(metadata, :source_ip),
          duid: Map.get(metadata, :duid)
        })

        emit_identified(mac, profile_id, confidence)

      :unknown ->
        DeviceRegistry.update_device(mac, %{
          fingerprint: fingerprint,
          profile_id: nil,
          profile_confidence: 0,
          oui_vendor: oui_vendor,
          hostname: Map.get(metadata, :option_12) || Map.get(metadata, :option_39),
          source_ip: Map.get(metadata, :source_ip),
          duid: Map.get(metadata, :duid)
        })

        emit_unknown(fingerprint)
    end
  end

  defp extract_mac_v4(metadata) do
    case Map.get(metadata, :chaddr) do
      <<mac::binary-6, _::binary>> -> format_mac(mac)
      _ -> nil
    end
  end

  defp extract_mac_v6(metadata) do
    case Map.get(metadata, :duid) do
      # DUID-LLT: type(2) + hw_type(2) + time(4) + link_layer(6+)
      <<1::16, _hw::16, _time::32, mac::binary-6, _::binary>> -> format_mac(mac)
      # DUID-LL: type(2) + hw_type(2) + link_layer(6+)
      <<3::16, _hw::16, mac::binary-6, _::binary>> -> format_mac(mac)
      _ -> nil
    end
  end

  defp format_mac(<<a, b, c, d, e, f>>) do
    [a, b, c, d, e, f]
    |> Enum.map_join(":", &String.pad_leading(Integer.to_string(&1, 16), 2, "0"))
    |> String.downcase()
  end

  defp emit_identified(mac, profile_id, confidence) do
    :telemetry.execute(
      [:yellow_dog, :fingerprint, :device, :identified],
      %{count: 1},
      %{mac: mac, profile: profile_id, confidence: confidence}
    )
  end

  defp emit_unknown(%{id: id, protocol: protocol, parameter_list: params}) do
    :telemetry.execute(
      [:yellow_dog, :fingerprint, :unknown],
      %{count: 1},
      %{fingerprint_id: id, protocol: protocol, parameter_list: params}
    )
  end
end
