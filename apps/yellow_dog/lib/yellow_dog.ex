defmodule YellowDog do
  @moduledoc """
  YellowDog is a distributed DNS and DHCP server.

  This is the core application that provides:
  - Configuration management
  - Orchestration of protocol-specific applications
  - Public API for the YellowDog system
  """

  @banner_text "YellowDog DNS and DHCP Server"

  @doc false
  def banner do
    @banner_text
  end

  @doc false
  @spec child_spec(any()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    %{
      id: {__MODULE__, make_ref()},
      start: {__MODULE__, :start_link, []},
      type: :supervisor,
      restart: :permanent
    }
  end

  @doc """
  Starts a `YellowDog` instance.
  """
  @spec start_link(any()) :: Supervisor.on_start()
  def start_link(_opts \\ []) do
    # The YellowDog application is started via the Application module
    # This function is provided for compatibility but doesn't start anything directly
    {:ok, self()}
  end

  @doc """
  Get configuration value
  """
  def get_config(name) do
    YellowDog.Config.get(name)
  end

  @doc """
  Get all configuration
  """
  def get_all_config do
    YellowDog.Config.get_all()
  end
end
