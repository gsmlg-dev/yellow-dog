defmodule YellowDog.Netboot.Asset.FileOps do
  @moduledoc false

  alias YellowDog.Netboot.Asset.ManagedAsset

  @chunk_size 65_536

  @spec move_verified(Path.t(), Path.t(), ManagedAsset.t(), keyword()) ::
          :ok | {:error, atom()}
  def move_verified(source, target, asset, opts \\ [])

  def move_verified(source, target, %ManagedAsset{} = asset, opts)
      when is_binary(source) and is_binary(target) and is_list(opts) do
    with :ok <- validate_transition(source, target),
         :ok <-
           with_verified_source(source, asset, fn identity ->
             with :ok <- invoke_before_transition(opts, source, target),
                  :ok <- rename_no_replace(source, target),
                  :ok <- verify_transition_target(target, identity, asset) do
               :ok
             end
           end) do
      :ok
    end
  end

  def move_verified(_source, _target, _asset, _opts), do: {:error, :invalid_options}

  @spec remove_verified(Path.t(), ManagedAsset.t(), keyword()) :: :ok | {:error, atom()}
  def remove_verified(path, asset, opts \\ [])

  def remove_verified(path, %ManagedAsset{} = asset, opts)
      when is_binary(path) and is_list(opts) do
    with_verified_source(path, asset, fn identity ->
      with :ok <- invoke_before_remove(opts, path),
           :ok <- verify_transition_target(path, identity, asset),
           :ok <- remove_path(path) do
        :ok
      end
    end)
  end

  def remove_verified(_path, _asset, _opts), do: {:error, :invalid_options}

  defp with_verified_source(path, asset, operation) do
    case File.lstat(path) do
      {:ok, %{type: :regular} = path_stat} ->
        with_open_source(path, path_stat, asset, operation)

      {:ok, _stat} ->
        {:error, :source_mismatch}

      {:error, :enoent} ->
        {:error, :source_missing}

      {:error, _reason} ->
        {:error, :source_mismatch}
    end
  end

  defp with_open_source(path, path_stat, asset, operation) do
    case File.open(path, [:read, :binary]) do
      {:ok, device} ->
        try do
          with {:ok, device_stat} <- device_stat(device),
               true <- same_identity?(path_stat, device_stat),
               :ok <- verify_device(device, device_stat, asset) do
            operation.(identity(device_stat))
          else
            false -> {:error, :source_changed}
            {:error, :source_mismatch} = error -> error
            {:error, _reason} -> {:error, :source_mismatch}
          end
        after
          File.close(device)
        end

      {:error, :enoent} ->
        {:error, :source_missing}

      {:error, _reason} ->
        {:error, :source_mismatch}
    end
  end

  defp verify_transition_target(path, expected_identity, asset) do
    case File.lstat(path) do
      {:ok, %{type: :regular} = path_stat} ->
        verify_open_target(path, path_stat, expected_identity, asset)

      _other ->
        {:error, :source_changed}
    end
  end

  defp verify_open_target(path, path_stat, expected_identity, asset) do
    case File.open(path, [:read, :binary]) do
      {:ok, device} ->
        try do
          with {:ok, device_stat} <- device_stat(device),
               true <- same_identity?(path_stat, device_stat),
               true <- identity(device_stat) == expected_identity,
               :ok <- verify_device(device, device_stat, asset),
               {:ok, final_stat} <- File.lstat(path),
               true <- same_identity?(device_stat, final_stat) do
            :ok
          else
            _failure -> {:error, :source_changed}
          end
        after
          File.close(device)
        end

      {:error, _reason} ->
        {:error, :source_changed}
    end
  end

  defp verify_device(device, stat, asset) do
    with true <- stat.type == :regular and stat.size == asset.size,
         {:ok, 0} <- :file.position(device, :bof),
         {:ok, digest} <- digest_device(device, :crypto.hash_init(:sha256)),
         true <- digest == asset.blob_digest do
      :ok
    else
      _failure -> {:error, :source_mismatch}
    end
  end

  defp digest_device(device, context) do
    case IO.binread(device, @chunk_size) do
      :eof ->
        {:ok, context |> :crypto.hash_final() |> Base.encode16(case: :lower)}

      data when is_binary(data) ->
        digest_device(device, :crypto.hash_update(context, data))

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp device_stat(device) do
    case :file.read_file_info(device) do
      {:ok, file_info} -> {:ok, File.Stat.from_record(file_info)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp identity(stat) do
    {stat.major_device, stat.minor_device, stat.inode}
  end

  defp same_identity?(left, right) do
    identity(left) == identity(right)
  end

  defp validate_transition(source, target) do
    same_directory? = Path.dirname(Path.expand(source)) == Path.dirname(Path.expand(target))

    if source != target and same_directory?,
      do: :ok,
      else: {:error, :invalid_transition}
  end

  defp invoke_before_transition(opts, source, target) do
    case Keyword.get(opts, :before_transition) do
      nil -> :ok
      callback when is_function(callback, 2) -> normalize_callback(callback.(source, target))
      _callback -> {:error, :invalid_options}
    end
  end

  defp invoke_before_remove(opts, path) do
    case Keyword.get(opts, :before_remove) do
      nil -> :ok
      callback when is_function(callback, 1) -> normalize_callback(callback.(path))
      _callback -> {:error, :invalid_options}
    end
  end

  defp normalize_callback(:ok), do: :ok
  defp normalize_callback({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp normalize_callback(_result), do: {:error, :invalid_options}

  defp rename_no_replace(source, target) do
    with {:unix, :linux} <- :os.type(),
         executable when is_binary(executable) <- System.find_executable("mv") do
      case System.cmd(
             executable,
             ["--update=none-fail", "--no-copy", "-T", "--", source, target],
             stderr_to_stdout: true
           ) do
        {_output, 0} -> :ok
        {_output, _status} -> transition_error(source, target)
      end
    else
      _unsupported -> {:error, :unsupported_transition}
    end
  rescue
    _exception -> {:error, :transition_failed}
  end

  defp transition_error(source, target) do
    case File.lstat(target) do
      {:ok, _stat} ->
        {:error, :target_exists}

      {:error, :enoent} ->
        if File.exists?(source),
          do: {:error, :transition_failed},
          else: {:error, :source_missing}

      {:error, _reason} ->
        {:error, :transition_failed}
    end
  end

  defp remove_path(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> {:error, :source_changed}
      {:error, _reason} -> {:error, :remove_failed}
    end
  end
end
