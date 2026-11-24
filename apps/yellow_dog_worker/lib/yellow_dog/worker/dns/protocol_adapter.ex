defmodule YellowDog.Worker.Dns.ProtocolAdapter do
  @moduledoc false
  use GenServer

  alias YellowDog.Worker.Dns.{
    Cache,
    CertificateStore,
    DoqListener,
    Resolver,
    StreamListener,
    Tls,
    UdpHandler
  }

  alias YellowDog.Worker.OwnedShutdown

  @protocols ~w(udp tcp dot doq doh)
  @any_ipv4 {0, 0, 0, 0}
  @any_ipv6 {0, 0, 0, 0, 0, 0, 0, 0}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def status(pid), do: GenServer.call(pid, :status)

  def update(pid, service, resources),
    do: GenServer.call(pid, {:update, service, resources}, 25_000)

  def reload_certificate(pid, id, revision),
    do: GenServer.call(pid, {:reload_certificate, id, revision}, 25_000)

  def validate(service, resources) do
    with {:ok, _} <- Resolver.build_context(service, resources, nil), do: :ok
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    service = Keyword.fetch!(opts, :service)
    resources = Keyword.fetch!(opts, :resources)
    data_dir = Keyword.fetch!(opts, :data_dir)
    recursor_opts = Keyword.get(opts, :recursor_opts, [])

    with {:ok, context} <- Resolver.build_context(service, resources, Cache.new(), recursor_opts) do
      state = %{
        context: context,
        groups: %{},
        resources: resources,
        data_dir: data_dir,
        owner: hd(Process.get(:"$ancestors"))
      }

      {:ok, reconcile(service["config"], state)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, {:ok, state.context}, state}

  def handle_call({:tls_handshake_options, name}, _from, state) do
    case state.groups[name] do
      %{status: "running", tls_options: options} when is_function(options, 0) ->
        {:reply, {:ok, options.()}, state}

      _ ->
        {:reply, {:error, :listener_unavailable}, state}
    end
  end

  def handle_call({:reload_certificate, id, revision}, _from, state) do
    result = load_certificate(state.data_dir, id, revision)

    groups =
      Map.new(state.groups, fn {name, group} ->
        {name, reload(name, group, id, result, state.data_dir)}
      end)

    failed? =
      Enum.any?(groups, fn {_, group} ->
        group.spec.certificate == id and group.status != "stopped" and
          group.certificate_error != nil
      end)

    reply = if failed?, do: {:error, :dns_certificate_reload_failed}, else: :ok
    {:reply, reply, %{state | groups: groups}}
  end

  def handle_call({:update, service, resources}, _from, state) do
    case Resolver.update_context(service, resources, state.context) do
      {:ok, context} ->
        {:reply, :ok,
         reconcile(service["config"], %{state | context: context, resources: resources})}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:status, _from, state) do
    protocols = Map.new(state.groups, fn {name, group} -> {name, public(group)} end)

    {:reply,
     %{
       ready: true,
       operational: Enum.all?(protocols, fn {_, status} -> status["state"] != "error" end),
       protocols: protocols,
       owned_pids: [self() | Enum.flat_map(state.groups, fn {_, group} -> owned(group) end)],
       loaded_resources: Enum.map(state.resources, &Map.take(&1, ~w(id version digest)))
     }, state}
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, %{owner: pid} = state),
    do: {:stop, {:owner_exited, reason}, state}

  def handle_info({:EXIT, pid, reason}, state) do
    case find_listener(state.groups, pid) do
      {name, group, address} ->
        stop(group)
        failed = %{group | pids: [], status: "error", failure: failure(address, reason)}
        {:noreply, put_in(state.groups[name], failed)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.groups, fn {_, group} -> stop(group) end)
    Cache.delete(state.context.cache)
    :ok
  end

  defp reconcile(config, state) do
    groups =
      Map.new(@protocols, fn name ->
        transport = get_in(config, ["transports", name])
        listener = Map.get(transport, "listen", config["listen"])

        spec = %{
          addresses: addresses(listener),
          port: transport["port"],
          certificate: transport["certificate_id"]
        }

        previous = state.groups[name]

        result =
          cond do
            not transport["enabled"] ->
              stop(previous)
              group(spec, "stopped")

            match?(%{spec: ^spec, status: "running"}, previous) ->
              previous

            true ->
              stop(previous)
              group(spec, "pending")
          end

        {name, result}
      end)

    groups =
      Map.new(@protocols, fn name ->
        group = groups[name]
        {name, if(group.status == "pending", do: start(name, group, state.data_dir), else: group)}
      end)

    %{state | groups: groups}
  end

  defp group(spec, status) do
    %{
      spec: spec,
      pids: [],
      status: status,
      failure: nil,
      certificate_error: nil,
      revision: nil,
      tls_options: nil
    }
  end

  defp addresses(%{"mode" => "all"}), do: [@any_ipv4, @any_ipv6]
  defp addresses(%{"mode" => "all_ipv4"}), do: [@any_ipv4]
  defp addresses(%{"mode" => "all_ipv6"}), do: [@any_ipv6]

  defp addresses(%{"mode" => "specific", "addresses" => addresses}) do
    Enum.map(addresses, fn address ->
      {:ok, ip} = :inet.parse_strict_address(String.to_charlist(address))
      ip
    end)
  end

  defp start(name, group, data_dir) do
    case certificate(group.spec.certificate, data_dir) do
      {:ok, material, fallback?} ->
        group = if material, do: with_material(group, material), else: group

        group =
          if fallback?, do: %{group | certificate_error: "invalid_dns_certificate"}, else: group

        Enum.reduce_while(group.spec.addresses, group, fn address, acc ->
          case open(name, address, group.spec.port, material) do
            {:ok, pid} ->
              {:cont, %{acc | status: "running", pids: [{address, pid} | acc.pids]}}

            {:error, reason} ->
              stop(acc)
              {:halt, %{acc | pids: [], status: "error", failure: failure(address, reason)}}
          end
        end)

      {:error, reason} ->
        %{group | status: "error", failure: failure(hd(group.spec.addresses), reason)}
    end
  end

  defp certificate(nil, _data_dir), do: {:ok, nil, false}

  defp certificate(id, data_dir) do
    case CertificateStore.available_revisions(data_dir, id) do
      {:ok, []} ->
        {:error, :dns_certificate_not_found}

      {:ok, [latest | _] = revisions} ->
        Enum.find_value(revisions, {:error, :invalid_dns_certificate}, fn revision ->
          case load_certificate(data_dir, id, revision) do
            {:ok, material} -> {:ok, material, revision != latest}
            _ -> nil
          end
        end)

      _ ->
        {:error, :dns_certificate_storage_failed}
    end
  end

  defp load_certificate(data_dir, id, revision) do
    with {:ok, material} <- CertificateStore.fetch(data_dir, id, revision),
         :ok <- Tls.validate(material),
         do: {:ok, material}
  end

  defp reload(_name, %{status: "stopped"} = group, _id, _material, _dir), do: group

  defp reload(_name, %{spec: %{certificate: other}} = group, id, _material, _dir)
       when other != id,
       do: group

  defp reload(_name, group, _id, {:error, _}, _dir),
    do: %{group | certificate_error: "invalid_dns_certificate"}

  defp reload(name, %{status: "error"} = group, _id, {:ok, _}, dir),
    do: start(name, group(group.spec, "pending"), dir)

  defp reload(_name, %{revision: revision} = group, _id, {:ok, %{revision: same}}, _dir)
       when revision >= same,
       do: group

  defp reload("doq", group, _id, {:ok, material}, _dir) do
    pids = Enum.map(group.pids, &elem(&1, 1))

    # Keep the previous endpoints until all addresses switch successfully.
    success? =
      Enum.all?(pids, &safe_reload(fn -> DoqListener.prepare_reload(&1, material) end)) and
        Enum.all?(pids, &safe_reload(fn -> DoqListener.activate_reload(&1) end))

    Enum.each(pids, &safe_reload(fn -> DoqListener.finish_reload(&1, success?) end))

    if success?,
      do: with_material(group, material),
      else: %{group | certificate_error: "dns_certificate_reload_failed"}
  end

  defp reload(_name, group, _id, {:ok, material}, _dir), do: with_material(group, material)

  defp safe_reload(fun) do
    fun.() == :ok
  catch
    :exit, _ -> false
  end

  defp with_material(group, material) do
    options = Tls.otp_options(material)
    %{group | revision: material.revision, tls_options: fn -> options end, certificate_error: nil}
  end

  defp open("udp", ip, port, _material) do
    options = [ip: ip, reuseaddr: false, reuseport: false]
    options = if tuple_size(ip) == 8, do: [:inet6, {:ipv6_v6only, true} | options], else: options

    case Abyss.Endpoint.start_link(
           transport_module: Abyss.Transport.UDP.Unicast,
           datagram_handler: UdpHandler,
           handler_options: [adapter: self()],
           execution: :per_datagram,
           runtime_options: [callback_timeout: 60_000],
           port: port,
           transport_options: options,
           num_listeners: 1,
           max_packet_size: 4096
         ) do
      {:ok, pid} ->
        case await_udp(pid, {ip, port}, 30) do
          :ok ->
            {:ok, pid}

          {:error, reason} ->
            OwnedShutdown.stop(pid)
            {:error, reason}
        end

      error ->
        error
    end
  end

  defp open(kind, ip, port, material) when kind in ["tcp", "dot", "doh"] do
    StreamListener.start_link(
      kind: kind,
      ip: ip,
      port: port,
      certificate: material,
      adapter: self()
    )
  end

  defp open("doq", ip, port, material) do
    DoqListener.start_link(ip: ip, port: port, certificate: material, adapter: self())
  end

  defp await_udp(pid, endpoint, attempts) do
    case Abyss.Endpoint.local_endpoint(pid) do
      {:ok, ^endpoint} ->
        :ok

      _ when attempts == 0 ->
        {:error, :udp_not_ready}

      _ ->
        Process.sleep(20)
        await_udp(pid, endpoint, attempts - 1)
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp stop(nil), do: :ok

  defp stop(group) do
    Enum.each(group.pids, fn {_, pid} -> OwnedShutdown.stop(pid) end)
  end

  defp find_listener(groups, pid) do
    Enum.find_value(groups, fn {name, group} ->
      case Enum.find(group.pids, &(elem(&1, 1) == pid)) do
        {address, ^pid} -> {name, group, address}
        nil -> nil
      end
    end)
  end

  defp owned(group), do: Enum.flat_map(group.pids, fn {_, pid} -> OwnedShutdown.tree(pid) end)

  defp public(group) do
    status = %{
      "state" => group.status,
      "port" => group.spec.port,
      "addresses" => Enum.map(group.spec.addresses, &format_ip/1)
    }

    status = if group.failure, do: Map.put(status, "failure", group.failure), else: status

    status =
      if group.revision, do: Map.put(status, "certificate_revision", group.revision), else: status

    if group.certificate_error,
      do: Map.put(status, "certificate_error", group.certificate_error),
      else: status
  end

  defp failure(ip, reason), do: %{"address" => format_ip(ip), "reason" => format_reason(reason)}
  defp format_ip(ip), do: ip |> :inet.ntoa() |> List.to_string()

  defp format_reason(reason)
       when reason in [
              :eaddrinuse,
              :eaddrnotavail,
              :eacces,
              :dns_certificate_not_found,
              :invalid_dns_certificate,
              :dns_certificate_storage_failed,
              :udp_not_ready,
              :listener_unavailable
            ],
       do: Atom.to_string(reason)

  defp format_reason({:shutdown, {:failed_to_start_child, _, reason}}), do: format_reason(reason)
  defp format_reason({:stream_listener_exit, reason}), do: format_reason(reason)
  defp format_reason(_reason), do: "listener_failed"
end
