defmodule YellowDog.Management.EventStore do
  @moduledoc false

  use GenServer

  require Logger

  alias YellowDog.Management.Event
  alias YellowDog.Management.Storage.AtomicJson
  alias YellowDog.Management.Storage.Path, as: StoragePath

  @default_max_events 500

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc false
  def append(attrs), do: GenServer.call(__MODULE__, {:append, attrs})

  @doc false
  def list, do: GenServer.call(__MODULE__, :list)

  @impl true
  def init(:ok), do: {:ok, next_sequence()}

  @impl true
  def handle_call({:append, attrs}, _from, sequence) do
    event = Event.new(attrs, sequence)

    with {:ok, path} <- StoragePath.event(event.id),
         {:ok, _path} <- AtomicJson.create(path, Event.to_map(event)) do
      {:reply, {:ok, event}, sequence + 1}
    else
      {:error, _reason} = error -> {:reply, error, sequence}
    end
  end

  def handle_call(:list, _from, sequence) do
    events =
      read_events()
      |> Enum.sort_by(&{&1.sequence, &1.occurred_at, &1.id})
      |> Enum.take(-max_events())

    {:reply, events, sequence}
  end

  defp read_events do
    with {:ok, root} <- StoragePath.root() do
      root
      |> Path.join("events/*.json")
      |> Path.wildcard()
      |> Enum.flat_map(&read_event/1)
    else
      _error -> []
    end
  end

  defp read_event(path) do
    with {:ok, value} <- AtomicJson.read(path),
         {:ok, event} <- Event.from_map(value),
         {:ok, expected_path} <- StoragePath.event(event.id),
         true <- expected_path == path do
      [event]
    else
      _invalid ->
        Logger.warning("Ignoring malformed management event file: #{path}")
        []
    end
  end

  defp next_sequence do
    with {:ok, root} <- StoragePath.root() do
      root
      |> Path.join("events/evt-*.json")
      |> Path.wildcard()
      |> Enum.map(&event_file_sequence/1)
      |> Enum.max(fn -> 0 end)
      |> Kernel.+(1)
    else
      _error -> 1
    end
  end

  defp event_file_sequence(path) do
    case Regex.run(~r/^evt-([1-9][0-9]*)\.json$/, Path.basename(path)) do
      [_, sequence] -> String.to_integer(sequence)
      _invalid -> 0
    end
  end

  defp max_events do
    case Application.get_env(:yellow_dog_management_core, :max_events, @default_max_events) do
      limit when is_integer(limit) and limit > 0 -> limit
      _invalid -> @default_max_events
    end
  end
end
