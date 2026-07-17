defmodule YellowDog.Console.ManagementBlobControllerTest do
  use YellowDog.Console.ConnCase, async: false

  alias YellowDog.Console.ManagementBlobController
  alias YellowDog.Management.Storage.Path, as: StoragePath

  @token "management-blob-test-token"
  @max_blob_bytes 1_024

  defmodule SendFileCaptureAdapter do
    def send_file(payload, _status, _headers, path, offset, length) do
      {:ok, {:file, path, offset, length}, payload}
    end
  end

  setup do
    data_dir =
      Path.join(
        System.tmp_dir!(),
        "management_blob_controller_#{System.unique_integer([:positive])}"
      )

    previous_data_dir = Application.get_env(:yellow_dog_management_core, :data_dir)
    previous_token = Application.get_env(:yellow_dog_console, :management_token)
    previous_limit = Application.get_env(:yellow_dog_console, :management_blob_max_bytes)
    previous_management_only = Application.get_env(:yellow_dog_console, :management_release_only)

    Application.put_env(:yellow_dog_management_core, :data_dir, data_dir)
    Application.put_env(:yellow_dog_console, :management_token, @token)
    Application.put_env(:yellow_dog_console, :management_blob_max_bytes, @max_blob_bytes)
    Application.put_env(:yellow_dog_console, :management_release_only, true)

    on_exit(fn ->
      File.rm_rf!(data_dir)
      restore_env(:yellow_dog_management_core, :data_dir, previous_data_dir)
      restore_env(:yellow_dog_console, :management_token, previous_token)
      restore_env(:yellow_dog_console, :management_blob_max_bytes, previous_limit)
      restore_env(:yellow_dog_console, :management_release_only, previous_management_only)
    end)

    %{data_dir: data_dir}
  end

  describe "GET /management/blobs/:sha256" do
    test "rejects missing and incorrect bearer tokens", %{conn: conn} do
      digest = sha256("asset")

      assert conn
             |> get("/management/blobs/#{digest}")
             |> response(401) == "Unauthorized"

      assert conn
             |> put_req_header("authorization", "Bearer wrong-token")
             |> get("/management/blobs/#{digest}")
             |> response(401) == "Unauthorized"
    end

    test "rejects duplicate, empty, and unconfigured bearer tokens", %{conn: conn} do
      digest = sha256("asset")

      duplicate_headers = [
        {"authorization", "Bearer #{@token}"},
        {"authorization", "Bearer #{@token}"}
      ]

      assert %{conn | req_headers: duplicate_headers}
             |> get("/management/blobs/#{digest}")
             |> response(401) == "Unauthorized"

      assert conn
             |> put_req_header("authorization", "Bearer ")
             |> get("/management/blobs/#{digest}")
             |> response(401) == "Unauthorized"

      Application.delete_env(:yellow_dog_console, :management_token)

      assert conn
             |> authorize()
             |> get("/management/blobs/#{digest}")
             |> response(401) == "Unauthorized"
    end

    test "rejects a malformed digest", %{conn: conn} do
      body =
        conn
        |> authorize()
        |> get("/management/blobs/#{String.duplicate("A", 64)}")
        |> response(400)

      assert body == "Bad Request"
      refute body =~ "management"
    end

    test "returns a generic response for a missing blob", %{conn: conn, data_dir: data_dir} do
      body =
        conn
        |> authorize()
        |> get("/management/blobs/#{sha256("missing")}")
        |> response(404)

      assert body == "Not Found"
      refute body =~ data_dir
    end

    test "rejects a blob whose content length exceeds the configured limit", %{conn: conn} do
      contents = :binary.copy(<<0>>, @max_blob_bytes + 1)
      digest = put_blob(contents)

      assert conn
             |> authorize()
             |> get("/management/blobs/#{digest}")
             |> response(413) == "Payload Too Large"
    end

    test "does not serve a blob whose contents do not match its digest", %{
      conn: conn,
      data_dir: data_dir
    } do
      expected_digest = sha256("expected")
      put_blob_at(expected_digest, "tampered")

      body =
        conn
        |> authorize()
        |> get("/management/blobs/#{expected_digest}")
        |> response(422)

      assert body == "Unprocessable Content"
      refute body =~ data_dir
    end

    test "streams a verified blob with its exact content length", %{conn: conn} do
      contents = <<0, 1, 2, 3, 255, 254, 253>>
      digest = put_blob(contents)
      assert {:ok, path} = StoragePath.blob(digest)

      captured_conn =
        %{conn | adapter: {SendFileCaptureAdapter, %{}}}
        |> ManagementBlobController.show(%{"sha256" => digest})

      assert captured_conn.state == :file
      assert captured_conn.resp_body == {:file, path, 0, :all}

      assert get_resp_header(captured_conn, "content-length") == [
               Integer.to_string(byte_size(contents))
             ]

      routed_conn =
        build_conn()
        |> authorize()
        |> get("/management/blobs/#{digest}")

      assert response(routed_conn, 200) == contents
      assert get_resp_header(routed_conn, "content-type") == ["application/octet-stream"]

      assert get_resp_header(routed_conn, "content-length") == [
               Integer.to_string(byte_size(contents))
             ]

      assert get_resp_header(routed_conn, "etag") == [~s("#{digest}")]
      assert routed_conn.state == :file

      refute Enum.any?(routed_conn.resp_headers, fn {_name, value} ->
               String.contains?(value, path)
             end)
    end

    test "resolves blobs only through the public management-core facade" do
      module = YellowDog.Console.ManagementBlobController

      assert {:ok, {^module, [imports: imports]}} =
               module
               |> :code.which()
               |> :beam_lib.chunks([:imports])

      assert {YellowDog.ManagementCore, :get_blob, 2} in imports
      assert {Plug.Conn, :send_file, 3} in imports
      refute {Plug.Conn, :send_chunked, 2} in imports
      refute {Plug.Conn, :chunk, 2} in imports

      refute Enum.any?(imports, fn {imported_module, _function, _arity} ->
               imported_module in [File, YellowDog.Management.Storage.Path]
             end)
    end
  end

  defp authorize(conn),
    do: put_req_header(conn, "authorization", "Bearer #{@token}")

  defp put_blob(contents) do
    digest = sha256(contents)
    put_blob_at(digest, contents)
    digest
  end

  defp put_blob_at(digest, contents) do
    assert {:ok, path} = StoragePath.blob(digest)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  defp sha256(contents),
    do: :sha256 |> :crypto.hash(contents) |> Base.encode16(case: :lower)

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
