defmodule YellowDog.Management.Storage.Path do
  @moduledoc """
  Concrete, validated paths for management durable storage.
  """

  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Error

  @max_domain_bytes 253
  @max_version 9_223_372_036_854_775_807
  @event_id ~r/\Aevt-[1-9][0-9]*\z/
  @request_id ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @domain_label ~r/\A(?:[a-z0-9]|[a-z0-9](?:[a-z0-9-]*[a-z0-9])?|_[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)\z/

  @type result :: {:ok, String.t()} | {:error, Error.t()}

  @spec root() :: result()
  def root do
    data_dir =
      Application.get_env(:yellow_dog_management_core, :data_dir) ||
        YellowDog.Config.get_data_dir()

    if is_binary(data_dir) and data_dir != "" do
      {:ok, Path.join(data_dir, "management")}
    else
      invalid()
    end
  rescue
    _exception -> internal()
  end

  @spec server_manifest(term()) :: result()
  def server_manifest(server_id), do: manifest("servers", server_id)

  @spec server_version(term(), term(), term()) :: result()
  def server_version(server_id, version, digest),
    do: version("servers", server_id, version, digest)

  @spec netman_manifest(term()) :: result()
  def netman_manifest(netman_id), do: manifest("netmans", netman_id)

  @spec netman_version(term(), term(), term()) :: result()
  def netman_version(netman_id, version, digest),
    do: version("netmans", netman_id, version, digest)

  @spec command(term()) :: result()
  def command(request_id) do
    with {:ok, request_id} <- request_id(request_id),
         {:ok, root} <- root() do
      {:ok, Path.join([root, "commands", "#{request_id}.json"])}
    end
  end

  @spec event(term()) :: result()
  def event(event_id) do
    with {:ok, event_id} <- event_id(event_id),
         {:ok, root} <- root() do
      {:ok, Path.join([root, "events", "#{event_id}.json"])}
    end
  end

  @spec server_snapshot(term(), term()) :: result()
  def server_snapshot(server_id, domain), do: snapshot("servers", server_id, domain)

  @spec netman_snapshot(term(), term()) :: result()
  def netman_snapshot(netman_id, domain), do: snapshot("netmans", netman_id, domain)

  @spec blob(term()) :: result()
  def blob(digest) do
    with {:ok, digest} <- Digest.validate(digest),
         {:ok, root} <- root() do
      {:ok, Path.join([root, "blobs", digest])}
    end
  end

  defp manifest(target_directory, target_id) do
    with {:ok, target_id} <- identifier(target_id),
         {:ok, root} <- root() do
      {:ok, Path.join([root, target_directory, target_id, "manifest.json"])}
    end
  end

  defp version(target_directory, target_id, version, digest) do
    with {:ok, target_id} <- identifier(target_id),
         {:ok, version} <- version_number(version),
         {:ok, digest} <- Digest.validate(digest),
         {:ok, root} <- root() do
      {:ok,
       Path.join([
         root,
         target_directory,
         target_id,
         "versions",
         "#{version}-#{digest}.json"
       ])}
    end
  end

  defp snapshot(target_directory, target_id, domain) do
    with {:ok, target_id} <- identifier(target_id),
         {:ok, domain} <- domain(domain),
         {:ok, root} <- root() do
      {:ok, Path.join([root, "snapshots", target_directory, target_id, "#{domain}.json"])}
    end
  end

  defp identifier(value) do
    with {:ok, value} <- Bounds.id(value),
         :ok <- path_segment(value) do
      {:ok, value}
    else
      _error -> invalid()
    end
  end

  defp request_id(value) do
    with {:ok, value} <- Bounds.id(value),
         :ok <- path_segment(value),
         true <- Regex.match?(@request_id, value) do
      {:ok, value}
    else
      _error -> invalid()
    end
  end

  defp event_id(value) do
    with {:ok, value} <- Bounds.id(value),
         :ok <- path_segment(value),
         true <- Regex.match?(@event_id, value) do
      {:ok, value}
    else
      _error -> invalid()
    end
  end

  defp version_number(value) when is_integer(value) and value >= 0 and value <= @max_version,
    do: {:ok, value}

  defp version_number(_value), do: invalid()

  defp domain(value) when is_binary(value) and byte_size(value) <= @max_domain_bytes do
    with :ok <- path_segment(value),
         true <- value == String.downcase(value),
         labels <- String.split(value, "."),
         true <- Enum.all?(labels, &valid_domain_label?/1) do
      {:ok, value}
    else
      _error -> invalid()
    end
  end

  defp domain(_value), do: invalid()

  defp valid_domain_label?(label) when byte_size(label) in 1..63,
    do: Regex.match?(@domain_label, label)

  defp valid_domain_label?(_label), do: false

  defp path_segment(value) do
    with true <- value != "",
         true <- value not in [".", ".."],
         true <- String.valid?(value),
         {:ok, normalized} <- nfkc(value),
         true <- normalized == value,
         false <- Regex.match?(~r/\p{C}/u, value),
         false <- String.contains?(value, ["/", "\\"]),
         false <- Regex.match?(~r/\A[A-Za-z]:/, value) do
      :ok
    else
      _error -> :error
    end
  end

  defp nfkc(value) do
    case :unicode.characters_to_nfkc_binary(value) do
      normalized when is_binary(normalized) -> {:ok, normalized}
      _other -> :error
    end
  rescue
    _exception -> :error
  end

  defp invalid, do: {:error, Error.new(:invalid, "invalid storage path component", %{})}
  defp internal, do: {:error, Error.new(:internal, "storage root unavailable", %{})}
end
