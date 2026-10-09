defmodule YellowDog.ManagementUI.WorkerConnection.Secret do
  @moduledoc false
  @derive {Inspect, except: [:text]}
  defstruct [:text]
end

defmodule YellowDog.ManagementUI.WorkerConnection do
  use YellowDog.ManagementUI, :html

  attr :bootstrap, :map, required: true

  def configuration(assigns) do
    ~H"""
    <.card title="Worker connection configuration">
      <p class="management-help">
        Save this as bootstrap.toml on the Worker. This token is shown once; keep the file private.
      </p>
      <label class="form-control">
        <span class="label">bootstrap.toml</span>
        <textarea id="worker-bootstrap" class="textarea" rows="10" readonly spellcheck="false">{@bootstrap.text}</textarea>
      </label>
      <button
        id="worker-bootstrap-copy"
        class="btn btn-primary"
        type="button"
        phx-hook="CopyToClipboard"
        data-target="worker-bootstrap"
      >Copy configuration</button>
      <pre>chmod 600 bootstrap.toml
    YELLOW_DOG_WORKER_BOOTSTRAP=/absolute/path/bootstrap.toml bin/yellow_dog_worker start</pre>
      <p class="management-help">
        If your Management gateway requires a client certificate, add tls_cert_file and tls_key_file.
        Add tls_ca_file when using a private certificate authority. File paths are local to the Worker.
      </p>
      <button class="btn btn-outline" type="button" phx-click="dismiss_connection">I've saved this configuration</button>
    </.card>
    """
  end

  def origin(uri) do
    parsed = URI.parse(uri)
    URI.to_string(%URI{scheme: parsed.scheme, host: parsed.host, port: parsed.port})
  end

  def protect(text), do: %__MODULE__.Secret{text: text}

  def status(worker) do
    case worker["connection_status"] do
      "connected" -> "Online"
      "offline" -> "Offline"
      _ -> "Not connected"
    end
  end

  def services(worker) do
    case worker["reported_services"] || %{} do
      services when map_size(services) == 0 ->
        "No service report"

      services ->
        suffix = if worker["connection_status"] == "connected", do: "", else: " (last report)"

        Enum.map_join(Enum.sort(services), ", ", fn {id, report} ->
          "#{id}: #{report["state"]}"
        end) <> suffix
    end
  end

  def service_state(worker, instance_id) do
    if worker["connection_status"] == "connected" do
      get_in(worker, ["reported_services", instance_id, "state"]) || "unknown"
    else
      "unknown"
    end
  end
end
