defmodule YellowDog.Console.Diagnostics.QueryResult do
  @moduledoc """
  Represents a completed diagnostic query with request/response data.

  Used by all protocol tabs (DNS, mDNS, DHCPv4, DHCPv6) to store
  query results including timing information and binary payloads.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          timestamp: DateTime.t(),
          params: map(),
          request_binary: binary(),
          request_struct: struct() | nil,
          response_binary: binary() | nil,
          response_struct: struct() | nil,
          sources: [map()],
          latency_ms: non_neg_integer(),
          status: :success | :timeout | :error,
          error: String.t() | nil
        }

  defstruct [
    :id,
    :timestamp,
    :params,
    :request_binary,
    :request_struct,
    :response_binary,
    :response_struct,
    :sources,
    :latency_ms,
    :status,
    :error
  ]

  @doc """
  Creates a new QueryResult with auto-generated ID and timestamp.
  """
  @spec new(map()) :: t()
  def new(attrs \\ %{}) do
    defaults = %{
      id: generate_id(),
      timestamp: DateTime.utc_now(),
      params: %{},
      request_binary: <<>>,
      request_struct: nil,
      response_binary: nil,
      response_struct: nil,
      sources: [],
      latency_ms: 0,
      status: :success,
      error: nil
    }

    struct(__MODULE__, Map.merge(defaults, attrs))
  end

  @doc """
  Creates a success result with timing and response data.
  """
  @spec success(map(), struct(), binary(), struct(), binary(), non_neg_integer()) :: t()
  def success(
        params,
        request_struct,
        request_binary,
        response_struct,
        response_binary,
        latency_ms
      ) do
    new(%{
      params: params,
      request_struct: request_struct,
      request_binary: request_binary,
      response_struct: response_struct,
      response_binary: response_binary,
      latency_ms: latency_ms,
      status: :success
    })
  end

  @doc """
  Creates an error result.
  """
  @spec error(map(), struct() | nil, binary(), String.t(), non_neg_integer()) :: t()
  def error(params, request_struct, request_binary, error_message, latency_ms \\ 0) do
    new(%{
      params: params,
      request_struct: request_struct,
      request_binary: request_binary,
      latency_ms: latency_ms,
      status: :error,
      error: error_message
    })
  end

  @doc """
  Creates a timeout result.
  """
  @spec timeout(map(), struct() | nil, binary(), non_neg_integer()) :: t()
  def timeout(params, request_struct, request_binary, latency_ms) do
    new(%{
      params: params,
      request_struct: request_struct,
      request_binary: request_binary,
      latency_ms: latency_ms,
      status: :timeout,
      error: "Query timed out"
    })
  end

  @doc """
  Creates a multicast result with multiple sources (for mDNS).
  """
  @spec multicast_success(map(), struct(), binary(), [map()], non_neg_integer()) :: t()
  def multicast_success(params, request_struct, request_binary, sources, latency_ms) do
    new(%{
      params: params,
      request_struct: request_struct,
      request_binary: request_binary,
      sources: sources,
      latency_ms: latency_ms,
      status: :success
    })
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
