defmodule YellowDog.ManagementUI.CloudDnsForms do
  @moduledoc false
  use YellowDog.ManagementUI, :html
  alias YellowDog.Management.CloudDns.Provider

  attr :form, :map, default: nil

  def modal(assigns) do
    ~H"""
    <div
      :if={@form}
      id={@form.id}
      phx-hook="SchemaModal"
      phx-update="ignore"
      data-form={Jason.encode!(Map.drop(@form, [:id]))}
    />
    """
  end

  def provider_form(provider, bound?) do
    title = if provider, do: "Edit Cloud Provider", else: "Add Cloud Provider"

    fields = %{
      "name" => %{type: "string", title: "Name", minLength: 1, maxLength: 128}
    }

    fields =
      if bound? do
        fields
      else
        Map.merge(fields, %{
          "kind" =>
            options("Provider", [
              {"route53", Provider.label("route53")},
              {"cloudflare", Provider.label("cloudflare")}
            ]),
          "profile" => %{
            type: "string",
            title: "Credential profile prefix",
            description: "Prefix of the provider credentials set in the Management environment.",
            pattern: "^[A-Z][A-Z0-9_]{0,63}$"
          }
        })
      end

    initial =
      if provider, do: Map.take(provider, [:name, :kind, :profile]), else: %{profile: "DNS"}

    form(title, fields, Map.take(initial, Enum.map(Map.keys(fields), &String.to_existing_atom/1)))
  end

  def binding_form(mode, providers, zones, zone) do
    title =
      if mode == "import", do: "Import cloud zone", else: "Create cloud zone from local zone"

    fields = %{
      "provider_id" =>
        options(
          "Cloud Provider",
          Enum.map(providers, &{&1.id, "#{&1.name} · #{Provider.label(&1.kind)}"})
        )
    }

    fields =
      case {mode, zone} do
        {"import", _} ->
          Map.put(fields, "remote_id", %{type: "string", title: "Cloud zone ID", minLength: 1})

        {"create", nil} ->
          Map.put(fields, "zone_id", options("Local zone", Enum.map(zones, &{&1.id, &1.name})))

        {"create", _} ->
          fields
      end

    form(title, fields, %{})
  end

  def conflicts_form(rows) do
    fields =
      rows
      |> Enum.with_index()
      |> Enum.filter(fn {row, _index} -> row.state == :conflict end)
      |> Map.new(fn {row, index} ->
        title = "#{elem(row.key, 0)} #{elem(row.key, 1)}"

        {Integer.to_string(index),
         options(title, [{"local", "Keep local"}, {"remote", "Use cloud"}])}
      end)

    form("Resolve record conflicts", fields, %{})
  end

  defp options(title, options) do
    %{
      type: "string",
      title: title,
      enum: Enum.map(options, &elem(&1, 0)),
      "x-widget": "select",
      "x-options": Enum.map(options, fn {value, label} -> %{value: value, label: label} end)
    }
  end

  defp form(title, fields, initial) do
    %{
      id: "cloud-dns-form-#{Ecto.UUID.generate()}",
      title: title,
      schema: %{
        type: "object",
        additionalProperties: false,
        properties: fields,
        required: Map.keys(fields)
      },
      initial: initial
    }
  end
end
