defmodule YellowDog.Fingerprint.FingerbankClient do
  @moduledoc """
  Optional Fingerbank API client for device identification fallback.

  Queries the Fingerbank API when local matching fails. Results are
  cached in ETS with a configurable TTL. Rate-limited to prevent abuse.

  Disabled by default — set `fingerbank_enabled: true` in config.
  """

  use GenServer

  require Logger

  @cache_table :fp_fingerbank_cache
  @default_ttl_hours 168
  @default_rate_limit 300

  # --- Public API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Queries Fingerbank to identify a fingerprint.

  Returns `{:ok, profile_id, confidence}` or `{:error, reason}`.
  Results are cached locally.
  """
  @spec interrogate(map()) :: {:ok, String.t(), non_neg_integer()} | {:error, term()}
  def interrogate(fingerprint) do
    GenServer.call(__MODULE__, {:interrogate, fingerprint}, 15_000)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    :ets.new(@cache_table, [:named_table, :set, :public, read_concurrency: true])

    state = %{
      api_key: Application.get_env(:yellow_dog_fingerprint, :fingerbank_api_key, ""),
      base_url: Application.get_env(:yellow_dog_fingerprint, :fingerbank_base_url, "https://api.fingerbank.org"),
      ttl_hours: Application.get_env(:yellow_dog_fingerprint, :fingerbank_cache_ttl_hours, @default_ttl_hours),
      rate_limit: Application.get_env(:yellow_dog_fingerprint, :fingerbank_rate_limit, @default_rate_limit),
      requests_this_hour: 0,
      hour_started: System.monotonic_time(:second)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:interrogate, fingerprint}, _from, state) do
    cache_key = fingerprint.id

    case check_cache(cache_key, state.ttl_hours) do
      {:ok, result} ->
        {:reply, result, state}

      :miss ->
        state = maybe_reset_rate_limit(state)

        if state.requests_this_hour >= state.rate_limit do
          {:reply, {:error, :rate_limited}, state}
        else
          result = do_interrogate(fingerprint, state)
          cache_result(cache_key, result)
          {:reply, result, %{state | requests_this_hour: state.requests_this_hour + 1}}
        end
    end
  end

  # --- Private ---

  defp check_cache(key, ttl_hours) do
    case :ets.lookup(@cache_table, key) do
      [{^key, result, cached_at}] ->
        age_hours = (System.monotonic_time(:second) - cached_at) / 3600

        if age_hours < ttl_hours do
          {:ok, result}
        else
          :ets.delete(@cache_table, key)
          :miss
        end

      [] ->
        :miss
    end
  end

  defp cache_result(key, result) do
    :ets.insert(@cache_table, {key, result, System.monotonic_time(:second)})
  end

  defp maybe_reset_rate_limit(state) do
    now = System.monotonic_time(:second)

    if now - state.hour_started >= 3600 do
      %{state | requests_this_hour: 0, hour_started: now}
    else
      state
    end
  end

  defp do_interrogate(_fingerprint, %{api_key: ""}) do
    {:error, :no_api_key}
  end

  defp do_interrogate(_fingerprint, _state) do
    # Fingerbank API integration is a stub — requires HTTP client (Req)
    # POST /api/v2/combinations/interrogate
    # Headers: Authorization: Bearer <api_key>
    # Body: %{dhcp_fingerprint: "1,3,6,15,...", dhcp_vendor: "MSFT 5.0"}
    {:error, :not_implemented}
  end
end
