defmodule GSMLG.AdminWeb.PKILive.Components.PEMViewer do
  @moduledoc """
  Component for displaying and copying PEM-encoded data.
  """
  use GSMLG.AdminWeb, :html

  attr :pem, :string, required: true
  attr :label, :string, default: "PEM"
  attr :class, :string, default: ""
  attr :id, :string, required: true

  def pem_viewer(assigns) do
    ~H"""
    <div class={["card bg-base-200", @class]}>
      <div class="card-body">
        <div class="flex justify-between items-center mb-2">
          <h3 class="card-title text-sm"><%= @label %></h3>
          <div class="flex gap-2">
            <button
              type="button"
              class="btn btn-xs btn-primary"
              phx-click={copy_to_clipboard("##{@id}-content")}
            >
              <.icon name="hero-clipboard-document" class="w-4 h-4" />
              Copy
            </button>
            <button
              type="button"
              class="btn btn-xs btn-secondary"
              phx-click={toggle_visibility("##{@id}-pre")}
            >
              <.icon name="hero-eye" class="w-4 h-4" />
              Toggle
            </button>
          </div>
        </div>
        <pre
          id={"#{@id}-pre"}
          class="bg-base-300 p-4 rounded overflow-x-auto text-xs font-mono max-h-96"
        ><code id={"#{@id}-content"}><%= @pem %></code></pre>
      </div>
    </div>
    """
  end

  defp copy_to_clipboard(selector) do
    JS.dispatch("phx:copy", to: selector)
  end

  defp toggle_visibility(selector) do
    JS.toggle(to: selector)
  end

  # Fallback icon component if not available
  def icon(assigns) do
    ~H"""
    <span class={@class}>
      <%= if String.contains?(@name, "clipboard") do %>
        📋
      <% else %>
        👁️
      <% end %>
    </span>
    """
  end
end
