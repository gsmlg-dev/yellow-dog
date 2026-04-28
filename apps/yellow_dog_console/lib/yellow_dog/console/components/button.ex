defmodule YellowDog.Console.Components.Button do
  @moduledoc """
  Native button component compatible with the DuskMoon `dm_btn` API used by the console.
  """
  use Phoenix.Component

  attr :id, :any, default: nil, doc: "HTML id attribute"
  attr :class, :any, default: nil, doc: "Additional CSS classes"

  attr :variant, :string,
    default: nil,
    values: [
      nil,
      "primary",
      "secondary",
      "accent",
      "tertiary",
      "info",
      "success",
      "warning",
      "error",
      "ghost",
      "link",
      "outline"
    ],
    doc: "Button color variant"

  attr :size, :string, default: nil, values: [nil, "xs", "sm", "md", "lg"], doc: "Button size"
  attr :shape, :string, default: nil, values: [nil, "square", "circle"], doc: "Button shape"
  attr :type, :string, default: "button", doc: "Native button type"
  attr :loading, :boolean, default: false, doc: "Show loading state"
  attr :disabled, :boolean, default: false, doc: "Disable the button"

  attr :noise, :boolean, default: false, doc: "Compatibility with the DuskMoon noise mode"
  attr :content, :string, default: "", doc: "Compatibility content for noise mode"

  attr :confirm, :string, default: "", doc: "Confirmation message"
  attr :confirm_title, :string, default: "", doc: "Compatibility attribute"
  attr :confirm_text, :string, default: "Yes", doc: "Compatibility attribute"
  attr :cancel_text, :string, default: "Cancel", doc: "Compatibility attribute"
  attr :confirm_class, :any, default: nil, doc: "Compatibility attribute"
  attr :cancel_class, :any, default: nil, doc: "Compatibility attribute"
  attr :show_cancel_action, :boolean, default: true, doc: "Compatibility attribute"
  attr :confirm_dialog_label, :string, default: "Confirmation", doc: "Compatibility attribute"

  attr :rest, :global,
    include:
      ~w(form name value onclick phx-disable-with phx-hook phx-target phx-value-id phx-value-index phx-value-name phx-value-type),
    doc: "Additional HTML attributes"

  slot :inner_block, required: true, doc: "Button content"
  slot :prefix, required: false, doc: "Content before button text"
  slot :suffix, required: false, doc: "Content after button text"
  slot :confirm_action, required: false, doc: "Compatibility slot"

  def dm_btn(%{noise: true} = assigns) do
    ~H"""
    <button
      type={@type}
      id={@id}
      class={["btn-noise", @class]}
      data-content={@content}
      aria-label={@content}
      disabled={@disabled || @loading}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  def dm_btn(assigns) do
    ~H"""
    <button
      type={@type}
      id={@id}
      class={button_classes(@variant, @size, @shape, @loading, @disabled, @class)}
      disabled={@disabled || @loading}
      aria-busy={@loading && "true"}
      data-confirm={@confirm != "" && @confirm}
      {@rest}
    >
      <span :for={prefix <- @prefix} class="inline-flex items-center">{render_slot(prefix)}</span>
      {render_slot(@inner_block)}
      <span :for={suffix <- @suffix} class="inline-flex items-center">{render_slot(suffix)}</span>
    </button>
    """
  end

  defp button_classes(variant, size, shape, loading, disabled, extra_class) do
    [
      "btn",
      variant_class(variant),
      size_class(size),
      shape_class(shape),
      loading && "btn-loading",
      disabled && "btn-disabled",
      extra_class
    ]
  end

  defp variant_class(nil), do: "btn-primary"
  defp variant_class("accent"), do: "btn-tertiary"
  defp variant_class("tertiary"), do: "btn-tertiary"
  defp variant_class("link"), do: "btn-link"
  defp variant_class(variant), do: "btn-#{variant}"

  defp size_class(nil), do: nil
  defp size_class(size), do: "btn-#{size}"

  defp shape_class(nil), do: nil
  defp shape_class(shape), do: "btn-#{shape}"
end
