defmodule YellowDog.Worker.Connection do
  @moduledoc """
  Opt-in Management connection over the `worker:<id>` Phoenix channel at
  `/api/worker/connect`; execution and offline recovery remain local.

  The token travels only in the join payload, never in the upgrade request.
  Management pushes `"target"`; the Worker pushes `"report"` after each target
  and as a periodic heartbeat. Any socket, channel or join failure tears the
  client down and reconnects with exponential backoff.
  """
  use GenServer
  alias YellowDog.ConfigSpec
  alias YellowDog.Worker.ServiceManager

  @connect_timeout 10_000
  @await_interval 50
  @report_interval 15_000
  @backoff {1_000, 30_000}
  @join_errors ~w(unauthorized unavailable invalid_report)

  def start_link(options),
    do: GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))

  def status(pid), do: GenServer.call(pid, :status)

  @impl true
  def init(options) do
    options = resolve(options)
    token = options[:token]
    if token == nil, do: raise("invalid managed bootstrap")
    worker_id = Keyword.fetch!(options, :worker_id)
    # The socket client is linked; its exit must reconnect, not crash us.
    Process.flag(:trap_exit, true)

    state = %{
      manager: Keyword.get(options, :manager, ServiceManager),
      worker_id: worker_id,
      # Kept in a closure so the token never appears in state dumps.
      credential: fn -> token end,
      impl: Keyword.get(options, :socket_impl, __MODULE__.Channel),
      socket_options: [
        name: Keyword.get(options, :socket_name, __MODULE__.Socket),
        url: socket_url(options[:management_url]),
        params: %{"worker_id" => worker_id},
        tls: tls(options)
      ],
      report_interval: Keyword.get(options, :report_interval_ms, @report_interval),
      backoff: Keyword.get(options, :backoff_ms, @backoff),
      phase: :idle,
      socket: nil,
      channel: nil,
      deadline: nil,
      timer: nil,
      failures: 0,
      apply_error: nil,
      connection_error: nil,
      connected: false
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: {:noreply, connect(state)}

  @impl true
  def handle_call(:status, _from, state), do: {:reply, public_status(state), state}

  @impl true
  def handle_info(:connect, %{phase: :waiting} = state), do: {:noreply, connect(state)}

  def handle_info(:await_socket, %{phase: :connecting} = state) do
    case safe(fn -> state.impl.status(state.socket) end) do
      :connected ->
        {:noreply, join(state)}

      :connecting ->
        if System.monotonic_time(:millisecond) < state.deadline do
          Process.send_after(self(), :await_socket, @await_interval)
          {:noreply, state}
        else
          {:noreply, retry(state, "request_failed")}
        end

      _ ->
        {:noreply, retry(state, "request_failed")}
    end
  end

  def handle_info(:report, %{phase: :joined} = state),
    do: {:noreply, state |> push_report() |> schedule_report()}

  def handle_info({__MODULE__.Channel, pid, "target", payload}, %{channel: {pid, _}} = state) do
    target = if is_map(payload), do: Map.get(payload, "target", :invalid), else: :invalid
    {:noreply, state |> apply_target(target) |> push_report()}
  end

  def handle_info({__MODULE__.Channel, pid, event, _}, %{channel: {pid, _}} = state)
      when event in ["phx_close", "phx_error"],
      do: {:noreply, retry(state, "disconnected")}

  def handle_info({:DOWN, ref, :process, _, _}, %{channel: {_, ref}} = state),
    do: {:noreply, retry(state, "disconnected")}

  def handle_info({:EXIT, pid, _}, %{socket: pid} = state),
    do: {:noreply, retry(state, "disconnected")}

  # Stale timers, replies to asynchronous report pushes and exits of retired clients.
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    teardown(state)
    :ok
  end

  @impl true
  def format_status(status), do: Map.put(status, :state, "[redacted Worker connection]")

  defp resolve(options) do
    case options[:bootstrap_path] do
      nil ->
        options

      path ->
        with {:ok, bootstrap} <- YellowDog.Worker.Bootstrap.load(path),
             {:ok, credentials} <-
               ServiceManager.connection_credentials(options[:manager] || ServiceManager) do
          options
          |> Keyword.merge(bootstrap[:connection] || [])
          |> Keyword.merge(Map.to_list(credentials))
        else
          _ -> []
        end
    end
  end

  defp connect(state) do
    case safe(fn -> state.impl.open(state.socket_options) end) do
      {:ok, socket} ->
        send(self(), :await_socket)

        %{
          state
          | phase: :connecting,
            socket: socket,
            deadline: System.monotonic_time(:millisecond) + @connect_timeout
        }

      _ ->
        retry(state, "request_failed")
    end
  end

  defp join(state) do
    topic = "worker:" <> state.worker_id

    result =
      with {:ok, status} <- manager_status(state) do
        payload = %{"token" => state.credential.(), "report" => report(state, status)}
        safe(fn -> state.impl.join(state.socket, topic, payload) end)
      end

    case result do
      {:ok, channel} when is_pid(channel) ->
        ref = Process.monitor(channel)

        schedule_report(%{
          state
          | phase: :joined,
            channel: {channel, ref},
            connected: true,
            connection_error: nil,
            failures: 0
        })

      {:error, :manager_unavailable} ->
        retry(state, "manager_unavailable")

      {:error, code} when code in @join_errors ->
        retry(state, code)

      _ ->
        retry(state, "request_failed")
    end
  end

  defp retry(state, error) do
    state = teardown(state)
    {minimum, maximum} = state.backoff
    base = min(minimum * Integer.pow(2, state.failures), maximum)
    # Up to 20% jitter spreads reconnecting Workers; it is subtracted at the
    # cap so no delay ever exceeds the maximum.
    jitter = :rand.uniform(div(base, 5) + 1) - 1
    delay = if base + jitter <= maximum, do: base + jitter, else: maximum - jitter

    %{
      state
      | phase: :waiting,
        timer: Process.send_after(self(), :connect, delay),
        failures: min(state.failures + 1, 16),
        connected: false,
        connection_error: error
    }
  end

  defp teardown(state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    case state.channel do
      {_, ref} -> Process.demonitor(ref, [:flush])
      nil -> :ok
    end

    if state.socket, do: safe(fn -> state.impl.close(state.socket) end)
    %{state | phase: :idle, socket: nil, channel: nil, deadline: nil, timer: nil}
  end

  defp schedule_report(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :report, state.report_interval)}
  end

  defp push_report(%{channel: {channel, _}} = state) do
    with {:ok, status} <- manager_status(state) do
      safe(fn -> state.impl.push(channel, "report", report(state, status)) end)
    end

    state
  end

  defp apply_target(state, target) do
    case manager_status(state) do
      {:ok, status} ->
        result =
          try do
            accept_target(target, status, state)
          rescue
            _ -> {:error, :apply_failed}
          catch
            :exit, _ -> {:error, :apply_failed}
          end

        case result do
          :ok -> %{state | apply_error: nil}
          {:error, reason} -> %{state | apply_error: Atom.to_string(reason)}
        end

      {:error, _} ->
        state
    end
  end

  defp manager_status(state) do
    {:ok, ServiceManager.status(state.manager)}
  catch
    :exit, _ -> {:error, :manager_unavailable}
  end

  # Adapter failures are reduced to an atom so neither the join payload nor
  # exception arguments can reach a crash report.
  defp safe(fun) do
    fun.()
  rescue
    _ -> {:error, :request_failed}
  catch
    _, _ -> {:error, :request_failed}
  end

  defp socket_url(url) when is_binary(url) do
    uri = URI.parse(url)
    scheme = if uri.scheme == "https", do: "wss", else: "ws"
    port = if uri.port == URI.default_port(uri.scheme), do: nil, else: uri.port

    URI.to_string(%URI{
      scheme: scheme,
      host: uri.host,
      port: port,
      path: "/api/worker/connect"
    })
  end

  defp socket_url(_), do: nil

  defp tls(options) do
    if is_binary(options[:management_url]) and
         URI.parse(options[:management_url]).scheme == "https" do
      ca =
        case options[:tls_ca_file] do
          nil -> [cacerts: :public_key.cacerts_get()]
          path -> [cacertfile: String.to_charlist(path)]
        end

      client =
        if options[:tls_cert_file] && options[:tls_key_file] do
          [
            certfile: String.to_charlist(options[:tls_cert_file]),
            keyfile: String.to_charlist(options[:tls_key_file])
          ]
        else
          []
        end

      [verify: :verify_peer] ++ ca ++ client
    else
      []
    end
  end

  defp report(state, status) do
    plan = status.desired
    digest = if plan, do: elem(ConfigSpec.plan_digest(plan), 1)

    %{
      "worker_id" => state.worker_id,
      "capabilities" => ["dns"],
      "services" =>
        Map.new(status.services, fn {id, service} ->
          observed =
            cond do
              service[:ready] != true -> "error"
              get_in(service, [:applied, "desired_state"]) == "stopped" -> "stopped"
              true -> "running"
            end

          {id, %{"state" => observed}}
        end),
      "applied_revision" => if(plan, do: plan["revision"]),
      "applied_digest" => digest,
      "apply_error" => state.apply_error
    }
  end

  defp accept_target(nil, _status, _state), do: :ok

  defp accept_target(%{"revision" => revision, "digest" => digest, "plan" => plan}, status, state) do
    with true <- is_integer(revision) and revision > 0,
         {:ok, normalized} <- ConfigSpec.normalize_plan(plan),
         true <-
           normalized["worker_id"] == state.worker_id and normalized["revision"] == revision,
         {:ok, actual_digest} <- ConfigSpec.plan_digest(normalized),
         true <- actual_digest == digest,
         :ok <- fresh_target(status.desired, revision, digest),
         {:ok, _} <- YellowDog.Worker.submit_plan(normalized, state.manager) do
      :ok
    else
      {:error, :stale_target} -> {:error, :stale_target}
      {:error, :revision_conflict} -> {:error, :invalid_target}
      {:error, _} -> {:error, :apply_failed}
      _ -> {:error, :invalid_target}
    end
  end

  defp accept_target(_, _, _), do: {:error, :invalid_target}

  defp fresh_target(nil, _, _), do: :ok

  defp fresh_target(plan, revision, digest) do
    {:ok, active_digest} = ConfigSpec.plan_digest(plan)

    cond do
      revision < plan["revision"] -> {:error, :stale_target}
      revision == plan["revision"] and digest != active_digest -> {:error, :revision_conflict}
      true -> :ok
    end
  end

  defp public_status(state), do: Map.take(state, [:connected, :connection_error, :apply_error])
end
