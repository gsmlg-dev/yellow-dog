defmodule YellowDog.Console.CoreComponents do
  @moduledoc """
  Provides core UI components.

  The components in this module use Tailwind CSS, a utility-first CSS framework.
  See the [Tailwind CSS documentation](https://tailwindcss.com) to learn how to
  customize the generated components in this file.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  # Note: modal function removed for now - can be added later when needed

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
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate "is invalid" in the "errors" domain
    #     dgettext("errors", "is invalid")
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
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

  ## Attributes
  - `changeset` - The changeset containing errors
  - `field` - The field atom to display errors for
  """
  attr :changeset, :map, required: true
  attr :field, :atom, required: true

  def input_error(assigns) do
    assigns =
      assign(assigns, :errors, Keyword.get_values(assigns.changeset.errors, assigns.field))

    ~H"""
    <%= if @errors != [] do %>
      <div class="label">
        <span class="label-text-alt text-error">
          {translate_error(Enum.at(@errors, 0))}
        </span>
      </div>
    <% end %>
    """
  end

  ## DaisyUI Components

  @doc """
  Renders a DaisyUI stat card.

  ## Examples

      <.stat title="Total Users" value="4,200" desc="21% more than last month" />
      <.stat title="Downloads" value="12M" trend="up" trend_value="12%" />
  """
  attr :title, :string, required: true
  attr :value, :string, required: true
  attr :desc, :string, default: nil
  attr :trend, :string, default: nil, values: ["up", "down", nil]
  attr :trend_value, :string, default: nil
  attr :class, :string, default: nil

  def stat(assigns) do
    ~H"""
    <div class={["stat", @class]}>
      <div class="stat-title">{@title}</div>
      <div class="stat-value">{@value}</div>
      <div :if={@desc} class="stat-desc">{@desc}</div>
      <div
        :if={@trend}
        class={["stat-desc", @trend == "up" && "text-success", @trend == "down" && "text-error"]}
      >
        {@trend_value}
      </div>
    </div>
    """
  end

  @doc """
  Renders a DaisyUI badge.

  ## Examples

      <.badge>Default</.badge>
      <.badge color="primary">Primary</.badge>
      <.badge color="success" size="lg">Success Large</.badge>
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
  Renders a DaisyUI card.

  ## Examples

      <.card title="Card Title">
        <p>Card content goes here</p>
        <:actions>
          <button class="btn btn-primary">Action</button>
        </:actions>
      </.card>
  """
  attr :title, :string, default: nil
  attr :image, :string, default: nil
  attr :class, :string, default: nil
  attr :compact, :boolean, default: false

  slot :inner_block, required: true
  slot :actions

  def card(assigns) do
    ~H"""
    <div class={["card bg-base-100 shadow-xl", @compact && "card-compact", @class]}>
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
  Renders a DaisyUI modal.

  ## Examples

      <.modal id="my-modal" title="Modal Title">
        <p>Modal content</p>
        <:actions>
          <button class="btn" phx-click={hide_modal("my-modal")}>Cancel</button>
          <button class="btn btn-primary">Confirm</button>
        </:actions>
      </.modal>
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
      phx-remove={hide_modal(@id)}
      phx-window-keydown={@on_cancel}
      phx-key="Escape"
    >
      <div class="modal-box">
        <h3 :if={@title} class="font-bold text-lg mb-4">{@title}</h3>
        {render_slot(@inner_block)}
        <div :if={@actions != []} class="modal-action">
          {render_slot(@actions)}
        </div>
      </div>
      <div class="modal-backdrop" phx-click={@on_cancel}>
        <button type="button">close</button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a DaisyUI table.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="Name"><%= user.name %></:col>
        <:col :let={user} label="Email"><%= user.email %></:col>
        <:action :let={user}>
          <button class="btn btn-sm btn-ghost">Edit</button>
        </:action>
      </.table>
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
        @zebra && "table-zebra",
        @hover && "hover:table-hover",
        @pin_rows && "table-pin-rows",
        @class
      ]}>
        <thead>
          <tr>
            <th :for={col <- @col} class={col[:class]}>{col[:label]}</th>
            <th :if={@action != []}>Actions</th>
          </tr>
        </thead>
        <tbody id={@id}>
          <tr :for={row <- @rows} class="hover">
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
  Renders a DaisyUI loading indicator.

  ## Examples

      <.loading />
      <.loading type="spinner" size="lg" />
  """
  attr :type, :string, default: "spinner", values: ["spinner", "dots", "ring", "ball", "bars"]
  attr :size, :string, default: "md", values: ["xs", "sm", "md", "lg"]

  attr :color, :string,
    default: nil,
    values: ["primary", "secondary", "accent", "info", "success", "warning", "error", nil]

  def loading(assigns) do
    ~H"""
    <span class={[
      "loading",
      "loading-#{@type}",
      "loading-#{@size}",
      @color && "text-#{@color}"
    ]}>
    </span>
    """
  end

  @doc """
  Renders a DaisyUI progress bar.

  ## Examples

      <.progress value={75} />
      <.progress value={50} color="success" />
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
    >
    </progress>
    """
  end

  @doc """
  Renders a DaisyUI radial progress indicator.

  ## Examples

      <.radial_progress value={70} />
      <.radial_progress value={85} color="success" size="lg"><%= "85%" %></.radial_progress>
  """
  attr :value, :integer, required: true
  attr :size, :string, default: "md", values: ["xs", "sm", "md", "lg", "xl"]

  attr :color, :string,
    default: nil,
    values: ["primary", "secondary", "accent", "info", "success", "warning", "error", nil]

  attr :thickness, :integer, default: 2
  slot :inner_block

  def radial_progress(assigns) do
    assigns =
      assign(assigns, :style, "--value:#{assigns.value}; --thickness: #{assigns.thickness}px;")

    ~H"""
    <div
      class={[
        "radial-progress",
        @size && "radial-progress-#{@size}",
        @color && "text-#{@color}"
      ]}
      style={@style}
      role="progressbar"
    >
      {if @inner_block != [], do: render_slot(@inner_block), else: "#{@value}%"}
    </div>
    """
  end

  @doc """
  Renders a DaisyUI alert/toast.

  ## Examples

      <.toast id="success-toast" type="success">Operation successful!</.toast>
      <.toast id="error-toast" type="error">Something went wrong</.toast>
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
      <svg
        xmlns="http://www.w3.org/2000/svg"
        class="h-6 w-6 shrink-0 stroke-current"
        fill="none"
        viewBox="0 0 24 24"
      >
        <path
          :if={@type == "success"}
          stroke-linecap="round"
          stroke-linejoin="round"
          stroke-width="2"
          d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
        />
        <path
          :if={@type == "error"}
          stroke-linecap="round"
          stroke-linejoin="round"
          stroke-width="2"
          d="M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z"
        />
        <path
          :if={@type == "warning"}
          stroke-linecap="round"
          stroke-linejoin="round"
          stroke-width="2"
          d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"
        />
        <path
          :if={@type == "info"}
          stroke-linecap="round"
          stroke-linejoin="round"
          stroke-width="2"
          d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
        />
      </svg>
      <span>{render_slot(@inner_block)}</span>
    </div>
    """
  end

  @doc """
  Renders a service status indicator with pulse animation.

  ## Examples

      <.status_indicator status="running" />
      <.status_indicator status="stopped" label="DNS Service" />
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
        >
        </span>
        <span class={[
          "relative inline-flex rounded-full h-3 w-3",
          @status == "running" && "bg-success",
          @status == "stopped" && "bg-error",
          @status == "warning" && "bg-warning",
          @status == "unknown" && "bg-base-300"
        ]}>
        </span>
      </span>
      <span :if={@label} class="text-sm font-medium">
        {@label}
      </span>
    </div>
    """
  end

  @doc """
  Renders a service status alert banner.

  Shows a warning when the backing service is not running, helping users
  understand why data may be missing.

  ## Examples

      <.service_alert :if={not @service_running} service="DNS" />
      <.service_alert :if={not @service_running} service="mDNS" navigate="/dashboard" />
  """
  attr :service, :string, required: true
  attr :navigate, :string, default: "/dashboard"

  def service_alert(assigns) do
    ~H"""
    <div class="alert alert-warning" role="alert">
      <svg
        xmlns="http://www.w3.org/2000/svg"
        class="h-6 w-6 shrink-0 stroke-current"
        fill="none"
        viewBox="0 0 24 24"
      >
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          stroke-width="2"
          d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"
        />
      </svg>
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

  ## Examples

      iex> format_number(1234567)
      "1,234,567"

      iex> format_number(0)
      "0"
  """
  def format_number(number) when is_integer(number) do
    number
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
    |> Enum.map(&Enum.join/1)
    |> Enum.join(",")
  end

  def format_number(number) when is_float(number) do
    number
    |> trunc()
    |> format_number()
  end

  def format_number(nil), do: "0"
  def format_number(other), do: to_string(other)
end
