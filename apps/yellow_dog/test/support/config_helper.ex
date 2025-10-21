defmodule YellowDog.ConfigHelper do
  @moduledoc """
  Test helper module for configuration-related tests.

  Provides utilities for loading test configs, starting applications
  with specific configurations, and managing test state.
  """

  @fixtures_path Path.expand("../fixtures", __DIR__)

  @doc """
  Loads a test configuration from a fixture file.

  ## Examples

      iex> YellowDog.ConfigHelper.load_test_config("valid_config")
      {:ok, %{"core" => %{"dns" => true, ...}}}

      iex> YellowDog.ConfigHelper.load_test_config("nonexistent")
      {:error, :enoent}
  """
  @spec load_test_config(String.t()) :: {:ok, map()} | {:error, term()}
  def load_test_config(fixture_name) do
    path = fixture_path(fixture_name)
    YellowDog.Config.load(path)
  end

  @doc """
  Starts the Yellow Dog application with a specific configuration.

  ## Examples

      iex> config = %{"core" => %{"dns" => true}}
      iex> YellowDog.ConfigHelper.start_with_config(config)
      {:ok, pid}
  """
  @spec start_with_config(map()) :: {:ok, pid()} | {:error, term()}
  def start_with_config(config) do
    # Stop any running application first
    stop_all_services()

    # Start config agent with the provided config
    case YellowDog.Config.start_link(config) do
      {:ok, _pid} ->
        # Start the Yellow Dog application
        Application.start(:yellow_dog)

      error ->
        error
    end
  end

  @doc """
  Waits for a service to start with a timeout.

  ## Examples

      iex> YellowDog.ConfigHelper.wait_for_service(YellowDog.Dns, 1000)
      :ok

      iex> YellowDog.ConfigHelper.wait_for_service(NonExistent, 100)
      {:error, :timeout}
  """
  @spec wait_for_service(module(), non_neg_integer()) :: :ok | {:error, :timeout}
  def wait_for_service(service_module, timeout \\ 5000) do
    wait_for_process(service_module, timeout, System.monotonic_time(:millisecond))
  end

  defp wait_for_process(name, timeout, start_time) do
    case Process.whereis(name) do
      nil ->
        elapsed = System.monotonic_time(:millisecond) - start_time
        if elapsed < timeout do
          Process.sleep(50)
          wait_for_process(name, timeout, start_time)
        else
          {:error, :timeout}
        end

      _pid ->
        :ok
    end
  end

  @doc """
  Gets the current state/config of a service.

  ## Examples

      iex> YellowDog.ConfigHelper.get_service_config(:dns)
      %{port: 53, listen: "0.0.0.0"}
  """
  @spec get_service_config(atom()) :: map() | nil
  def get_service_config(service_name) do
    YellowDog.Config.get_service(service_name)
  end

  @doc """
  Stops all Yellow Dog services and the application.
  """
  @spec stop_all_services() :: :ok
  def stop_all_services do
    # Stop the application
    Application.stop(:yellow_dog)

    # Stop the config agent if running
    case Process.whereis(YellowDog.Config) do
      nil -> :ok
      pid -> Process.exit(pid, :kill)
    end

    # Give processes time to shut down
    Process.sleep(100)

    :ok
  end

  @doc """
  Returns the path to a fixture file.

  ## Examples

      iex> YellowDog.ConfigHelper.fixture_path("valid_config")
      "/path/to/test/fixtures/valid_config.toml"
  """
  @spec fixture_path(String.t()) :: String.t()
  def fixture_path(fixture_name) do
    Path.join(@fixtures_path, "#{fixture_name}.toml")
  end

  @doc """
  Creates a temporary config file with the given content.

  Returns the path to the created file. The file will be cleaned up
  when the test process exits.

  ## Examples

      iex> content = "[core]\\ndns = true"
      iex> path = YellowDog.ConfigHelper.create_temp_config(content)
      iex> File.exists?(path)
      true
  """
  @spec create_temp_config(String.t()) :: String.t()
  def create_temp_config(content) do
    # Create a temporary directory if it doesn't exist
    temp_dir = Path.join(System.tmp_dir!(), "yellow_dog_test")
    File.mkdir_p!(temp_dir)

    # Create a unique filename
    filename = "test_config_#{:erlang.unique_integer([:positive])}.toml"
    path = Path.join(temp_dir, filename)

    # Write the content
    File.write!(path, content)

    # Schedule cleanup when the process exits
    on_exit(fn -> File.rm(path) end)

    path
  end

  # Registers a cleanup function to run when the current process exits.
  defp on_exit(cleanup_fn) do
    # Get the current test process
    test_pid = self()

    # Spawn a monitor process
    spawn(fn ->
      ref = Process.monitor(test_pid)
      receive do
        {:DOWN, ^ref, :process, ^test_pid, _reason} ->
          cleanup_fn.()
      end
    end)
  end

  @doc """
  Asserts that a service is running.

  ## Examples

      iex> YellowDog.ConfigHelper.assert_service_running(YellowDog.Dns)
      true

      iex> YellowDog.ConfigHelper.assert_service_running(NonExistent)
      false
  """
  @spec assert_service_running(module()) :: boolean()
  def assert_service_running(service_module) do
    case Process.whereis(service_module) do
      nil -> false
      _pid -> true
    end
  end

  @doc """
  Asserts that a service is not running.

  ## Examples

      iex> YellowDog.ConfigHelper.assert_service_not_running(NonExistent)
      true
  """
  @spec assert_service_not_running(module()) :: boolean()
  def assert_service_not_running(service_module) do
    not assert_service_running(service_module)
  end

  @doc """
  Gets all running Yellow Dog service processes.

  Returns a list of tuples with {module_name, pid}.
  """
  @spec list_running_services() :: [{module(), pid()}]
  def list_running_services do
    services = [
      YellowDog.Config,
      YellowDog.Dns,
      YellowDog.Mdns,
      YellowDog.Dhcpv4,
      YellowDog.Dhcpv6
    ]

    Enum.filter(services, fn module ->
      Process.whereis(module) != nil
    end)
    |> Enum.map(fn module ->
      {module, Process.whereis(module)}
    end)
  end
end
