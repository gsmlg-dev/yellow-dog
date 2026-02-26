defmodule YellowDog.Console.BootController do
  @moduledoc """
  HTTP boot endpoints for iPXE network boot chain.

  Serves dynamic iPXE scripts, static boot assets, install manifests,
  and handles device self-registration and status callbacks from the
  installer environment.
  """

  use YellowDog.Console, :controller

  alias YellowDog.Netboot.Boot.{Arch, ScriptEngine}
  alias YellowDog.Netboot.Device.Registry
  alias YellowDog.Netboot.Manifest.Store

  @doc "GET /boot/ipxe — Dynamic iPXE script for a device."
  def ipxe(conn, params) do
    mac = Map.get(params, "mac", "")
    arch_str = Map.get(params, "arch")
    uuid = Map.get(params, "uuid")
    arch = if arch_str, do: Arch.from_string(arch_str)

    # Register/update device if MAC provided
    if mac != "" do
      attrs = %{}
      attrs = if arch, do: Map.put(attrs, :arch, arch), else: attrs
      attrs = if uuid, do: Map.put(attrs, :uuid, uuid), else: attrs
      Registry.register(mac, attrs)
    end

    # Resolve profile for this device
    case resolve_profile(mac) do
      {:ok, profile} ->
        assigns = build_script_assigns(conn, profile, mac, arch)

        case ScriptEngine.render(assigns) do
          {:ok, script} -> send_ipxe(conn, script)
          {:error, _} -> send_rescue_script(conn, mac)
        end

      :no_profile ->
        send_rescue_script(conn, mac)
    end
  end

  @doc "GET /boot/assets/*path — Static boot asset serving."
  def asset(conn, %{"path" => path_parts}) do
    relative_path = Path.join(path_parts)

    case YellowDog.Netboot.Asset.Store.get_file(relative_path) do
      {:ok, %{type: :file}} ->
        root = YellowDog.Netboot.Asset.Store.root_dir()
        full_path = Path.join(root, relative_path)
        send_file(conn, 200, full_path)

      {:ok, %{type: :directory}} ->
        conn |> put_status(403) |> text("Directory listing not allowed")

      {:error, :path_traversal} ->
        conn |> put_status(400) |> text("Invalid path")

      {:error, :not_found} ->
        conn |> put_status(404) |> text("Not found")
    end
  end

  @doc "GET /boot/manifest/:device_id — Install manifest JSON."
  def manifest(conn, %{"device_id" => mac}) do
    with {:ok, device} <- Registry.get(mac),
         profile_id when not is_nil(profile_id) <- device.profile_id,
         {:ok, manifest} <- Store.get_manifest(profile_id) do
      json(conn, %{
        device: %{mac: device.mac, arch: to_string(device.arch || "unknown")},
        manifest: manifest
      })
    else
      _ -> conn |> put_status(404) |> json(%{error: "no manifest found"})
    end
  end

  @doc "POST /boot/register — Device self-registration from installer."
  def register_device(conn, params) do
    mac = Map.get(params, "mac", "")

    cond do
      mac == "" ->
        conn |> put_status(400) |> json(%{error: "mac required"})

      not valid_mac?(mac) ->
        conn |> put_status(400) |> json(%{error: "invalid MAC address format"})

      true ->
        attrs = %{
          hostname: Map.get(params, "hostname"),
          uuid: Map.get(params, "uuid"),
          arch: parse_arch(Map.get(params, "arch")),
          hardware_info: Map.get(params, "hardware_info", %{})
        }

        case Registry.register(mac, attrs) do
          {:ok, device} ->
            json(conn, %{status: "ok", mac: device.mac, state: to_string(device.state)})

          {:error, reason} ->
            conn |> put_status(422) |> json(%{error: inspect(reason)})
        end
    end
  end

  @doc "POST /boot/status — Device install status callback."
  def status_update(conn, params) do
    mac = Map.get(params, "mac", "")
    status = Map.get(params, "status", "")

    cond do
      mac == "" or status == "" ->
        conn |> put_status(400) |> json(%{error: "mac and status required"})

      not valid_mac?(mac) ->
        conn |> put_status(400) |> json(%{error: "invalid MAC address format"})

      true ->
        new_state = status_to_state(status)
        metadata = Map.get(params, "metadata", %{})

        case Registry.update_state(mac, new_state, metadata) do
          {:ok, device} ->
            json(conn, %{status: "ok", mac: device.mac, state: to_string(device.state)})

          {:error, reason} ->
            conn |> put_status(422) |> json(%{error: inspect(reason)})
        end
    end
  end

  # --- Private ---

  defp resolve_profile(mac) when mac == "", do: :no_profile

  defp resolve_profile(mac) do
    case Registry.get(mac) do
      {:ok, %{profile_id: id}} when not is_nil(id) ->
        case Store.get_profile(id) do
          {:ok, profile} -> {:ok, profile}
          _ -> :no_profile
        end

      _ ->
        # Try default profile
        case Store.default_profile_id() do
          nil ->
            :no_profile

          id ->
            case Store.get_profile(id) do
              {:ok, p} -> {:ok, p}
              _ -> :no_profile
            end
        end
    end
  catch
    _, _ -> :no_profile
  end

  defp build_script_assigns(conn, profile, mac, arch) do
    port = conn.port
    server = conn.host
    base_url = "http://#{server}:#{port}"

    %{
      server: server,
      port: port,
      mac: mac,
      arch: to_string(arch || :x86_64),
      kernel: profile.kernel,
      initrd: profile.initrd,
      kernel_args: profile.kernel_args || "",
      registration_url: "#{base_url}/api/hosts/register"
    }
  end

  defp send_ipxe(conn, script) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, script)
  end

  defp send_rescue_script(conn, mac) do
    assigns = %{
      server: conn.host,
      port: conn.port,
      mac: mac
    }

    case ScriptEngine.render_rescue(assigns) do
      {:ok, script} -> send_ipxe(conn, script)
      {:error, _} -> conn |> put_status(500) |> text("#!ipxe\necho Error rendering script\nshell")
    end
  end

  # MAC address: 12 hex chars with optional separators (colon, dash, dot, or none)
  @mac_pattern ~r/\A[0-9a-fA-F]{2}([:\-.]?[0-9a-fA-F]{2}){5}\z/
  defp valid_mac?(mac), do: Regex.match?(@mac_pattern, mac)

  @valid_statuses ~w(booting installing installed failed)
  defp status_to_state(status) when status in @valid_statuses, do: String.to_existing_atom(status)
  defp status_to_state(_), do: :failed

  defp parse_arch(nil), do: nil
  defp parse_arch(arch) when is_binary(arch), do: Arch.from_string(arch)
  defp parse_arch(_), do: nil
end
