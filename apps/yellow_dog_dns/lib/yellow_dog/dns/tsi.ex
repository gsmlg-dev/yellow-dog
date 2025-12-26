defmodule YellowDog.Dns.TSI do
  @moduledoc """
  Telemetry Span Item (TSI) for DNS request tracking.

  A TSI is created for each DNS request and passed through the entire
  resolution chain. It provides:

  - Request correlation for telemetry
  - Client context (IP, port)
  - Query metadata
  - Resolution path tracking (view, zone)
  - Timing information
  """

  alias DNS.Message

  @type t :: %__MODULE__{
          id: binary(),
          query: Message.t() | nil,
          client_ip: :inet.ip_address(),
          client_port: :inet.port_number(),
          received_at: integer(),
          view: String.t() | nil,
          zone: String.t() | nil,
          response: Message.t() | nil,
          completed_at: integer() | nil,
          metadata: map()
        }

  defstruct [
    :id,
    :query,
    :client_ip,
    :client_port,
    :received_at,
    :view,
    :zone,
    :response,
    :completed_at,
    metadata: %{}
  ]

  @doc """
  Creates a new TSI for an incoming DNS request.

  ## Parameters

  - `query` - Parsed DNS.Message
  - `client_ip` - Client IP address tuple
  - `client_port` - Client port number

  ## Returns

  A new TSI struct with unique ID and timestamp.
  """
  @spec new(Message.t(), :inet.ip_address(), :inet.port_number()) :: t()
  def new(query, client_ip, client_port) do
    %__MODULE__{
      id: generate_id(),
      query: query,
      client_ip: client_ip,
      client_port: client_port,
      received_at: System.monotonic_time(:microsecond),
      metadata: %{}
    }
  end

  @doc """
  Creates a new TSI from raw data before parsing.

  Used when we want to track the request even before parsing succeeds.
  """
  @spec new_raw(:inet.ip_address(), :inet.port_number()) :: t()
  def new_raw(client_ip, client_port) do
    %__MODULE__{
      id: generate_id(),
      query: nil,
      client_ip: client_ip,
      client_port: client_port,
      received_at: System.monotonic_time(:microsecond),
      metadata: %{}
    }
  end

  @doc """
  Sets the parsed query on the TSI.
  """
  @spec set_query(t(), Message.t()) :: t()
  def set_query(%__MODULE__{} = tsi, query) do
    %{tsi | query: query}
  end

  @doc """
  Sets the view that handled this request.
  """
  @spec set_view(t(), String.t()) :: t()
  def set_view(%__MODULE__{} = tsi, view_name) do
    %{tsi | view: view_name}
  end

  @doc """
  Sets the zone that resolved this request.
  """
  @spec set_zone(t(), String.t()) :: t()
  def set_zone(%__MODULE__{} = tsi, zone_name) do
    %{tsi | zone: zone_name}
  end

  @doc """
  Sets the response and completion time.
  """
  @spec complete(t(), Message.t()) :: t()
  def complete(%__MODULE__{} = tsi, response) do
    %{tsi | response: response, completed_at: System.monotonic_time(:microsecond)}
  end

  @doc """
  Marks the TSI as complete without a response (error case).
  """
  @spec complete_error(t()) :: t()
  def complete_error(%__MODULE__{} = tsi) do
    %{tsi | completed_at: System.monotonic_time(:microsecond)}
  end

  @doc """
  Adds metadata to the TSI.
  """
  @spec put_metadata(t(), atom(), term()) :: t()
  def put_metadata(%__MODULE__{} = tsi, key, value) do
    %{tsi | metadata: Map.put(tsi.metadata, key, value)}
  end

  @doc """
  Merges metadata into the TSI.
  """
  @spec merge_metadata(t(), map()) :: t()
  def merge_metadata(%__MODULE__{} = tsi, metadata) when is_map(metadata) do
    %{tsi | metadata: Map.merge(tsi.metadata, metadata)}
  end

  @doc """
  Returns the elapsed time in microseconds.
  """
  @spec elapsed_us(t()) :: integer()
  def elapsed_us(%__MODULE__{received_at: received_at, completed_at: nil}) do
    System.monotonic_time(:microsecond) - received_at
  end

  def elapsed_us(%__MODULE__{received_at: received_at, completed_at: completed_at}) do
    completed_at - received_at
  end

  @doc """
  Returns the elapsed time in milliseconds.
  """
  @spec elapsed_ms(t()) :: float()
  def elapsed_ms(%__MODULE__{} = tsi) do
    elapsed_us(tsi) / 1000.0
  end

  @doc """
  Returns a map suitable for telemetry metadata.
  """
  @spec to_telemetry_metadata(t()) :: map()
  def to_telemetry_metadata(%__MODULE__{} = tsi) do
    %{
      tsi_id: tsi.id,
      client_ip: format_ip(tsi.client_ip),
      client_port: tsi.client_port,
      view: tsi.view,
      zone: tsi.zone,
      query_name: get_query_name(tsi.query),
      query_type: get_query_type(tsi.query),
      response_code: get_response_code(tsi.response),
      elapsed_us: elapsed_us(tsi)
    }
    |> Map.merge(tsi.metadata)
  end

  # Generate a unique request ID
  defp generate_id do
    # Use a combination of timestamp and random bytes for uniqueness
    timestamp = System.system_time(:microsecond)
    random = :crypto.strong_rand_bytes(8)
    Base.encode16(<<timestamp::64>> <> random, case: :lower)
  end

  defp format_ip(ip) when is_tuple(ip) do
    :inet.ntoa(ip) |> to_string()
  end

  defp format_ip(ip), do: inspect(ip)

  defp get_query_name(nil), do: nil

  defp get_query_name(%Message{qdlist: [question | _]}) do
    question.name
  end

  defp get_query_name(_), do: nil

  defp get_query_type(nil), do: nil

  defp get_query_type(%Message{qdlist: [question | _]}) do
    question.type
  end

  defp get_query_type(_), do: nil

  defp get_response_code(nil), do: nil

  defp get_response_code(%Message{header: header}) do
    header.rcode
  end
end
