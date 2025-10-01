defmodule GSMLG.Web.Phoenix18DemoLive do
  use GSMLG.Web, :live_view

  @moduledoc """
  Phoenix 1.8 Demo LiveView showcasing the new unified layout system and features.
  """

  def mount(_params, _session, socket) do
    {:ok, assign(socket,
      page_title: "Phoenix 1.8 Features Demo",
      themes: available_themes(),
      current_theme: "light",
      scope_info: get_scope_info(socket)
    )}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  def handle_event("set_theme", %{"theme" => theme}, socket) do
    {:noreply, assign(socket, :current_theme, theme)}
  end

  def render(assigns) do
    ~H"""
    <!-- Phoenix 1.8: Using existing layout templates with new components -->
    <Layouts.root page_title={@page_title} class="bg-gradient-to-br from-base-100 to-base-300">
      <!-- Enhanced header with Phoenix 1.8 patterns -->
      <Layouts.phoenix18_header class="bg-gradient-to-r from-primary to-secondary" />

      <!-- Main content wrapped in unified wrapper -->
      <Layouts.unified_wrapper class="py-8">
        <div class="max-w-4xl mx-auto px-4">
        <div class="card bg-base-100 shadow-xl">
          <div class="card-body">
            <h2 class="card-title text-3xl mb-6">🚀 Phoenix 1.8 Features Demo</h2>

            <!-- Scopes Pattern Demo -->
            <div class="alert alert-info mb-6">
              <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" class="stroke-current shrink-0 w-6 h-6">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"></path>
              </svg>
              <span><strong>Scopes Pattern:</strong> {@scope_info}</span>
            </div>

            <!-- Magic Links Demo -->
            <div class="mb-6">
              <h3 class="text-xl font-bold mb-3">✨ Magic Link Authentication</h3>
              <p class="mb-4">Experience passwordless authentication with magic links!</p>
              <a href={~p"/auth/magic-link/new"} class="btn btn-primary">
                Try Magic Link Login
              </a>
            </div>

            <!-- DaisyUI Theming Demo -->
            <div class="mb-6">
              <h3 class="text-xl font-bold mb-3">🎨 DaisyUI Theming</h3>
              <p class="mb-4">Current theme: <span class="badge badge-primary">{@current_theme}</span></p>
              <div class="flex flex-wrap gap-2 mb-4">
                <%= for theme <- @themes do %>
                  <button
                    phx-click="set_theme"
                    phx-value-theme={theme}
                    class={"btn btn-sm #{if theme == @current_theme, do: "btn-active", else: "btn-ghost"}"}
                  >
                    <%= Phoenix.Naming.humanize(theme) %>
                  </button>
                <% end %>
              </div>
            </div>

            <!-- Unified Layout System -->
            <div class="mb-6">
              <h3 class="text-xl font-bold mb-3">📐 Unified Layout System</h3>
              <p class="mb-4">This page demonstrates Phoenix 1.8's explicit layout system with:</p>
              <ul class="list-disc list-inside space-y-2">
                <li>Function component-based layouts</li>
                <li>Explicit layout calls instead of implicit configuration</li>
                <li>Composable layout slots (header, footer, sidebar)</li>
                <li>DaisyUI integration for modern styling</li>
              </ul>
            </div>

            <!-- Core Components Demo -->
            <div class="mb-6">
              <h3 class="text-xl font-bold mb-3">🧩 Phoenix 1.8 Components</h3>
              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div class="card bg-base-200">
                  <div class="card-body">
                    <h4 class="card-title">Buttons</h4>
                    <div class="flex flex-wrap gap-2">
                      <button class="btn btn-primary">Primary</button>
                      <button class="btn btn-secondary">Secondary</button>
                      <button class="btn btn-accent">Accent</button>
                      <button class="btn btn-ghost">Ghost</button>
                    </div>
                  </div>
                </div>
                <div class="card bg-base-200">
                  <div class="card-body">
                    <h4 class="card-title">Alerts</h4>
                    <div class="alert alert-success">
                      <svg xmlns="http://www.w3.org/2000/svg" class="stroke-current shrink-0 h-6 w-6" fill="none" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z" />
                      </svg>
                      <span>Success! Phoenix 1.8 is working great.</span>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>

        <!-- Phoenix 1.8 AGENTS.md demo -->
        <div class="alert alert-warning">
          <svg xmlns="http://www.w3.org/2000/svg" class="stroke-current shrink-0 h-6 w-6" fill="none" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4c-.77-.833-1.964-.833-2.732 0L3.732 16.5c-.77.833.192 2.5 1.732 2.5z" />
          </svg>
          <span>This application includes AGENTS.md for AI-assisted development!</span>
        </div>
        </div>
      </Layouts.unified_wrapper>

      <!-- Enhanced footer with Phoenix 1.8 patterns -->
      <Layouts.phoenix18_footer />
    </Layouts.root>
    """
  end

  defp available_themes do
    [
      "light", "dark", "cupcake", "bumblebee", "emerald", "corporate",
      "synthwave", "retro", "cyberpunk", "valentine", "halloween", "garden",
      "forest", "aqua", "lofi", "pastel", "fantasy", "wireframe"
    ]
  end

  defp get_scope_info(socket) do
    case socket.assigns[:current_scope] do
      nil -> "No scope available - user not authenticated"
      scope -> "Scope active for user: #{scope.user.username}"
    end
  end
end