defmodule GSMLG.AdminWeb.CommanderLive.TokensLive do
  @moduledoc """
  LiveView for managing commander agent tokens.

  Provides token generation, listing, revocation, and regeneration.
  """

  # Suppress undefined module warnings for Commander modules (loaded at runtime)
  @compile {:no_warn_undefined, [GSMLG.Commander.Token, GSMLG.Commander.TokenManager]}

  use GSMLG.AdminWeb, :live_view

  alias GSMLG.Commander.{Token, TokenManager}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(GSMLG.PubSub, "commander:tokens")
    end

    {:ok,
     socket
     |> assign(:page_title, "Agent Tokens")
     |> assign(:tokens, [])
     |> assign(:show_modal, nil)
     |> assign(:selected_token, nil)
     |> assign(:generated_token, nil)
     |> assign(:form, to_form(default_form_params(), as: :token))
     |> fetch_tokens()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:show_modal, nil)
    |> assign(:selected_token, nil)
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:show_modal, :new)
    |> assign(:form, to_form(default_form_params(), as: :token))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title} active_menu="commander_tokens">
      <div class="p-6">
        <div class="mb-6">
          <h1 class="text-2xl font-bold text-gray-900 dark:text-white">Agent Tokens</h1>
          <p class="mt-2 text-gray-600 dark:text-gray-400">
            Agent tokens allow commander agents to authenticate with the server.
            Generate a token, then configure your agent with the token value.
          </p>
        </div>

        <div class="mb-4">
          <.link
            patch={~p"/commander/tokens/new"}
            class="inline-flex items-center px-4 py-2 bg-blue-600 text-white rounded-md hover:bg-blue-700 transition-colors"
          >
            <svg class="w-5 h-5 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M12 4v16m8-8H4"
              />
            </svg>
            Generate New Token
          </.link>
        </div>

        <div class="bg-white dark:bg-gray-800 shadow-md rounded-lg overflow-hidden">
          <table class="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
            <thead class="bg-gray-50 dark:bg-gray-700">
              <tr>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">
                  Name
                </th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">
                  Created
                </th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">
                  Last Used
                </th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">
                  Status
                </th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">
                  Actions
                </th>
              </tr>
            </thead>
            <tbody class="bg-white dark:bg-gray-800 divide-y divide-gray-200 dark:divide-gray-700">
              <%= for token <- @tokens do %>
                <tr class="hover:bg-gray-50 dark:hover:bg-gray-700">
                  <td class="px-6 py-4 whitespace-nowrap">
                    <div class="flex items-center">
                      <div>
                        <div class="text-sm font-medium text-gray-900 dark:text-white">
                          {token.name}
                        </div>
                        <div class="text-sm text-gray-500 dark:text-gray-400 font-mono">
                          {token.token_prefix}...
                        </div>
                      </div>
                    </div>
                  </td>
                  <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-500 dark:text-gray-400">
                    {format_date(token.created_at)}
                  </td>
                  <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-500 dark:text-gray-400">
                    {format_last_used(token.last_used_at)}
                  </td>
                  <td class="px-6 py-4 whitespace-nowrap">
                    <.status_badge status={Token.status(token)} />
                  </td>
                  <td class="px-6 py-4 whitespace-nowrap text-sm">
                    <div class="flex space-x-2">
                      <button
                        phx-click="view_token"
                        phx-value-id={token.id}
                        class="text-blue-600 hover:text-blue-800 dark:text-blue-400 dark:hover:text-blue-300"
                      >
                        View
                      </button>
                      <%= unless token.revoked do %>
                        <button
                          phx-click="regenerate_token"
                          phx-value-id={token.id}
                          class="text-yellow-600 hover:text-yellow-800 dark:text-yellow-400 dark:hover:text-yellow-300"
                          data-confirm="Are you sure you want to regenerate this token? The old token value will be invalidated."
                        >
                          Regenerate
                        </button>
                        <button
                          phx-click="revoke_token"
                          phx-value-id={token.id}
                          class="text-red-600 hover:text-red-800 dark:text-red-400 dark:hover:text-red-300"
                          data-confirm="Are you sure you want to revoke this token? Connected agents will be disconnected."
                        >
                          Revoke
                        </button>
                      <% else %>
                        <button
                          phx-click="delete_token"
                          phx-value-id={token.id}
                          class="text-red-600 hover:text-red-800 dark:text-red-400 dark:hover:text-red-300"
                          data-confirm="Are you sure you want to permanently delete this token?"
                        >
                          Delete
                        </button>
                      <% end %>
                    </div>
                  </td>
                </tr>
              <% end %>
              <%= if Enum.empty?(@tokens) do %>
                <tr>
                  <td colspan="5" class="px-6 py-12 text-center text-gray-500 dark:text-gray-400">
                    No tokens found. Generate a new token to get started.
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>

        <%= if @show_modal == :new do %>
          <.modal id="new-token-modal" show on_cancel={JS.patch(~p"/commander/tokens")}>
            <:title>Generate New Token</:title>
            <.form
              for={@form}
              phx-submit="generate_token"
              phx-change="validate_token"
              class="space-y-4"
            >
              <div>
                <label class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                  Token Name *
                </label>
                <input
                  type="text"
                  name="token[name]"
                  value={@form[:name].value}
                  required
                  class="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md shadow-sm focus:ring-blue-500 focus:border-blue-500 dark:bg-gray-700 dark:text-white"
                  placeholder="production-web-servers"
                />
              </div>

              <div>
                <label class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                  Description (optional)
                </label>
                <textarea
                  name="token[description]"
                  rows="2"
                  class="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md shadow-sm focus:ring-blue-500 focus:border-blue-500 dark:bg-gray-700 dark:text-white"
                  placeholder="Token for production web tier servers"
                ><%= @form[:description].value %></textarea>
              </div>

              <div>
                <label class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                  Expiration
                </label>
                <select
                  name="token[expires_in]"
                  class="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md shadow-sm focus:ring-blue-500 focus:border-blue-500 dark:bg-gray-700 dark:text-white"
                >
                  <option value="">Never expires</option>
                  <option value="2592000">30 days</option>
                  <option value="5184000">60 days</option>
                  <option value="7776000">90 days</option>
                  <option value="31536000">1 year</option>
                </select>
              </div>

              <div>
                <label class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">
                  Allowed Capabilities
                </label>
                <div class="space-y-2">
                  <%= for cap <- Token.all_capabilities() do %>
                    <label class="flex items-center">
                      <input
                        type="checkbox"
                        name="token[capabilities][]"
                        value={cap}
                        checked={cap in (@form[:capabilities].value || Token.all_capabilities())}
                        class="h-4 w-4 text-blue-600 focus:ring-blue-500 border-gray-300 rounded"
                      />
                      <span class="ml-2 text-sm text-gray-700 dark:text-gray-300">
                        {capability_label(cap)}
                      </span>
                    </label>
                  <% end %>
                </div>
              </div>

              <div>
                <label class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                  Auto-assign Tags (comma separated)
                </label>
                <input
                  type="text"
                  name="token[auto_tags]"
                  value={@form[:auto_tags].value}
                  class="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md shadow-sm focus:ring-blue-500 focus:border-blue-500 dark:bg-gray-700 dark:text-white"
                  placeholder="production, web-tier"
                />
              </div>

              <div class="flex justify-end space-x-3 pt-4">
                <.link
                  patch={~p"/commander/tokens"}
                  class="px-4 py-2 border border-gray-300 dark:border-gray-600 rounded-md text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-700"
                >
                  Cancel
                </.link>
                <button
                  type="submit"
                  class="px-4 py-2 bg-blue-600 text-white rounded-md hover:bg-blue-700"
                >
                  Generate Token
                </button>
              </div>
            </.form>
          </.modal>
        <% end %>

        <%= if @show_modal == :generated do %>
          <.modal id="generated-token-modal" show on_cancel={JS.push("close_modal")}>
            <:title>Token Generated Successfully</:title>
            <div class="space-y-4">
              <div class="bg-yellow-50 dark:bg-yellow-900/30 border-l-4 border-yellow-400 p-4">
                <div class="flex">
                  <div class="flex-shrink-0">
                    <svg class="h-5 w-5 text-yellow-400" viewBox="0 0 20 20" fill="currentColor">
                      <path
                        fill-rule="evenodd"
                        d="M8.257 3.099c.765-1.36 2.722-1.36 3.486 0l5.58 9.92c.75 1.334-.213 2.98-1.742 2.98H4.42c-1.53 0-2.493-1.646-1.743-2.98l5.58-9.92zM11 13a1 1 0 11-2 0 1 1 0 012 0zm-1-8a1 1 0 00-1 1v3a1 1 0 002 0V6a1 1 0 00-1-1z"
                        clip-rule="evenodd"
                      />
                    </svg>
                  </div>
                  <div class="ml-3">
                    <p class="text-sm text-yellow-700 dark:text-yellow-200">
                      Copy this token now. You won't be able to see it again!
                    </p>
                  </div>
                </div>
              </div>

              <div class="relative">
                <input
                  type="text"
                  id="generated-token"
                  value={@generated_token}
                  readonly
                  class="w-full px-3 py-2 pr-12 font-mono text-sm bg-gray-100 dark:bg-gray-700 border border-gray-300 dark:border-gray-600 rounded-md"
                />
                <button
                  type="button"
                  phx-hook="Clipboard"
                  id="copy-token-btn"
                  data-clipboard-target="#generated-token"
                  class="absolute right-2 top-1/2 -translate-y-1/2 p-1 hover:bg-gray-200 dark:hover:bg-gray-600 rounded"
                >
                  <svg
                    class="w-5 h-5 text-gray-500"
                    fill="none"
                    stroke="currentColor"
                    viewBox="0 0 24 24"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M8 5H6a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2v-1M8 5a2 2 0 002 2h2a2 2 0 002-2M8 5a2 2 0 012-2h2a2 2 0 012 2m0 0h2a2 2 0 012 2v3m2 4H10m0 0l3-3m-3 3l3 3"
                    />
                  </svg>
                </button>
              </div>

              <div class="mt-4">
                <h4 class="text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">
                  Agent Configuration Example (config.toml):
                </h4>
                <pre class="bg-gray-100 dark:bg-gray-700 p-4 rounded-md text-sm overflow-x-auto"><code class="text-gray-800 dark:text-gray-200"># Commander Agent Configuration
    [server]
    url = "wss://commander.example.com/agent/connect"
    token = "<%= @generated_token %>"

    [agent]
    hostname = "web-prod-01"
    heartbeat_interval = 30

    [capabilities]
    shell = true
    files = true
    processes = true
    system_info = true</code></pre>
              </div>

              <div class="flex justify-end pt-4">
                <button
                  type="button"
                  phx-click="close_modal"
                  class="px-4 py-2 bg-blue-600 text-white rounded-md hover:bg-blue-700"
                >
                  Done
                </button>
              </div>
            </div>
          </.modal>
        <% end %>

        <%= if @show_modal == :details && @selected_token do %>
          <.modal id="token-details-modal" show on_cancel={JS.push("close_modal")}>
            <:title>Token Details</:title>
            <div class="space-y-4">
              <div class="grid grid-cols-2 gap-4">
                <div>
                  <label class="text-sm font-medium text-gray-500 dark:text-gray-400">Name</label>
                  <p class="text-gray-900 dark:text-white">{@selected_token.name}</p>
                </div>
                <div>
                  <label class="text-sm font-medium text-gray-500 dark:text-gray-400">Status</label>
                  <p><.status_badge status={Token.status(@selected_token)} /></p>
                </div>
                <div>
                  <label class="text-sm font-medium text-gray-500 dark:text-gray-400">
                    Token Prefix
                  </label>
                  <p class="font-mono text-gray-900 dark:text-white">
                    {@selected_token.token_prefix}...
                  </p>
                </div>
                <div>
                  <label class="text-sm font-medium text-gray-500 dark:text-gray-400">Use Count</label>
                  <p class="text-gray-900 dark:text-white">{@selected_token.use_count}</p>
                </div>
                <div>
                  <label class="text-sm font-medium text-gray-500 dark:text-gray-400">Created</label>
                  <p class="text-gray-900 dark:text-white">
                    {format_datetime(@selected_token.created_at)}
                  </p>
                </div>
                <div>
                  <label class="text-sm font-medium text-gray-500 dark:text-gray-400">Last Used</label>
                  <p class="text-gray-900 dark:text-white">
                    {format_last_used(@selected_token.last_used_at)}
                  </p>
                </div>
                <%= if @selected_token.expires_at do %>
                  <div>
                    <label class="text-sm font-medium text-gray-500 dark:text-gray-400">Expires</label>
                    <p class="text-gray-900 dark:text-white">
                      {format_datetime(@selected_token.expires_at)}
                    </p>
                  </div>
                <% end %>
              </div>

              <%= if @selected_token.description do %>
                <div>
                  <label class="text-sm font-medium text-gray-500 dark:text-gray-400">
                    Description
                  </label>
                  <p class="text-gray-900 dark:text-white">{@selected_token.description}</p>
                </div>
              <% end %>

              <div>
                <label class="text-sm font-medium text-gray-500 dark:text-gray-400">Capabilities</label>
                <div class="flex flex-wrap gap-2 mt-1">
                  <%= for cap <- @selected_token.capabilities do %>
                    <span class="px-2 py-1 bg-blue-100 dark:bg-blue-900 text-blue-800 dark:text-blue-200 text-xs rounded">
                      {capability_label(cap)}
                    </span>
                  <% end %>
                </div>
              </div>

              <%= if @selected_token.auto_tags != [] do %>
                <div>
                  <label class="text-sm font-medium text-gray-500 dark:text-gray-400">Auto Tags</label>
                  <div class="flex flex-wrap gap-2 mt-1">
                    <%= for tag <- @selected_token.auto_tags do %>
                      <span class="px-2 py-1 bg-gray-100 dark:bg-gray-700 text-gray-800 dark:text-gray-200 text-xs rounded">
                        {tag}
                      </span>
                    <% end %>
                  </div>
                </div>
              <% end %>

              <div class="flex justify-end space-x-3 pt-4">
                <button
                  type="button"
                  phx-click="close_modal"
                  class="px-4 py-2 border border-gray-300 dark:border-gray-600 rounded-md text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-700"
                >
                  Close
                </button>
                <%= unless @selected_token.revoked do %>
                  <button
                    type="button"
                    phx-click="regenerate_token"
                    phx-value-id={@selected_token.id}
                    data-confirm="Are you sure you want to regenerate this token?"
                    class="px-4 py-2 bg-yellow-600 text-white rounded-md hover:bg-yellow-700"
                  >
                    Regenerate
                  </button>
                  <button
                    type="button"
                    phx-click="revoke_token"
                    phx-value-id={@selected_token.id}
                    data-confirm="Are you sure you want to revoke this token?"
                    class="px-4 py-2 bg-red-600 text-white rounded-md hover:bg-red-700"
                  >
                    Revoke
                  </button>
                <% end %>
              </div>
            </div>
          </.modal>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  # Event Handlers

  @impl true
  def handle_event("validate_token", %{"token" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :token))}
  end

  @impl true
  def handle_event("generate_token", %{"token" => params}, socket) do
    user = get_current_user(socket)

    capabilities =
      case params["capabilities"] do
        nil -> Token.all_capabilities()
        caps when is_list(caps) -> Enum.map(caps, &String.to_existing_atom/1)
        _ -> Token.all_capabilities()
      end

    expires_in =
      case params["expires_in"] do
        "" -> nil
        nil -> nil
        val -> String.to_integer(val)
      end

    auto_tags =
      case params["auto_tags"] do
        nil -> []
        "" -> []
        tags -> tags |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
      end

    opts = [
      name: params["name"],
      description: params["description"],
      capabilities: capabilities,
      auto_tags: auto_tags,
      expires_in: expires_in,
      created_by: user.id || "anonymous"
    ]

    case TokenManager.generate_token(opts) do
      {:ok, %{token: plaintext, id: _id}} ->
        {:noreply,
         socket
         |> assign(:show_modal, :generated)
         |> assign(:generated_token, plaintext)
         |> fetch_tokens()
         |> put_flash(:info, "Token generated successfully")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to generate token: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("view_token", %{"id" => id}, socket) do
    case TokenManager.get_token(id) do
      {:ok, token} ->
        {:noreply,
         socket
         |> assign(:show_modal, :details)
         |> assign(:selected_token, token)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Token not found")}
    end
  end

  @impl true
  def handle_event("revoke_token", %{"id" => id}, socket) do
    user = get_current_user(socket)

    case TokenManager.revoke_token(id, user.id || "anonymous") do
      :ok ->
        {:noreply,
         socket
         |> fetch_tokens()
         |> assign(:show_modal, nil)
         |> assign(:selected_token, nil)
         |> put_flash(:info, "Token revoked successfully")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to revoke token: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("regenerate_token", %{"id" => id}, socket) do
    user = get_current_user(socket)

    case TokenManager.regenerate_token(id, user.id || "anonymous") do
      {:ok, %{token: plaintext}} ->
        {:noreply,
         socket
         |> assign(:show_modal, :generated)
         |> assign(:generated_token, plaintext)
         |> assign(:selected_token, nil)
         |> fetch_tokens()
         |> put_flash(:info, "Token regenerated successfully")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to regenerate token: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("delete_token", %{"id" => id}, socket) do
    case TokenManager.delete_token(id) do
      :ok ->
        {:noreply,
         socket
         |> fetch_tokens()
         |> put_flash(:info, "Token deleted successfully")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete token: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_modal, nil)
     |> assign(:generated_token, nil)
     |> assign(:selected_token, nil)}
  end

  @impl true
  def handle_info({:token_revoked, _id}, socket) do
    {:noreply, fetch_tokens(socket)}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # Private Helpers

  defp fetch_tokens(socket) do
    tokens = TokenManager.list_tokens()
    assign(socket, :tokens, tokens)
  rescue
    _ -> assign(socket, :tokens, [])
  end

  defp get_current_user(socket) do
    socket.assigns[:current_user] || %{id: nil}
  end

  defp default_form_params do
    %{
      "name" => "",
      "description" => "",
      "expires_in" => "",
      "capabilities" => Token.all_capabilities(),
      "auto_tags" => ""
    }
  end

  defp format_date(nil), do: "-"

  defp format_date(datetime) do
    Calendar.strftime(datetime, "%b %d, %Y")
  end

  defp format_datetime(nil), do: "-"

  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%b %d, %Y %H:%M")
  end

  defp format_last_used(nil), do: "Never"

  defp format_last_used(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "Just now"
      diff < 3600 -> "#{div(diff, 60)} min ago"
      diff < 86400 -> "#{div(diff, 3600)} hours ago"
      diff < 604_800 -> "#{div(diff, 86400)} days ago"
      true -> format_date(datetime)
    end
  end

  defp capability_label(:shell), do: "Shell (PTY access)"
  defp capability_label(:files), do: "File Browser"
  defp capability_label(:processes), do: "Process Manager"
  defp capability_label(:system_info), do: "System Info"
  defp capability_label(:logs), do: "Log Viewer"
  defp capability_label(:metrics), do: "Metrics"
  defp capability_label(:services), do: "Service Manager"
  defp capability_label(cap), do: to_string(cap)

  # Components

  defp status_badge(assigns) do
    {bg_color, text_color, label} =
      case assigns.status do
        :active ->
          {"bg-green-100 dark:bg-green-900", "text-green-800 dark:text-green-200", "Active"}

        :unused ->
          {"bg-yellow-100 dark:bg-yellow-900", "text-yellow-800 dark:text-yellow-200", "Unused"}

        :expired ->
          {"bg-red-100 dark:bg-red-900", "text-red-800 dark:text-red-200", "Expired"}

        :revoked ->
          {"bg-gray-100 dark:bg-gray-700", "text-gray-800 dark:text-gray-200", "Revoked"}
      end

    assigns = assign(assigns, bg_color: bg_color, text_color: text_color, label: label)

    ~H"""
    <span class={"inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium #{@bg_color} #{@text_color}"}>
      {@label}
    </span>
    """
  end

  defp modal(assigns) do
    ~H"""
    <div
      id={@id}
      class="fixed inset-0 z-50 overflow-y-auto"
      aria-labelledby="modal-title"
      role="dialog"
      aria-modal="true"
    >
      <div class="flex items-center justify-center min-h-screen px-4 pt-4 pb-20 text-center sm:block sm:p-0">
        <div
          class="fixed inset-0 bg-gray-500 bg-opacity-75 transition-opacity"
          phx-click={@on_cancel}
        >
        </div>

        <span class="hidden sm:inline-block sm:align-middle sm:h-screen" aria-hidden="true">
          &#8203;
        </span>

        <div class="inline-block align-bottom bg-white dark:bg-gray-800 rounded-lg px-4 pt-5 pb-4 text-left overflow-hidden shadow-xl transform transition-all sm:my-8 sm:align-middle sm:max-w-lg sm:w-full sm:p-6">
          <div class="flex justify-between items-center mb-4">
            <h3 class="text-lg font-medium text-gray-900 dark:text-white" id="modal-title">
              {render_slot(@title)}
            </h3>
            <button
              type="button"
              class="text-gray-400 hover:text-gray-500"
              phx-click={@on_cancel}
            >
              <svg class="h-6 w-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M6 18L18 6M6 6l12 12"
                />
              </svg>
            </button>
          </div>
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end
end
