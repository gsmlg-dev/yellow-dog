defmodule Abyss.TestHelper do
  @moduledoc """
  Test utilities for Abyss
  """

  @doc """
  Starts a test server with the given configuration.
  Returns {:ok, {server_pid, port}}
  """
  def start_test_server(opts \\ []) do
    opts = Keyword.put(opts, :port, 0)

    case Abyss.start_link(opts) do
      {:ok, server_pid} ->
        # Get the actual port
        listener_pool_pid = Abyss.Server.listener_pool_pid(server_pid)
        listener_pids = Abyss.ListenerPool.listener_pids(listener_pool_pid)

        if length(listener_pids) > 0 do
          listener_pid = hd(listener_pids)
          {:ok, {_ip, port}} = Abyss.Listener.listener_info(listener_pid)
          {:ok, {server_pid, port}}
        else
          {:error, :no_listeners}
        end

      error ->
        error
    end
  end

  @doc """
  Creates a UDP client socket for testing
  """
  def create_test_client do
    Abyss.Transport.UDP.listen(0, [])
  end

  @doc """
  Sends data to server and receives response
  """
  def send_and_receive(client_socket, server_ip, server_port, data, timeout \\ 1000) do
    with :ok <- Abyss.Transport.UDP.send(client_socket, server_ip, server_port, data),
         {:ok, {_client_ip, _client_port, response}} <-
           Abyss.Transport.UDP.recv(client_socket, 0, timeout) do
      {:ok, response}
    end
  end

  @doc """
  Stops a test server and cleans up
  """
  def stop_test_server(server_pid) do
    Abyss.stop(server_pid)
  end

  @doc """
  Waits for a message to be received by the test process
  """
  def wait_for_message(_pattern, timeout \\ 1000) do
    receive do
      msg -> {:ok, msg}
    after
      timeout -> {:error, :timeout}
    end
  end
end
