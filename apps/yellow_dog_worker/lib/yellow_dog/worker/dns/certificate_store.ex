defmodule YellowDog.Worker.Dns.CertificateStore do
  @moduledoc false
  import Bitwise
  require Record

  Record.defrecordp(
    :otp_certificate,
    :OTPCertificate,
    Record.extract(:OTPCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :tbs_certificate,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  @id ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/
  @max_pem_bytes 65_536
  @max_revision 2_147_483_647
  @max_file_bytes 4 * @max_pem_bytes
  @key_types [:RSAPrivateKey, :ECPrivateKey, :PrivateKeyInfo]

  # LocalStore serializes writes under the Worker data directory lock.
  def install(data_dir, %{"id" => id, "revision" => rev} = payload, ops) do
    directory = directory(data_dir)

    with true <- valid_id?(id) and valid_revision?(rev),
         {:ok, revisions} <- revisions(directory, id) do
      case revisions do
        [latest | _] when latest > rev ->
          {:ok, :stale}

        [^rev | _] ->
          case read_payload(directory, id, rev) do
            {:ok, ^payload} ->
              case ops.sync_path(directory) do
                :ok -> {:ok, :current}
                _ -> {:error, :dns_certificate_storage_failed}
              end

            {:ok, _} ->
              {:error, :invalid_dns_certificate}

            {:error, _} = error ->
              error
          end

        _ ->
          with {:ok, _} <- decode(payload) do
            write(data_dir, directory, id, rev, payload, ops)
          end
      end
    else
      false -> {:error, :invalid_dns_certificate}
      {:error, _} -> {:error, :dns_certificate_storage_failed}
    end
  end

  def install(_data_dir, _payload, _ops), do: {:error, :invalid_dns_certificate}

  def latest(data_dir, id) do
    directory = directory(data_dir)

    with true <- valid_id?(id),
         {:ok, [revision | _]} <- revisions(directory, id) do
      fetch(data_dir, id, revision)
    else
      {:ok, []} -> {:error, :dns_certificate_not_found}
      _ -> {:error, :dns_certificate_storage_failed}
    end
  end

  def fetch(data_dir, id, revision) do
    directory = directory(data_dir)

    with true <- valid_id?(id) and valid_revision?(revision),
         {:ok, %{type: :directory}} <- File.lstat(directory),
         {:ok, payload} <- read_payload(directory, id, revision),
         do: decode(payload),
         else: (_ -> {:error, :dns_certificate_not_found})
  end

  def available_revisions(data_dir, id) do
    if valid_id?(id),
      do: revisions(directory(data_dir), id),
      else: {:error, :invalid_dns_certificate}
  end

  defp directory(data_dir), do: Path.join(data_dir, "dns-certificates")
  defp path(directory, id, revision), do: Path.join(directory, "#{id}.#{revision}.json")

  defp revisions(directory, id) do
    case File.lstat(directory) do
      {:ok, %{type: :directory}} ->
        prefix = id <> "."

        with {:ok, files} <- File.ls(directory) do
          revisions =
            for name <- files,
                String.starts_with?(name, prefix),
                suffix = String.replace_prefix(name, prefix, ""),
                {revision, ".json"} <- [Integer.parse(suffix)],
                valid_revision?(revision),
                do: revision

          {:ok, Enum.sort(revisions, :desc)}
        end

      {:error, :enoent} ->
        {:ok, []}

      _ ->
        {:error, :invalid_directory}
    end
  end

  defp write(data_dir, directory, id, revision, payload, ops) do
    name = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    temporary = Path.join(directory, ".incoming-" <> name)

    result =
      with :ok <- File.mkdir_p(directory),
           :ok <- File.chmod(directory, 0o700),
           :ok <- ops.sync_path(data_dir),
           :ok <- ops.write_private_synced(temporary, Jason.encode!(payload)),
           :ok <- ops.rename(temporary, path(directory, id, revision)),
           :ok <- ops.sync_path(directory) do
        {:ok, :stored}
      else
        _ -> {:error, :dns_certificate_storage_failed}
      end

    File.rm(temporary)
    result
  end

  defp read_payload(directory, id, revision) do
    file = path(directory, id, revision)

    with {:ok, %{type: :regular, size: size, mode: mode}}
         when size <= @max_file_bytes and band(mode, 0o777) == 0o600 <- File.lstat(file),
         {:ok, bytes} <- File.read(file),
         {:ok, %{"id" => ^id, "revision" => ^revision} = payload} <- Jason.decode(bytes) do
      {:ok, payload}
    else
      _ -> {:error, :dns_certificate_storage_failed}
    end
  end

  defp decode(
         %{
           "id" => id,
           "revision" => rev,
           "certificate_pem" => chain,
           "private_key_pem" => private_key
         } = payload
       )
       when map_size(payload) == 4 and is_binary(chain) and is_binary(private_key) and
              byte_size(chain) <= @max_pem_bytes and byte_size(private_key) <= @max_pem_bytes do
    with [{:Certificate, leaf, :not_encrypted} | _] = entries <- :public_key.pem_decode(chain),
         true <- Enum.all?(entries, &valid_certificate?/1),
         [{type, der, :not_encrypted} = entry] when type in @key_types <-
           :public_key.pem_decode(private_key),
         true <- key_matches?(leaf, :public_key.pem_entry_decode(entry)) do
      {:ok, %{id: id, revision: rev, certs: Enum.map(entries, &elem(&1, 1)), key: {type, der}}}
    else
      _ -> {:error, :invalid_dns_certificate}
    end
  rescue
    _ -> {:error, :invalid_dns_certificate}
  end

  defp decode(_), do: {:error, :invalid_dns_certificate}

  defp valid_certificate?({:Certificate, der, :not_encrypted}) do
    match?(otp_certificate(), :public_key.pkix_decode_cert(der, :otp))
  end

  defp valid_certificate?(_), do: false

  defp key_matches?(leaf, key) do
    otp_certificate(tbsCertificate: tbs_certificate(subjectPublicKeyInfo: info)) =
      :public_key.pkix_decode_cert(leaf, :otp)

    {public, digest} = verification_key(info)
    challenge = "Yellow Dog DNS certificate key check"
    :public_key.verify(challenge, digest, :public_key.sign(challenge, digest, key), public)
  end

  defp verification_key({:OTPSubjectPublicKeyInfo, _, {:RSAPublicKey, _, _} = key}),
    do: {key, :sha256}

  defp verification_key(
         {:OTPSubjectPublicKeyInfo, {:PublicKeyAlgorithm, oid, parameters}, {:ECPoint, _} = key}
       ) do
    case oid do
      algorithm when algorithm in [{1, 3, 101, 112}, {1, 3, 101, 113}] ->
        {{key, {:namedCurve, algorithm}}, :none}

      _ ->
        {{key, parameters}, :sha256}
    end
  end

  defp valid_id?(id), do: is_binary(id) and Regex.match?(@id, id)
  defp valid_revision?(rev), do: is_integer(rev) and rev in 1..@max_revision
end
