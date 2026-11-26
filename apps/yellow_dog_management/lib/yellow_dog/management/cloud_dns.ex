defmodule YellowDog.Management.CloudDns do
  @moduledoc "Explicit, reviewed synchronization between Management zones and cloud DNS."
  import Ecto.Changeset
  import Ecto.Query

  alias YellowDog.Management.{Access, Caller, Domain, Repo, Zone}
  alias YellowDog.Management.CloudDns.{Binding, Cloudflare, Provider, Records, Route53}

  @providers %{"route53" => Route53, "cloudflare" => Cloudflare}
  @timeout 120_000

  def list(caller) do
    with :ok <- Access.ui_admin(caller) do
      {:ok, Repo.all(from(b in Binding, order_by: b.inserted_at, preload: [:provider]))}
    end
  end

  def list(caller, zone_id) do
    with :ok <- Access.ui_admin(caller) do
      query =
        case zone_id do
          nil -> from(b in Binding, where: is_nil(b.zone_id))
          id -> from(b in Binding, where: b.zone_id == ^id)
        end

      {:ok, Repo.all(from(b in query, order_by: b.inserted_at, preload: [:provider]))}
    end
  end

  def synced_zone?(caller, zone_id) do
    Access.ui_admin(caller) == :ok and
      Repo.exists?(from(b in Binding, where: b.zone_id == ^zone_id))
  end

  def zones(caller) do
    with :ok <- Access.ui_admin(caller) do
      {:ok,
       Repo.all(
         from(z in Zone,
           where: is_nil(z.deleted_at),
           order_by: z.name,
           select: %{id: z.id, name: z.name}
         )
       )}
    end
  end

  def providers(caller) do
    with :ok <- Access.ui_admin(caller) do
      {:ok,
       Repo.all(
         from(p in Provider,
           as: :provider,
           order_by: [p.name, p.kind, p.id],
           select: struct(p, [:id, :name, :kind, :profile, :inserted_at, :updated_at]),
           select_merge: %{
             bound?: exists(from(b in Binding, where: b.provider_id == parent_as(:provider).id))
           }
         )
       )}
    end
  end

  def remote_zones(caller, provider_id) do
    with :ok <- Access.ui_admin(caller),
         {:ok, id} <- parse_id(provider_id),
         %Provider{} = provider <- Repo.get(Provider, id),
         {:ok, credentials} <- credentials(provider),
         {:ok, zones} <- adapter(provider).list_zones(credentials) do
      {:ok, Enum.sort_by(zones, &{&1.name, &1.id})}
    else
      nil -> {:error, :provider_not_found}
      error -> error
    end
  end

  def add_provider(caller, attrs) do
    with :ok <- Access.ui_admin(caller) do
      %Provider{} |> Provider.changeset(attrs) |> Repo.insert(log: false)
    end
  end

  def update_provider(caller, %Provider{} = selected, attrs) do
    with :ok <- Access.ui_admin(caller) do
      Repo.transact(fn ->
        case Repo.one(from(p in Provider, where: p.id == ^selected.id, lock: "FOR UPDATE")) do
          %Provider{updated_at: updated_at} = provider when updated_at == selected.updated_at ->
            changeset = Provider.changeset(provider, attrs)

            profile_changed? =
              changed?(changeset, :profile) and not is_nil(get_field(changeset, :profile))

            if (changed?(changeset, :kind) or profile_changed?) and
                 Repo.exists?(from(b in Binding, where: b.provider_id == ^provider.id)) do
              {:error, :provider_in_use}
            else
              Repo.update(changeset, log: false)
            end

          _ ->
            {:error, :stale_provider}
        end
      end)
    end
  end

  def delete_provider(caller, id) do
    with :ok <- Access.ui_admin(caller),
         {:ok, id} <- parse_id(id),
         %Provider{} = provider <- Repo.get(Provider, id) do
      provider
      |> change()
      |> no_assoc_constraint(:bindings)
      |> Repo.delete()
    else
      nil -> {:error, :provider_not_found}
      error -> error
    end
  end

  def add(caller, %{"provider_id" => provider_id} = params) do
    with :ok <- Access.ui_admin(caller),
         {:ok, id} <- parse_id(provider_id) do
      Repo.transact(fn ->
        with %Provider{} = provider <-
               Repo.one(from(p in Provider, where: p.id == ^id, lock: "FOR SHARE")),
             {:ok, attrs} <- binding_attrs(provider, params),
             {:ok, binding} <-
               %Binding{}
               |> change(attrs)
               |> put_assoc(:provider, provider)
               |> unique_constraint([:provider_id, :remote_id])
               |> unique_constraint([:provider_id, :zone_id],
                 name: :management_cloud_dns_pending_zone
               )
               |> Repo.insert() do
          {:ok, binding}
        else
          nil -> {:error, :provider_not_found}
          error -> error
        end
      end)
    end
  end

  def add(_caller, _params), do: {:error, :provider_not_found}

  def unlink(caller, id) do
    locked(caller, id, fn binding ->
      with {:ok, _binding} <- Repo.delete(binding), do: {:ok, :unlinked}
    end)
  end

  def create_remote(caller, id) do
    locked(caller, id, fn
      %Binding{remote_id: nil, zone_id: zone_id} = binding ->
        with {:ok, %{"name" => name}} <- zone_by_id(zone_id, true),
             :ok <- serialize_creation(binding.provider.kind, name),
             {:ok, credentials} <- credentials(binding),
             :ok <- Access.ui_admin(caller),
             {:ok, remote_id} <- adapter(binding).create_zone(name, credentials, binding.id),
             {:ok, %{name: ^name} = remote} <- adapter(binding).fetch(remote_id, credentials),
             :ok <- empty_cloud_zone(remote) do
          save_baseline(binding, %{}, remote_id: remote_id)
        else
          {:ok, _wrong_zone} -> {:error, :zone_name_mismatch}
          error -> error
        end

      _ ->
        {:error, :already_linked}
    end)
  end

  def preview(caller, id, direction) when direction in [:pull, :push] do
    with :ok <- Access.ui_admin(caller),
         {:ok, binding} <- get_binding(id),
         {:ok, context} <- snapshot(binding, direction, false) do
      review(context, direction)
    end
  end

  def confirm(caller, id, direction, stamp, choices \\ %{}) when direction in [:pull, :push] do
    locked(caller, id, fn binding ->
      with {:ok, context} <- snapshot(binding, direction, true),
           {:ok, %{stamp: ^stamp} = review} <- review(context, direction),
           :ok <- Access.ui_admin(caller) do
        execute(direction, caller, context, review, choices)
      else
        {:ok, _changed} -> {:error, :stale_preview}
        error -> error
      end
    end)
  end

  defp locked(caller, id, fun) do
    with :ok <- Access.ui_admin(caller),
         {:ok, id} <- parse_id(id) do
      Repo.transaction(
        fn ->
          case Repo.one(from(b in Binding, where: b.id == ^id, lock: "FOR UPDATE")) do
            nil ->
              Repo.rollback(:binding_not_found)

            binding ->
              case fun.(Repo.preload(binding, :provider)) do
                {:ok, result} -> result
                {:error, reason} -> Repo.rollback(reason)
              end
          end
        end,
        timeout: @timeout
      )
    end
  end

  defp get_binding(id) do
    with {:ok, id} <- parse_id(id),
         %Binding{} = row <- Repo.get(Binding, id) do
      {:ok, Repo.preload(row, :provider)}
    else
      _ -> {:error, :binding_not_found}
    end
  end

  defp binding_attrs(%Provider{kind: kind}, %{"mode" => "import"} = attrs) do
    remote_id = attrs["remote_id"] || ""

    if valid_remote_id?(kind, remote_id) do
      with {:ok, zone_id} <- optional_zone(attrs["zone_id"]) do
        {:ok, %{remote_id: canonical_id(kind, remote_id), zone_id: zone_id}}
      end
    else
      {:error, :invalid_remote_zone_id}
    end
  end

  defp binding_attrs(_provider, %{"mode" => "create"} = attrs) do
    with {:ok, %{"id" => zone_id}} <- zone_by_id(attrs["zone_id"], false) do
      {:ok, %{zone_id: zone_id}}
    end
  end

  defp binding_attrs(_provider, _), do: {:error, :invalid_binding}

  defp optional_zone(id) when id in [nil, ""], do: {:ok, nil}

  defp optional_zone(id) do
    with {:ok, %{"id" => zone_id}} <- zone_by_id(id, false), do: {:ok, zone_id}
  end

  defp valid_remote_id?("route53", id) when is_binary(id),
    do: Regex.match?(~r/^(?:\/hostedzone\/)?Z[A-Z0-9]{1,31}$/, id)

  defp valid_remote_id?("cloudflare", id) when is_binary(id),
    do: Regex.match?(~r/^[0-9a-fA-F]{32}$/, id)

  defp valid_remote_id?(_, _), do: false
  defp canonical_id("route53", id), do: String.replace_prefix(id, "/hostedzone/", "")
  defp canonical_id("cloudflare", id), do: String.downcase(id)

  defp parse_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_id}
    end
  end

  defp serialize_creation(provider, name) do
    case Repo.query("SELECT pg_advisory_xact_lock(hashtext($1))", [
           "cloud-dns:#{provider}:#{name}"
         ]) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :database_unavailable}
    end
  end

  defp empty_cloud_zone(%{name: name, rrsets: rrsets}) do
    if Enum.all?(Map.keys(rrsets), &(&1 in [{name, "SOA"}, {name, "NS"}])),
      do: :ok,
      else: {:error, :remote_zone_not_empty}
  end

  defp zone_by_id(id, lock?) do
    with {:ok, id} <- parse_id(id),
         %Zone{} <- zone_row(from(z in Zone, where: z.id == ^id), lock?) do
      Domain.get_zone(id)
    else
      _ -> {:error, :local_zone_not_found}
    end
  end

  defp zone_row(query, true),
    do: Repo.one(from(z in query, where: is_nil(z.deleted_at), lock: "FOR UPDATE"))

  defp zone_row(query, false), do: Repo.one(from(z in query, where: is_nil(z.deleted_at)))

  defp local_zone(%Binding{zone_id: nil}, name, lock?) do
    case zone_row(from(z in Zone, where: z.name == ^name), lock?) do
      %Zone{id: id} -> Domain.get_zone(id)
      nil -> {:ok, nil}
    end
  end

  defp local_zone(%Binding{zone_id: id}, name, lock?) do
    case zone_by_id(id, lock?) do
      {:ok, %{"name" => ^name} = zone} -> {:ok, zone}
      {:ok, _renamed} -> {:error, :zone_name_mismatch}
      error -> error
    end
  end

  defp snapshot(%Binding{remote_id: nil}, _direction, _lock?), do: {:error, :create_remote_first}

  defp snapshot(binding, direction, lock?) do
    with {:ok, credentials} <- credentials(binding),
         {:ok, remote} <- adapter(binding).fetch(binding.remote_id, credentials),
         {:ok, remote_records} <- Records.remote(remote),
         {:ok, zone} <- local_zone(binding, remote.name, lock?),
         {:ok, source} <- source(direction, binding, zone),
         {:ok, apex} <- apex(direction, binding, remote, zone) do
      {:ok,
       %{
         binding: binding,
         remote: remote,
         remote_records: remote_records,
         protected: Records.protected(remote),
         zone: zone,
         local_records: Records.local(remote.name, source),
         credentials: credentials,
         base: Records.load(if(binding.baseline, do: binding.baseline["records"], else: [])),
         apex: apex
       }}
    end
  end

  defp source(:pull, _binding, nil), do: {:ok, []}
  defp source(:pull, _binding, zone), do: {:ok, zone["records"]}
  defp source(:push, %Binding{baseline: nil}, _zone), do: {:error, :pull_first}
  defp source(:push, _binding, nil), do: {:error, :local_zone_not_found}

  defp source(:push, _binding, zone) do
    case Enum.find(Domain.list_versions(zone["id"]), &(&1["source_revision"] == zone["revision"])) do
      nil -> {:error, :confirm_local_version}
      version -> {:ok, version["content"]["records"]}
    end
  end

  defp apex(:push, _binding, _remote, _zone), do: {:ok, []}

  defp apex(:pull, %Binding{baseline: nil}, remote, _zone), do: Records.apex(remote)

  defp apex(:pull, _binding, _remote, zone) do
    {:ok,
     Enum.filter(
       zone["records"],
       &(not Records.editable?(zone["name"], {&1["name"], &1["type"]}))
     )}
  end

  defp review(context, direction) do
    %{binding: binding, base: base, local_records: local, remote_records: remote} = context

    rows =
      (Map.keys(base) ++ Map.keys(local) ++ Map.keys(remote))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.flat_map(fn key ->
        before = base[key]
        here = local[key]
        there = remote[key]

        state =
          cond do
            MapSet.member?(context.protected, key) -> :protected
            here == there -> :same
            direction == :pull and is_nil(binding.baseline) -> :cloud_change
            here == before -> :cloud_change
            there == before -> :local_change
            true -> :conflict
          end

        if state == :same, do: [], else: [%{key: key, local: here, remote: there, state: state}]
      end)

    stamp =
      {binding.id, binding.remote_id, binding.baseline, binding.provider.updated_at, context.zone,
       context.remote, direction}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    {:ok,
     %{
       stamp: stamp,
       rows: rows,
       name: context.remote.name,
       zone_id: context.zone && context.zone["id"],
       initial?: is_nil(binding.baseline),
       protected: Enum.sort(context.protected),
       blocked?:
         direction == :push and
           Enum.any?(rows, &(&1.state in [:cloud_change, :conflict]))
     }}
  end

  defp execute(:pull, caller, context, review, selections) do
    local =
      if review.initial?,
        do: Map.drop(context.local_records, MapSet.to_list(context.protected)),
        else: context.local_records

    with {:ok, merged} <- merge_pull(review.rows, local, selections),
         {:ok, records} <- Records.to_records(merged),
         {:ok, zone} <- save_zone(caller, context, records ++ context.apex) do
      save_baseline(context.binding, context.remote_records, zone_id: zone["id"])
    end
  end

  defp execute(:push, _caller, _context, %{blocked?: true}, _selections),
    do: {:error, :pull_first}

  defp execute(:push, _caller, context, review, _selections) do
    %{binding: binding, credentials: credentials, remote: remote, local_records: local} = context

    changes =
      for %{key: key, state: :local_change} <- review.rows do
        %{key: key, before: remote.rrsets[key], after: local[key]}
      end

    expected = Map.drop(local, MapSet.to_list(context.protected))

    with :ok <- apply_changes(binding, credentials, changes),
         {:ok, remote} <- verified_cloud(binding, credentials, expected, changes) do
      save_baseline(binding, remote, [])
    end
  end

  defp apply_changes(_binding, _credentials, []), do: :ok

  defp apply_changes(binding, credentials, changes),
    do: adapter(binding).apply(binding.remote_id, credentials, changes)

  defp verified_cloud(_binding, _credentials, local, []), do: {:ok, local}

  defp verified_cloud(binding, credentials, local, _changes) do
    with {:ok, observed} <- adapter(binding).fetch(binding.remote_id, credentials),
         {:ok, ^local} <- Records.remote(observed) do
      {:ok, local}
    else
      _ -> {:error, :cloud_write_unverified}
    end
  end

  defp merge_pull(rows, local, selections) do
    Enum.reduce_while(Enum.with_index(rows), {:ok, local}, fn {row, index}, {:ok, merged} ->
      case {row.state, Map.get(selections, Integer.to_string(index))} do
        {:cloud_change, _} -> {:cont, {:ok, put_rrset(merged, row.key, row.remote)}}
        {:conflict, "remote"} -> {:cont, {:ok, put_rrset(merged, row.key, row.remote)}}
        {:conflict, "local"} -> {:cont, {:ok, merged}}
        {:conflict, _} -> {:halt, {:error, :resolve_conflicts}}
        {_, _} -> {:cont, {:ok, merged}}
      end
    end)
  end

  defp put_rrset(records, key, nil), do: Map.delete(records, key)
  defp put_rrset(records, key, rrset), do: Map.put(records, key, rrset)

  defp save_zone(caller, %{zone: nil, remote: remote}, records),
    do: mutate_zone(caller, "create_zone", %{"name" => remote.name, "records" => records})

  defp save_zone(caller, %{zone: zone}, records) do
    if Enum.sort(records) == Enum.sort(zone["records"]) do
      {:ok, zone}
    else
      mutate_zone(caller, "update_zone", %{
        "id" => zone["id"],
        "expected_revision" => zone["revision"],
        "name" => zone["name"],
        "records" => records
      })
    end
  end

  defp mutate_zone(caller, operation, params) do
    Domain.mutate(operation, params, Caller.actor(caller), Ecto.UUID.generate(),
      caller: caller,
      scope: "ui:admin"
    )
  end

  defp save_baseline(binding, records, attrs) do
    binding
    |> change(
      attrs ++ [baseline: %{"records" => Records.dump(records)}, synced_at: DateTime.utc_now()]
    )
    |> unique_constraint([:provider_id, :remote_id])
    |> Repo.update()
  end

  defp adapter(%Binding{provider: provider}), do: adapter(provider)

  defp adapter(%Provider{kind: kind}) do
    adapters = Application.get_env(:yellow_dog_management, :cloud_dns_adapters, @providers)
    Map.fetch!(adapters, kind)
  end

  defp credentials(%Binding{provider: provider}), do: credentials(provider)

  defp credentials(%Provider{credentials: credentials})
       when is_map(credentials),
       do: {:ok, credentials}

  defp credentials(%Provider{kind: "route53", profile: profile}) do
    with {:ok, key} <- env(profile, "AWS_ACCESS_KEY_ID"),
         {:ok, secret} <- env(profile, "AWS_SECRET_ACCESS_KEY") do
      {:ok,
       %{
         "access_key_id" => key,
         "secret_access_key" => secret,
         "session_token" => System.get_env(profile <> "_AWS_SESSION_TOKEN")
       }}
    end
  end

  defp credentials(%Provider{kind: "cloudflare", profile: profile}) do
    with {:ok, token} <- env(profile, "CLOUDFLARE_API_TOKEN") do
      {:ok,
       %{
         "api_token" => token,
         "account_id" => System.get_env(profile <> "_CLOUDFLARE_ACCOUNT_ID")
       }}
    end
  end

  defp env(profile, key) do
    case System.get_env(profile <> "_" <> key) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, :missing_credentials}
    end
  end
end
