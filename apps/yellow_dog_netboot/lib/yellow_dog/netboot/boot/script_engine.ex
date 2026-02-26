defmodule YellowDog.Netboot.Boot.ScriptEngine do
  @moduledoc """
  iPXE script template rendering engine.

  Renders dynamic iPXE scripts based on device profile and attributes.
  """

  use GenServer

  @default_template """
  #!ipxe
  echo YellowDog Netboot - ${mac} (${arch})
  dhcp
  set base-url http://<%= @server %>:<%= @port %>/boot/assets
  set registration-url http://<%= @server %>:<%= @port %>/api/hosts/register

  kernel ${base-url}/<%= @kernel %> <%= @kernel_args %> yellowdog.mac=<%= @mac %> yellowdog.api=http://<%= @server %>:<%= @port %> yellowdog.registration_url=${registration-url}
  initrd ${base-url}/<%= @initrd %>
  boot
  """

  @rescue_template """
  #!ipxe
  echo YellowDog Rescue Shell - ${mac}
  dhcp
  set base-url http://<%= @server %>:<%= @port %>/boot/assets

  kernel ${base-url}/rescue/vmlinuz rescue shell yellowdog.mac=<%= @mac %>
  initrd ${base-url}/rescue/initrd.img
  boot
  """

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Render an iPXE script for a device."
  @spec render(map()) :: {:ok, String.t()} | {:error, term()}
  def render(assigns) do
    GenServer.call(__MODULE__, {:render, :default, assigns})
  catch
    :exit, _ -> {:error, :engine_not_running}
  end

  @doc "Render a rescue iPXE script."
  @spec render_rescue(map()) :: {:ok, String.t()} | {:error, term()}
  def render_rescue(assigns) do
    GenServer.call(__MODULE__, {:render, :rescue, assigns})
  catch
    :exit, _ -> {:error, :engine_not_running}
  end

  @doc "Render a script with a custom template string."
  @spec render_custom(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def render_custom(template, assigns) do
    GenServer.call(__MODULE__, {:render_custom, template, assigns})
  catch
    :exit, _ -> {:error, :engine_not_running}
  end

  @impl true
  def init(_opts) do
    templates = %{
      default: load_template("default.ipxe.eex", @default_template),
      rescue: load_template("rescue.ipxe.eex", @rescue_template)
    }

    {:ok, %{templates: templates}}
  end

  @impl true
  def handle_call({:render, template_name, assigns}, _from, state) do
    template = Map.get(state.templates, template_name, @default_template)
    result = do_render(template, assigns)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:render_custom, template, assigns}, _from, state) do
    result = do_render(template, assigns)
    {:reply, result, state}
  end

  # Max length for assign key names to prevent atom table exhaustion
  @max_key_length 64

  # Known template variables declared as atoms at compile time.
  # This ensures String.to_existing_atom/1 can find them at runtime
  # without needing String.to_atom/1 (which risks atom table exhaustion).
  @known_assign_keys ~w(
    server port mac arch kernel initrd kernel_args registration_url
    hostname ip name base_url flag version profile_id device_id
    gateway netmask dns_servers ntp_servers vlan
  )a

  defp do_render(template, assigns) do
    assigns_keyword =
      assigns
      |> Enum.flat_map(fn {k, v} ->
        case safe_to_atom(k) do
          {:ok, atom_key} -> [{atom_key, v}]
          :skip -> []
        end
      end)

    rendered = EEx.eval_string(template, assigns: assigns_keyword)
    {:ok, rendered}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp safe_to_atom(key) when is_atom(key), do: {:ok, key}

  defp safe_to_atom(key) when is_binary(key) and byte_size(key) <= @max_key_length do
    {:ok, String.to_existing_atom(key)}
  rescue
    ArgumentError -> :skip
  end

  defp safe_to_atom(_key), do: :skip

  @doc false
  def known_assign_keys, do: @known_assign_keys

  defp load_template(filename, fallback) do
    priv_path = :code.priv_dir(:yellow_dog_netboot)

    path =
      priv_path
      |> to_string()
      |> Path.join("templates/#{filename}")

    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> fallback
    end
  end
end
