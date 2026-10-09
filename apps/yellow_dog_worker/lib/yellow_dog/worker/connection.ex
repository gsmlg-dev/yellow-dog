defmodule YellowDog.Worker.Connection do
  @moduledoc "Opt-in authenticated polling; execution and offline recovery remain local."
  use GenServer
  alias YellowDog.ConfigSpec
  alias YellowDog.Worker.{ConnectionHTTP, ServiceManager}

  def start_link(options),
    do: GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))

  def status(pid), do: GenServer.call(pid, :status)
  def poll(pid), do: GenServer.call(pid, :poll, 130_000)

  @impl true
  def init(options) do
    options =
      case options[:bootstrap_path] do
        nil ->
          options

        path ->
          case YellowDog.Worker.Bootstrap.load(path) do
            {:ok, bootstrap} -> Keyword.merge(options, bootstrap[:connection] || [])
            {:error, _} -> []
          end
      end

    if options[:token] == nil, do: raise("invalid managed bootstrap")

    state = %{
      options: options,
      manager: Keyword.get(options, :manager, ServiceManager),
      worker_id: Keyword.fetch!(options, :worker_id),
      apply_error: nil,
      connection_error: nil,
      connected: false
    }

    {:ok, state, {:continue, :poll}}
  end

  @impl true
  def handle_continue(:poll, state), do: {:noreply, schedule(exchange(state))}

  @impl true
  def handle_info(:poll, state), do: {:noreply, schedule(exchange(state))}

  @impl true
  def handle_call(:poll, _from, state) do
    next = exchange(state)
    {:reply, public_status(next), next}
  end

  def handle_call(:status, _from, state), do: {:reply, public_status(state), state}

  @impl true
  def format_status(status), do: Map.put(status, :state, "[redacted Worker connection]")

  defp schedule(state) do
    Process.send_after(self(), :poll, Keyword.get(state.options, :poll_interval_ms, 10_000))
    state
  end

  defp exchange(state) do
    status = ServiceManager.status(state.manager)

    case ConnectionHTTP.connect(state.options, report(state, status)) do
      {:ok, %{"worker_id" => id, "target" => target}} when id == state.worker_id ->
        case accept_target(target, status, state) do
          :ok ->
            %{state | connected: true, connection_error: nil, apply_error: nil}

          {:error, reason} ->
            %{state | connected: true, connection_error: nil, apply_error: Atom.to_string(reason)}
        end

      {:ok, _} ->
        %{state | connected: false, connection_error: "invalid_response"}

      {:error, reason} ->
        %{state | connected: false, connection_error: Atom.to_string(reason)}
    end
  rescue
    _ -> %{state | connected: false, connection_error: "request_failed"}
  catch
    :exit, _ -> %{state | connected: false, connection_error: "manager_unavailable"}
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
