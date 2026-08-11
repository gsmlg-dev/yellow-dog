defmodule E2ETest.ManagementRelease do
  @moduledoc false

  @releases [:yellow_dog_management_core, :yellow_dog_server, :yellow_dog_netman]

  def release_binaries(root) when is_binary(root) do
    Map.new(@releases, fn release ->
      name = Atom.to_string(release)
      {release, Path.join([root, "_build", "prod", "rel", name, "bin", name])}
    end)
  end

  def validate_release_binaries(paths) when is_map(paths) do
    missing =
      @releases
      |> Enum.reject(fn release -> executable?(Map.get(paths, release)) end)
      |> Enum.sort()

    if missing == [], do: :ok, else: {:error, {:missing_release_binaries, missing}}
  end

  def validate_release_binaries(_paths),
    do: {:error, {:missing_release_binaries, Enum.sort(@releases)}}

  def build_releases(root) when is_binary(root) do
    run_script(root, "build", [], :build_failed)
  end

  def run(root, tmp_dir) when is_binary(root) and is_binary(tmp_dir) do
    with {:ok, [management_port, tls_port]} <- reserve_ports(2),
         {:ok, output} <-
           run_script(
             root,
             "run",
             [
               {"MANAGEMENT_E2E_DIR", Path.expand(tmp_dir)},
               {"MANAGEMENT_E2E_HTTP_PORT", Integer.to_string(management_port)},
               {"MANAGEMENT_E2E_TLS_PORT", Integer.to_string(tls_port)}
             ],
             :run_failed
           ) do
      {:ok, output}
    end
  end

  defp run_script(root, mode, env, failure) do
    script = Path.join(root, "scripts/e2e/management_releases.sh")

    case System.cmd("bash", [script, mode],
           cd: root,
           env: env,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        IO.write(output)
        if mode == "run", do: {:ok, output}, else: :ok

      {output, status} ->
        IO.write(output)
        {:error, {failure, status, output}}
    end
  end

  defp reserve_ports(count), do: reserve_ports(count, MapSet.new())

  defp reserve_ports(0, ports), do: {:ok, ports |> MapSet.to_list() |> Enum.sort()}

  defp reserve_ports(count, ports) do
    with {:ok, socket} <-
           :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: false]),
         {:ok, {_address, port}} <- :inet.sockname(socket),
         :ok <- :gen_tcp.close(socket) do
      if MapSet.member?(ports, port) do
        reserve_ports(count, ports)
      else
        reserve_ports(count - 1, MapSet.put(ports, port))
      end
    end
  end

  defp executable?(path) when is_binary(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _missing -> false
    end
  end

  defp executable?(_path), do: false
end
