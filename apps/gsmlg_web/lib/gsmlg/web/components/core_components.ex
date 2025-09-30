defmodule GSMLG.Web.Components.CoreComponents do
  @moduledoc """
  Phoenix 1.8 Core Components - Simplified, Essential Building Blocks

  This module provides the most essential UI components following Phoenix 1.8's
  philosophy of simplicity and explicitness. These components serve as foundational
  building blocks rather than a complete UI kit.
  """

  use Phoenix.Component
  alias Phoenix.LiveView.JS

  ## Phoenix 1.8 Essential Components

  @doc """
  Phoenix 1.8 simplified button component with DaisyUI styling.
  """
  attr :type, :string, default: "button"
  attr :class, :string, default: nil
  attr :rest, :global
  attr :variant, :string, default: "primary", values: ["primary", "secondary", "accent", "ghost", "link", "info", "success", "warning", "error"]
  attr :size, :string, default: "md", values: ["xs", "sm", "md", "lg"]
  attr :disabled, :boolean, default: false
  attr :loading, :boolean, default: false
  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button
      type={@type}
      class={[
        "btn",
        "btn-#{@variant}",
        "btn-#{@size}",
        @loading && "loading",
        @disabled && "btn-disabled",
        @class
      ]}
      disabled={@disabled or @loading}
      {@rest}
    >
      <%= render_slot(@inner_block) %>
    </button>
    """
  end

  @doc """
  Phoenix 1.8 simplified input component with DaisyUI styling.
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any
  attr :type, :string, default: "text"
  attr :field, Phoenix.HTML.FormField, doc: "a form field struct retrieved from input, e.g. @form[:email]"
  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, rest: :global
  attr :rest, :global
  attr :class, :string, default: nil
  attr :size, :string, default: "md", values: ["xs", "sm", "md", "lg"]

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(field.errors, &translate_error/1))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "checkbox", value: value} = assigns) do
    assigns = assign_new(assigns, :checked, fn -> Phoenix.HTML.Form.normalize_value("checkbox", value) end)

    ~H"""
    <div class="form-control">
      <label class={"label cursor-pointer justify-start gap-2"}>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
        />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class={["checkbox checkbox-#{@size}", @class]}
          {@rest}
        />
        <%= if @label do %>
          <span class="label-text">{@label}</span>
        <% end %>
      </label>
      <. Phoenix 1.8 error component %>
      <.error :for={msg <- @errors} message={msg} phx_feedback_for={@name} />
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="form-control">
      <label :if={@label} class="label" for={@id}>
        <span class="label-text">{@label}</span>
      </label>
      <select
        id={@id}
        name={@name}
        class={["select select-bordered select-#{@size}", @class]}
        multiple={@multiple}
        {@rest}
      >
        <option :if={@prompt} value="">{@prompt}</option>
        <%= Phoenix.HTML.Form.options_for_select(@options, @value) %>
      </select>
      <. Phoenix 1.8 error component %>
      <.error :for={msg <- @errors} message={msg} phx_feedback_for={@name} />
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="form-control">
      <label :if={@label} class="label" for={@id}>
        <span class="label-text">{@label}</span>
      </label>
      <textarea
        id={@id}
        name={@name}
        class={["textarea textarea-bordered textarea-#{@size}", @class]}
        {@rest}
      >{@value}</textarea>
      <. Phoenix 1.8 error component %>
      <.error :for={msg <- @errors} message={msg} phx_feedback_for={@name} />
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div class="form-control">
      <label :if={@label} class="label" for={@id}>
        <span class="label-text">{@label}</span>
      </label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class={["input input-bordered input-#{@size}", @class]}
        {@rest}
      />
      <. Phoenix 1.8 error component %>
      <.error :for={msg <- @errors} message={msg} phx_feedback_for={@name} />
    </div>
    """
  end

  @doc """
  Phoenix 1.8 simplified error component.
  """
  attr :for, :string, default: nil
  attr :message, :string, required: true

  def error(assigns) do
    ~H"""
    <p :if={@message} class="mt-1 text-sm text-error" phx-feedback-for={@for}>
      <%= @message %>
    </p>
    """
  end

  @doc """
  Phoenix 1.8 simplified flash component.
  """
  attr :id, :string, default: "flash", doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  def flash(assigns) do
    ~H"""
    <div
      :if={msg = live_flash(@flash, @kind)} id={@id} phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> JS.hide()}
      role="alert"
      class={[
        "alert",
        @kind == :info && "alert-info",
        @kind == :error && "alert-error",
        "cursor-pointer"
      ]}
      {@rest}
    >
      <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" class="stroke-current shrink-0 w-6 h-6">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" ></path>
      </svg>
      <span>{msg}</span>
    </div>
    """
  end

  @doc """
  Phoenix 1.8 simplified header component.
  """
  attr :class, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def header(assigns) do
    ~H"""
    <header class={["navbar bg-base-100 shadow-lg", @class]} {@rest}>
      <div class="navbar-start">
        <a href={~p"/"} class="btn btn-ghost normal-case text-xl">GSMLG</a>
      </div>
      <div class="navbar-center hidden lg:flex">
        <ul class="menu menu-horizontal px-1">
          <li><a href={~p"/blogs"}>Blog</a></li>
          <li><a href={~p"/toolbox"}>Toolbox</a></li>
          <li><a href={~p"/about"}>About</a></li>
        </ul>
      </div>
      <div class="navbar-end">
        <div class="flex items-center gap-2">
          <a href="https://github.com/gsmlg-dev" target="_blank" class="btn btn-ghost btn-circle">
            <svg class="w-5 h-5" fill="currentColor" viewBox="0 0 24 24">
              <path d="M12 0c-6.626 0-12 5.373-12 12 0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23.957-.266 1.983-.399 3.003-.404 1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576 4.765-1.589 8.199-6.086 8.199-11.386 0-6.627-5.373-12-12-12z"/>
            </svg>
          </a>
          <a href={~p"/auth/magic-link/new"} class="btn btn-ghost">Sign In</a>
        </div>
      </div>
    </header>
    """
  end

  @doc """
  Phoenix 1.8 simplified footer component.
  """
  attr :class, :string, default: nil
  attr :rest, :global

  def footer(assigns) do
    ~H"""
    <footer class={["footer footer-center p-10 bg-base-300 text-base-content", @class]} {@rest}>
      <div class="grid grid-flow-col gap-4">
        <a href={~p"/"} class="link link-hover">Home</a>
        <a href={~p"/blogs"} class="link link-hover">Blog</a>
        <a href={~p"/toolbox"} class="link link-hover">Toolbox</a>
        <a href={~p"/about"} class="link link-hover">About</a>
      </div>
      <div class="grid grid-flow-col gap-4">
        <a href="/toolbox/geoip2" class="link link-hover">GeoIP2 Database</a>
        <a href="/toolbox/whois" class="link link-hover">Domain/IP Whois</a>
        <a href="/toolbox/svg2react" class="link link-hover">SVG to React</a>
        <a href="/toolbox/mac_manufacturer" class="link link-hover">MAC Lookup</a>
      </div>
      <div>
        <p>Copyright © Jonathan Gao. All rights reserved</p>
      </div>
    </footer>
    """
  end

  @doc """
  Phoenix 1.8 simplified card component.
  """
  attr :class, :string, default: nil
  attr :rest, :global
  slot :header, doc: "Card header content"
  slot :body, doc: "Card body content"
  slot :footer, doc: "Card footer content"
  slot :inner_block, doc: "Alternative to body slot"

  def card(assigns) do
    ~H"""
    <div class={["card bg-base-100 shadow-xl", @class]} {@rest}>
      <div :if={@header != []} class="card-header">
        <%= render_slot(@header) %>
      </div>
      <div class="card-body">
        <%= if @body != [] do %>
          <%= render_slot(@body) %>
        <% else %>
          <%= render_slot(@inner_block) %>
        <% end %>
      </div>
      <div :if={@footer != []} class="card-footer">
        <%= render_slot(@footer) %>
      </div>
    </div>
    """
  end

  @doc """
  Phoenix 1.8 simplified alert component.
  """
  attr :type, :string, default: "info", values: ["info", "success", "warning", "error"]
  attr :class, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def alert(assigns) do
    ~H"""
    <div class={["alert", "alert-#{@type}", @class]} {@rest}>
      <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" class="stroke-current shrink-0 w-6 h-6">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"></path>
      </svg>
      <span><%= render_slot(@inner_block) %></span>
    </div>
    """
  end

  @doc """
  Phoenix 1.8 simplified badge component.
  """
  attr :type, :string, default: "primary", values: ["primary", "secondary", "accent", "info", "success", "warning", "error", "ghost"]
  attr :class, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def badge(assigns) do
    ~H"""
    <div class={["badge", "badge-#{@type}", @class]} {@rest}>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end

  @doc """
  Phoenix 1.8 simplified modal component.
  """
  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :on_cancel, JS, default: %JS{}
  attr :on_confirm, JS, default: %JS{}
  attr :rest, :global
  slot :header, doc: "Modal header content"
  slot :inner_block, doc: "Modal body content"
  slot :footer, doc: "Modal footer content"

  def modal(assigns) do
    ~H"""
    <div id={@id} phx-mounted={@show && show_modal(@id)} class={["modal", @show && "modal-open"]} {@rest}>
      <div class="modal-box">
        <form method="dialog" class="modal-backdrop">
          <button phx-click={@on_cancel}>close</button>
        </form>
        <div :if={@header != []} class="modal-header">
          <%= render_slot(@header) %>
        </div>
        <div class="modal-body">
          <%= render_slot(@inner_block) %>
        </div>
        <div :if={@footer != []} class="modal-footer">
          <%= render_slot(@footer) %>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Phoenix 1.8 simplified loading spinner component.
  """
  attr :class, :string, default: nil
  attr :size, :string, default: "md", values: ["xs", "sm", "md", "lg"]
  attr :rest, :global

  def spinner(assigns) do
    ~H"""
    <span class={["loading loading-spinner loading-#{@size}", @class]} {@rest}></span>
    """
  end

  @doc """
  Phoenix 1.8 simplified table component.
  """
  attr :class, :string, default: nil
  attr :rest, :global
  slot :header, doc: "Table header content"
  slot :body, doc: "Table body content"

  def table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table class={["table table-zebra", @class]} {@rest}>
        <thead :if={@header != []}>
          <tr><%= render_slot(@header) %></tr>
        </thead>
        <tbody :if={@body != []}>
          <%= render_slot(@body) %>
        </tbody>
      </table>
    </div>
    """
  end

  ## Phoenix 1.8 Helper Functions

  defp show_modal(js \\ %JS{}, id) do
    js
    |> JS.show(to: "##{id}")
    |> JS.add_class("modal-open", to: "##{id}")
  end

  defp hide_modal(js \\ %JS{}, id) do
    js
    |> JS.hide(to: "##{id}")
    |> JS.remove_class("modal-open", to: "##{id}")
  end

  defp translate_error({msg, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(GSMLG.Web.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(GSMLG.Web.Gettext, "errors", msg, opts)
    end
  end

  defp translate_error(msg) when is_binary(msg), do: msg

  defp live_flash(flash, key) when is_map(flash) do
    Map.get(flash, Atom.to_string(key))
  end

  defp live_flash(_flash, _key), do: nil
end