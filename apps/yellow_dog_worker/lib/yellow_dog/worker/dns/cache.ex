defmodule YellowDog.Worker.Dns.Cache do
  @moduledoc """
  Per-service DNS answer cache backed by an unnamed public ETS table owned by the
  creating process. Keys are `{lowercase name, integer type}`.
  """

  alias DNS.Message.Record

  @type t :: %__MODULE__{
          table: :ets.tid(),
          clock: (-> integer()),
          max_entries: pos_integer(),
          max_ttl: non_neg_integer(),
          negative_ttl_cap: non_neg_integer()
        }
  defstruct [:table, :clock, :max_entries, :max_ttl, :negative_ttl_cap]

  @type result :: %{rcode: 0 | 3, answers: [Record.t()], authority: [Record.t()]}

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      table: :ets.new(__MODULE__, [:set, :public, read_concurrency: true]),
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
      max_entries: Keyword.get(opts, :max_entries, 10_000),
      max_ttl: Keyword.get(opts, :max_ttl, 86_400),
      negative_ttl_cap: Keyword.get(opts, :negative_ttl_cap, 3_600)
    }
  end

  @spec get(t(), String.t(), non_neg_integer()) :: {:ok, result()} | :miss
  def get(%__MODULE__{table: table, clock: clock}, name, type) do
    now = clock.()

    case :ets.lookup(table, key(name, type)) do
      [{_, inserted, expires, rcode, answers, authority, _seq}] when now < expires ->
        elapsed = div(now - inserted, 1000)
        remaining = div(expires - now + 999, 1000)
        age = fn r -> %{r | ttl: max(min(r.ttl - elapsed, remaining), 0)} end

        {:ok,
         %{rcode: rcode, answers: Enum.map(answers, age), authority: Enum.map(authority, age)}}

      _ ->
        :miss
    end
  end

  @spec put(t(), String.t(), non_neg_integer(), result()) :: :ok
  def put(%__MODULE__{} = cache, name, type, %{
        rcode: rcode,
        answers: answers,
        authority: authority
      }) do
    case entry_ttl(cache, rcode, answers, authority) do
      ttl when is_integer(ttl) and ttl > 0 ->
        now = cache.clock.()
        capped = fn r -> %{r | ttl: min(r.ttl, cache.max_ttl)} end

        :ets.insert(
          cache.table,
          {key(name, type), now, now + ttl * 1000, rcode, Enum.map(answers, capped),
           Enum.map(authority, capped), :erlang.unique_integer([:monotonic])}
        )

        evict(cache, now)

      _ ->
        :ok
    end
  end

  @spec delete(t()) :: :ok
  def delete(%__MODULE__{table: table}) do
    :ets.delete(table)
    :ok
  end

  defp key(name, type), do: {String.downcase(name), type}

  defp entry_ttl(cache, 0, [_ | _] = answers, _authority),
    do: min(answers |> Enum.map(& &1.ttl) |> Enum.min(), cache.max_ttl)

  defp entry_ttl(cache, rcode, _answers, authority) when rcode in [0, 3] do
    case Enum.find(authority, &(to_string(&1.type) == "SOA")) do
      %Record{ttl: ttl, data: %{data: {_, _, _, _, _, _, minimum}}} ->
        Enum.min([ttl, minimum, cache.negative_ttl_cap, cache.max_ttl])

      _ ->
        nil
    end
  end

  defp entry_ttl(_, _, _, _), do: nil

  defp evict(%{table: table, max_entries: max}, now) do
    if :ets.info(table, :size) > max do
      :ets.select_delete(table, [{{:_, :_, :"$1", :_, :_, :_, :_}, [{:"=<", :"$1", now}], [true]}])

      size = :ets.info(table, :size)

      if size > max do
        table
        |> :ets.select([{{:"$1", :_, :_, :_, :_, :_, :"$2"}, [], [{{:"$2", :"$1"}}]}])
        |> Enum.sort()
        |> Enum.take(size - max)
        |> Enum.each(fn {_, k} -> :ets.delete(table, k) end)
      end
    end

    :ok
  end
end
