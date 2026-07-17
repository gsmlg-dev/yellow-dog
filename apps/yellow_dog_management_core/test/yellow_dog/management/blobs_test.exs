defmodule YellowDog.Management.BlobsTest do
  use ExUnit.Case, async: false

  alias YellowDog.Management.Storage.Path, as: StoragePath
  alias YellowDog.ManagementCore

  setup do
    previous_data_dir = Application.get_env(:yellow_dog_management_core, :data_dir)

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-management-blobs-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:yellow_dog_management_core, :data_dir, data_dir)

    on_exit(fn ->
      restore_data_dir(previous_data_dir)
      File.rm_rf(data_dir)
    end)

    :ok
  end

  test "reads content only when its canonical digest matches" do
    content = "netboot asset"
    digest = sha256(content)
    write_blob!(digest, content)

    assert {:ok, %{digest: ^digest, path: path, size: 13}} =
             ManagementCore.get_blob(digest, 1024)

    assert File.read!(path) == content
  end

  test "rejects malformed and mismatched digests without exposing paths" do
    assert {:error, %{code: :invalid, details: %{}}} =
             ManagementCore.get_blob("../asset", 1024)

    digest = sha256("expected")
    write_blob!(digest, "different")

    assert {:error,
            %{
              code: :invalid,
              message: "blob digest verification failed",
              details: %{"reason" => "digest_mismatch"}
            }} = ManagementCore.get_blob(digest, 1024)
  end

  test "distinguishes missing and oversized blobs with bounded errors" do
    digest = sha256("missing")

    assert {:error, %{code: :not_found, message: "blob was not found", details: %{}}} =
             ManagementCore.get_blob(digest, 1024)

    content = "too large"
    digest = sha256(content)
    write_blob!(digest, content)

    assert {:error,
            %{
              code: :invalid,
              message: "blob exceeds configured size limit",
              details: %{"reason" => "too_large"}
            }} = ManagementCore.get_blob(digest, 4)
  end

  test "rejects invalid size limits" do
    digest = sha256("content")

    assert {:error,
            %{
              code: :invalid,
              message: "invalid blob size limit",
              details: %{"reason" => "invalid_limit"}
            }} = ManagementCore.get_blob(digest, 0)
  end

  test "accepts empty and exact-limit blobs" do
    empty_digest = sha256("")
    write_blob!(empty_digest, "")

    assert {:ok, %{digest: ^empty_digest, size: 0}} =
             ManagementCore.get_blob(empty_digest, 1)

    content = "1234"
    digest = sha256(content)
    write_blob!(digest, content)

    assert {:ok, %{digest: ^digest, size: 4}} = ManagementCore.get_blob(digest, 4)
  end

  test "rejects symbolic links even when their target matches the digest" do
    content = "linked content"
    digest = sha256(content)
    {:ok, path} = StoragePath.blob(digest)
    target = path <> ".source"

    File.mkdir_p!(Path.dirname(path))
    File.write!(target, content)
    File.ln_s!(target, path)

    assert {:error,
            %{
              code: :invalid,
              message: "invalid blob file",
              details: %{"reason" => "invalid_file"}
            }} = ManagementCore.get_blob(digest, 1024)
  end

  defp write_blob!(digest, content) do
    {:ok, path} = StoragePath.blob(digest)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp sha256(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end

  defp restore_data_dir(nil), do: Application.delete_env(:yellow_dog_management_core, :data_dir)

  defp restore_data_dir(value),
    do: Application.put_env(:yellow_dog_management_core, :data_dir, value)
end
