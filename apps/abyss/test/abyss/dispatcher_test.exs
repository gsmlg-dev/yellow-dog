defmodule Abyss.DispatcherTestTransport do
  def send(_socket, _ip, _port, _bytes), do: :ok
end

defmodule Abyss.DispatcherFailingTransport do
  def send(_socket, _ip, _port, _bytes), do: {:error, :closed}
end

defmodule Abyss.DispatcherTestCallback do
  @behaviour Abyss.DatagramDispatcher

  @impl true
  def init(context, _opts), do: {:ok, %{started: 0, send_fun: context.send_fun}}

  @impl true
  def handle_datagram(_remote, <<key, _rest::binary>>, _at, %{routes: routes, state: state}) do
    case Map.get(routes, key) do
      %{pid: pid} ->
        {:route, [key], pid, %{state | started: state.started}}

      nil ->
        pid = spawn(fn -> Process.sleep(:infinity) end)
        {:new, [key], pid, %{state | started: state.started + 1}}
    end
  end

  def handle_datagram(_remote, _bytes, _at, %{state: state}),
    do: {:drop, :malformed, state}
end

defmodule Abyss.DispatcherTest do
  use ExUnit.Case, async: true

  alias Abyss.Dispatcher

  test "serializes repeated route keys and cleans routes when connection exits" do
    {:ok, dispatcher} =
      Dispatcher.start_link(
        module: Abyss.DispatcherTestCallback,
        module_options: [],
        socket: :socket,
        transport: Abyss.DispatcherTestTransport,
        local_info: {{127, 0, 0, 1}, 4433},
        max_queue: 2,
        max_bytes: 32
      )

    assert :ok = Dispatcher.dispatch(dispatcher, {{127, 0, 0, 1}, 1000}, <<7, 1>>, 1)
    assert %{7 => %{pid: pid}} = Dispatcher.routes(dispatcher)
    assert Process.alive?(pid)

    assert :ok = Dispatcher.dispatch(dispatcher, {{127, 0, 0, 1}, 1000}, <<7, 2>>, 2)
    assert %{7 => %{pid: ^pid}} = Dispatcher.routes(dispatcher)

    Process.exit(pid, :kill)
    assert_eventually(fn -> Dispatcher.routes(dispatcher) == %{} end)
  end

  test "writer returns bounded admission and actual send completion" do
    {:ok, dispatcher} =
      Dispatcher.start_link(
        module: Abyss.DispatcherTestCallback,
        module_options: [],
        socket: :socket,
        transport: Abyss.DispatcherTestTransport,
        local_info: {{127, 0, 0, 1}, 4433},
        max_queue: 1,
        max_bytes: 1
      )

    state = :sys.get_state(dispatcher)
    assert {:ok, _ref} = Dispatcher.send(state.send, {{127, 0, 0, 1}, 1000}, <<1>>)

    assert {:error, :queue_bytes_limit} =
             Dispatcher.send(state.send, {{127, 0, 0, 1}, 1000}, <<2, 3>>)
  end

  test "callback receives a socket-independent send function" do
    {:ok, dispatcher} =
      Dispatcher.start_link(
        module: Abyss.DispatcherTestCallback,
        module_options: [],
        socket: :socket,
        transport: Abyss.DispatcherTestTransport,
        local_info: {{127, 0, 0, 1}, 4433},
        max_queue: 2,
        max_bytes: 32
      )

    state = :sys.get_state(dispatcher)
    assert is_function(state.callback_state.send_fun, 2)
    assert {:ok, _ref} = state.callback_state.send_fun.({{127, 0, 0, 1}, 1000}, <<1>>)
  end

  test "send receipt waits for writer completion and preserves failure" do
    {:ok, dispatcher} =
      Dispatcher.start_link(
        module: Abyss.DispatcherTestCallback,
        module_options: [],
        socket: :socket,
        transport: Abyss.DispatcherFailingTransport,
        local_info: {{127, 0, 0, 1}, 4433},
        max_queue: 2,
        max_bytes: 32
      )

    state = :sys.get_state(dispatcher)

    assert {:error, :closed} =
             Dispatcher.send_receipt(state.send, {{127, 0, 0, 1}, 1000}, <<1>>)
  end

  defp assert_eventually(fun, attempts \\ 20)
  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")

  defp assert_eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          assert_eventually(fun, attempts - 1)
        )
  end
end
