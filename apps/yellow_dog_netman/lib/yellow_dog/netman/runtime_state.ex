defmodule YellowDog.Netman.RuntimeState do
  @moduledoc false

  use GenServer

  alias YellowDog.Netman.FeatureRegistry

  @apply_modes [:managed, :observe_first, :observe]

  @type state :: %{
          apply_mode: :managed | :observe_first | :observe,
          features: %{optional(atom()) => boolean()}
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec snapshot() :: {:ok, state()} | :error
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  catch
    :exit, _reason -> :error
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       apply_mode: normalize_apply_mode(Keyword.get(opts, :apply_mode, :managed)),
       features: normalize_features(Keyword.get(opts, :features, %{}))
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, {:ok, state}, state}

  defp normalize_apply_mode(mode) when mode in @apply_modes, do: mode
  defp normalize_apply_mode(_mode), do: :observe_first

  defp normalize_features(features) when is_map(features) do
    Map.new(FeatureRegistry.list_features(), fn feature ->
      {feature, Map.get(features, feature, false) == true}
    end)
  end

  defp normalize_features(_features), do: normalize_features(%{})
end
