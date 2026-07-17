defmodule YellowDog.ServerAgent do
  @moduledoc """
  Public facade for the local `yellow_dog_server` management agent skeleton.
  """

  alias YellowDog.ServerAgent.Client
  alias YellowDog.ServerAgent.Status
  alias YellowDog.ServerAgent.Supervisor

  @doc "Starts the server agent supervision tree."
  def start_link(opts \\ []) do
    with {:ok, prepared_opts} <- Supervisor.prepare_options(opts) do
      start_prepared_link(prepared_opts)
    end
  end

  def child_spec(opts) do
    case Supervisor.prepare_child_spec_options(opts) do
      {:ok, prepared_opts} ->
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_prepared_link, [prepared_opts]},
          type: :supervisor
        }

      {:error, :invalid_configuration} ->
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_invalid, []},
          type: :supervisor
        }
    end
  end

  @doc false
  def start_prepared_link(prepared_opts),
    do: Supervisor.start_prepared_child_link(prepared_opts)

  @doc false
  def start_invalid, do: {:error, :invalid_configuration}

  @doc "Returns a safe local status snapshot without contacting management core."
  def status_snapshot(opts \\ []), do: Status.snapshot(opts)

  @doc "Reports whether the configured outbound Client is active."
  def connected?(client \\ Client), do: Client.connected?(client) == true

  @doc "Returns the bounded local outbound connection state."
  def connection_state(client \\ Client) do
    case Client.connection_state(client) do
      state
      when state in [
             :disabled,
             :connecting,
             :handshaking,
             :active,
             :backoff,
             :unavailable
           ] ->
        state

      _invalid ->
        :unavailable
    end
  end
end
