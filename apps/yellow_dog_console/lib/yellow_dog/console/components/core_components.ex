defmodule YellowDog.Console.CoreComponents do
  @moduledoc """
  Provides core UI components built on @duskmoon-dev/core CSS classes.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      transition:
        {"transition-all transform ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all transform ease-in duration-200",
         "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(YellowDog.Console.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(YellowDog.Console.Gettext, "errors", msg, opts)
    end
  end

  def translate_error(msg) do
    msg
  end

  @doc """
  Renders validation errors for a form field from a changeset.
  """
  attr :changeset, :map, required: true
  attr :field, :atom, required: true

  def input_error(assigns) do
    assigns =
      assign(assigns, :errors, Keyword.get_values(assigns.changeset.errors, assigns.field))

    ~H"""
    <%= if @errors != [] do %>
      <div class="helper-text text-error">
        {translate_error(hd(@errors))}
      </div>
    <% end %>
    """
  end

  @doc """
  Returns a badge color for a DHCP lease state.
  """
  @lease_state_colors %{
    active: "success",
    offered: "info",
    released: "warning",
    expired: "error",
    declined: "error"
  }

  @spec lease_state_color(atom()) :: String.t()
  def lease_state_color(state), do: Map.get(@lease_state_colors, state, "ghost")

  @doc """
  Returns a text color class for a DHCP lease state.
  """
  @spec lease_state_text_color(atom()) :: String.t()
  def lease_state_text_color(state) do
    case lease_state_color(state) do
      "ghost" -> "text-on-surface"
      color -> "text-#{color}"
    end
  end

  @doc """
  Returns a color name for pool utilization percentage.
  """
  @spec utilization_color(number()) :: String.t()
  def utilization_color(percent) when percent >= 90, do: "error"
  def utilization_color(percent) when percent >= 75, do: "warning"
  def utilization_color(percent) when percent >= 50, do: "info"
  def utilization_color(_), do: "success"

  @doc """
  Returns a text color class for pool utilization percentage.
  """
  @spec utilization_text_color(number()) :: String.t()
  def utilization_text_color(percent), do: "text-#{utilization_color(percent)}"

  @doc "Returns a badge color for a DHCPv6 IA type."
  @ia_type_colors %{ia_na: "primary", ia_ta: "secondary", ia_pd: "accent"}

  @spec ia_type_color(atom()) :: String.t()
  def ia_type_color(type), do: Map.get(@ia_type_colors, type, "ghost")

  @doc "Returns a text color class for a DHCPv6 IA type."
  @spec ia_type_text_color(atom()) :: String.t()
  def ia_type_text_color(type) do
    case ia_type_color(type) do
      "ghost" -> "text-on-surface"
      color -> "text-#{color}"
    end
  end

  ## Components

  @doc """
  Renders a stat card.
  """
  attr :title, :string, required: true
  attr :value, :string, required: true
  attr :desc, :string, default: nil
  attr :trend, :string, default: nil, values: ["up", "down", nil]
  attr :trend_value, :string, default: nil
  attr :class, :string, default: nil

  def stat(assigns) do
    ~H"""
    <div class={["p-4 flex flex-col gap-1", @class]}>
      <div class="text-sm text-on-surface-variant">{@title}</div>
      <div class="text-2xl font-bold text-on-surface">{@value}</div>
      <div :if={@desc} class="text-xs text-on-surface-variant">{@desc}</div>
      <div
        :if={@trend}
        class={["text-xs", @trend == "up" && "text-success", @trend == "down" && "text-error"]}
      >
        {@trend_value}
      </div>
    </div>
    """
  end

  @doc """
  Renders a badge.
  """
  attr :color, :string,
    default: nil,
    values: [
      "primary",
      "secondary",
      "accent",
      "info",
      "success",
      "warning",
      "error",
      "ghost",
      nil
    ]

  attr :size, :string, default: nil, values: ["xs", "sm", "md", "lg", nil]
  attr :outline, :boolean, default: false
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def badge(assigns) do
    ~H"""
    <span class={[
      "badge",
      @color && "badge-#{@color}",
      @size && "badge-#{@size}",
      @outline && "badge-outline",
      @class
    ]}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  @doc """
  Renders a card.
  """
  attr :title, :string, default: nil
  attr :image, :string, default: nil
  attr :class, :string, default: nil
  attr :compact, :boolean, default: false

  slot :inner_block, required: true
  slot :actions

  def card(assigns) do
    ~H"""
    <div class={["card bg-surface-container shadow-xl", @compact && "p-2", @class]}>
      <figure :if={@image}>
        <img src={@image} alt={@title} />
      </figure>
      <div class="card-body">
        <h2 :if={@title} class="card-title">{@title}</h2>
        {render_slot(@inner_block)}
        <div :if={@actions != []} class="card-actions justify-end">
          {render_slot(@actions)}
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a modal dialog.
  """
  attr :id, :string, required: true
  attr :title, :string, default: nil
  attr :show, :boolean, default: false
  attr :on_cancel, JS, default: %JS{}

  slot :inner_block, required: true
  slot :actions

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      class={["modal", @show && "modal-open"]}
      role="dialog"
      aria-modal="true"
      aria-labelledby={@title && "#{@id}-title"}
      phx-remove={hide_modal(@id)}
      phx-window-keydown={@on_cancel}
      phx-key="Escape"
    >
      <div class="modal-box">
        <h2 :if={@title} id={"#{@id}-title"} class="text-title-large text-on-surface mb-4">
          {@title}
        </h2>
        {render_slot(@inner_block)}
        <div :if={@actions != []} class="modal-action">
          {render_slot(@actions)}
        </div>
      </div>
      <button type="button" class="modal-backdrop" phx-click={@on_cancel} aria-label="Close modal"></button>
    </div>
    """
  end

  @doc """
  Renders a data table.
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :zebra, :boolean, default: false
  attr :hover, :boolean, default: true
  attr :pin_rows, :boolean, default: false
  attr :class, :string, default: nil

  slot :col, required: true do
    attr :label, :string
    attr :class, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table class={[
        "table",
        @zebra && "table-striped",
        @hover && "table-hover",
        @class
      ]}>
        <thead>
          <tr>
            <th :for={col <- @col} class={col[:class]}>{col[:label]}</th>
            <th :if={@action != []}>Actions</th>
          </tr>
        </thead>
        <tbody id={@id}>
          <tr :for={row <- @rows}>
            <td :for={col <- @col} class={col[:class]}>
              {render_slot(col, row)}
            </td>
            <td :if={@action != []}>
              <div class="flex gap-2">
                {render_slot(@action, row)}
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  Renders a loading indicator.
  """
  attr :type, :string, default: "spinner", values: ["spinner", "dots", "ring", "ball", "bars"]
  attr :size, :string, default: "md", values: ["xs", "sm", "md", "lg"]

  attr :color, :string,
    default: nil,
    values: ["primary", "secondary", "accent", "info", "success", "warning", "error", nil]

  @loading_sizes %{"xs" => "w-4 h-4", "sm" => "w-5 h-5", "md" => "w-8 h-8", "lg" => "w-12 h-12"}

  def loading(assigns) do
    assigns = assign(assigns, :size_class, Map.get(@loading_sizes, assigns.size, "w-8 h-8"))

    ~H"""
    <span
      class={[
        "inline-block animate-spin rounded-full border-2 border-current border-t-transparent",
        @size_class,
        @color && "text-#{@color}"
      ]}
      role="status"
    ></span>
    """
  end

  @doc """
  Renders a progress bar.
  """
  attr :value, :integer, default: 0
  attr :max, :integer, default: 100

  attr :color, :string,
    default: nil,
    values: ["primary", "secondary", "accent", "info", "success", "warning", "error", nil]

  attr :class, :string, default: nil

  def progress(assigns) do
    ~H"""
    <progress
      class={["progress", @color && "progress-#{@color}", @class]}
      value={@value}
      max={@max}
    ></progress>
    """
  end

  @doc """
  Renders a radial progress indicator using SVG.
  """
  attr :value, :integer, required: true
  attr :size, :string, default: "md", values: ["xs", "sm", "md", "lg", "xl"]

  attr :color, :string,
    default: nil,
    values: ["primary", "secondary", "accent", "info", "success", "warning", "error", nil]

  attr :thickness, :integer, default: 2
  slot :inner_block

  @radial_sizes %{"xs" => 32, "sm" => 48, "md" => 64, "lg" => 80, "xl" => 96}

  def radial_progress(assigns) do
    px = Map.get(@radial_sizes, assigns.size, 64)
    r = (px - assigns.thickness * 2) / 2
    circumference = 2 * :math.pi() * r
    offset = circumference * (1 - assigns.value / 100)

    assigns =
      assign(assigns,
        px: px,
        r: r,
        circumference: circumference,
        offset: offset
      )

    ~H"""
    <div
      class={["relative inline-flex items-center justify-center", @color && "text-#{@color}"]}
      style={"width: #{@px}px; height: #{@px}px"}
      role="progressbar"
      aria-valuenow={@value}
    >
      <svg class="rotate-[-90deg]" width={@px} height={@px}>
        <circle
          class="text-surface-container-high"
          stroke="currentColor"
          fill="none"
          stroke-width={@thickness * 2}
          r={@r}
          cx={@px / 2}
          cy={@px / 2}
        />
        <circle
          stroke="currentColor"
          fill="none"
          stroke-width={@thickness * 2}
          stroke-dasharray={@circumference}
          stroke-dashoffset={@offset}
          stroke-linecap="round"
          r={@r}
          cx={@px / 2}
          cy={@px / 2}
        />
      </svg>
      <span class="absolute text-xs font-bold">
        {if @inner_block != [], do: render_slot(@inner_block), else: "#{@value}%"}
      </span>
    </div>
    """
  end

  @doc """
  Renders a toast/alert.
  """
  attr :id, :string, required: true

  attr :type, :string,
    default: "info",
    values: ["info", "success", "warning", "error"]

  attr :class, :string, default: nil
  slot :inner_block, required: true

  def toast(assigns) do
    ~H"""
    <div id={@id} class={["alert", "alert-#{@type}", @class]} role="alert">
      <span>{render_slot(@inner_block)}</span>
    </div>
    """
  end

  @doc """
  Renders a service status indicator with pulse animation.
  """
  attr :status, :string, required: true, values: ["running", "stopped", "warning", "unknown"]
  attr :label, :string, default: nil
  attr :pulse, :boolean, default: true

  def status_indicator(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <span class="relative flex h-3 w-3">
        <span
          :if={@pulse && @status == "running"}
          class="animate-ping absolute inline-flex h-full w-full rounded-full bg-success opacity-75"
        ></span>
        <span class={[
          "relative inline-flex rounded-full h-3 w-3",
          @status == "running" && "bg-success",
          @status == "stopped" && "bg-error",
          @status == "warning" && "bg-warning",
          @status == "unknown" && "bg-outline"
        ]}></span>
      </span>
      <span :if={@label} class="text-sm font-medium">
        {@label}
      </span>
    </div>
    """
  end

  @doc """
  Renders a service status alert banner.
  """
  attr :service, :string, required: true
  attr :navigate, :string, default: "/server/dashboard"

  def service_alert(assigns) do
    ~H"""
    <div class="alert alert-warning" role="alert">
      <div>
        <h3 class="font-bold">{@service} service is not running</h3>
        <div class="text-sm">
          Data shown may be unavailable. Start the service from the dashboard.
        </div>
      </div>
      <.link navigate={@navigate} class="btn btn-sm btn-ghost">Go to Dashboard</.link>
    </div>
    """
  end

  ## Modal helpers

  def show_modal(js \\ %JS{}, id) when is_binary(id) do
    js
    |> JS.add_class("modal-open", to: "##{id}")
  end

  def hide_modal(js \\ %JS{}, id) do
    js
    |> JS.remove_class("modal-open", to: "##{id}")
  end

  ## Formatting helpers

  @doc """
  Formats a number with thousand separators.
  """
  def format_number(number) when is_integer(number) do
    number |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+$)/, ",")
  end

  def format_number(number) when is_float(number) do
    number
    |> trunc()
    |> format_number()
  end

  def format_number(nil), do: "0"
  def format_number(other), do: to_string(other)
end
