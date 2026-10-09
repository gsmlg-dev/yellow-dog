defmodule YellowDog.Worker.Credentials do
  @moduledoc false
  alias YellowDog.Worker.Bootstrap
  import Bitwise

  # Called exclusively by the LocalStore which owns the directory lock.
  def resolve(dir, url, ops) do
    path = Path.join(dir, "connection.toml")
    origin = url |> URI.parse() |> Map.put(:path, nil) |> URI.to_string()

    with true <- Bootstrap.valid_url?(url),
         :ok <- File.chmod(dir, 0o700) do
      case File.lstat(path) do
        {:error, :enoent} ->
          if Enum.all?(["current", "journal/transition.toml"], fn relative ->
               File.lstat(Path.join(dir, relative)) == {:error, :enoent}
             end) do
            create(dir, path, origin, ops)
          else
            {:error, :missing_credentials_for_existing_state}
          end

        {:ok, %{type: :regular, size: size, mode: mode}} when size <= 4096 ->
          with true <- band(mode, 0o777) == 0o600,
               {:ok, bytes} <- File.read(path),
               {:ok, credentials} <- decode(bytes, origin),
               :ok <- ops.sync_path(path),
               :ok <- ops.sync_path(dir) do
            {:ok, credentials}
          else
            {:error, :credential_origin_mismatch} = error -> error
            _ -> {:error, :invalid_credentials}
          end

        _ ->
          {:error, :invalid_credentials}
      end
    else
      _ -> {:error, :invalid_credentials}
    end
  rescue
    _ -> {:error, :credential_persistence_failed}
  catch
    _, _ -> {:error, :credential_persistence_failed}
  end

  defp create(dir, path, origin, ops) do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    uuid =
      <<a::32, b::16, bor(band(c, 0x0FFF), 0x4000)::16, bor(band(d, 0x3FFF), 0x8000)::16, e::48>>

    # UUID fields span 128 bits; format through standard hexadecimal groups.
    <<x::binary-size(8), y::binary-size(4), z::binary-size(4), w::binary-size(4),
      v::binary-size(12)>> = Base.encode16(uuid, case: :lower)

    credentials = %{
      worker_id: Enum.join([x, y, z, w, v], "-"),
      token: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    }

    bytes =
      "management_url = #{inspect(origin)}\nworker_id = #{inspect(credentials.worker_id)}\ntoken = #{inspect(credentials.token)}\n"

    temp =
      Path.join(dir, ".connection-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower))

    result =
      with :ok <- ops.write_private_synced(temp, bytes),
           {:ok, ^bytes} <- File.read(temp),
           :ok <- ops.sync_path(temp),
           :ok <- ops.rename(temp, path),
           :ok <- ops.sync_path(dir) do
        {:ok, credentials}
      else
        _ -> {:error, :credential_persistence_failed}
      end

    File.rm(temp)
    result
  end

  defp decode(bytes, origin) do
    with {:ok, config} <- Toml.decode(bytes),
         true <- Enum.sort(Map.keys(config)) == ~w(management_url token worker_id),
         true <-
           is_binary(config["worker_id"]) and
             Regex.match?(
               ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/,
               config["worker_id"]
             ),
         true <-
           is_binary(config["token"]) and Regex.match?(~r/\A[A-Za-z0-9_-]{43}\z/, config["token"]),
         {:ok, token_bytes} <- Base.url_decode64(config["token"], padding: false),
         true <- byte_size(token_bytes) == 32,
         true <- Base.url_encode64(token_bytes, padding: false) == config["token"],
         true <- config["management_url"] == origin do
      {:ok, %{worker_id: config["worker_id"], token: config["token"]}}
    else
      false ->
        case Toml.decode(bytes) do
          {:ok, %{"management_url" => other}} when other != origin ->
            {:error, :credential_origin_mismatch}

          _ ->
            {:error, :invalid_credentials}
        end

      _ ->
        {:error, :invalid_credentials}
    end
  end
end
