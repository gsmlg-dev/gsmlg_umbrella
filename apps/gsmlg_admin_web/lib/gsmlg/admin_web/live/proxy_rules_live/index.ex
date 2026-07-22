defmodule GSMLG.AdminWeb.ProxyRulesLive.Index do
  use GSMLG.AdminWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:error, :not_ready} = GSMLG.ProxyRules.metadata()

    {:ok,
     assign(socket,
       page_title: "Proxy Rules",
       state: %{
         status: :not_ready,
         generation: nil,
         compiled_at: nil,
         proxy_count: nil,
         direct_count: nil,
         artifacts: [],
         sources: [
           %{id: "remote-gfwlist", label: "Remote GFWList"},
           %{id: "local-proxy-list", label: "Local proxy list"},
           %{id: "local-direct-list", label: "Local direct list"}
         ],
         diagnostics: [
           %{id: "invalid", label: "Invalid", value: nil},
           %{id: "unsupported", label: "Unsupported", value: nil},
           %{id: "duplicate", label: "Duplicate", value: nil},
           %{id: "collapsed", label: "Collapsed", value: nil},
           %{id: "conflict", label: "Conflict", value: nil}
         ]
       }
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title} active_menu="proxy_rules_dashboard">
      <div id="proxy-rules-dashboard" class="space-y-8 p-6 lg:p-8">
        <header class="flex flex-col gap-4 md:flex-row md:justify-between">
          <div class="space-y-2">
            <div class="flex items-center gap-3">
              <h1 class="text-3xl font-bold">Proxy Rules</h1>
              <.dm_badge id="proxy-rules-status" variant="warning" soft>Not ready</.dm_badge>
            </div>
            <p class="text-on-surface-variant">
              No artifact has been published. Operational metadata will appear after the first
              successful compilation.
            </p>
          </div>

          <div class="space-y-2">
            <.dm_btn
              id="proxy-rules-refresh"
              variant="primary"
              disabled
              aria-disabled="true"
              aria-describedby="proxy-rules-refresh-help"
            >
              Refresh remote source
            </.dm_btn>
            <p id="proxy-rules-refresh-help" class="text-sm text-on-surface-variant">
              Remote source service is not available yet.
            </p>
          </div>
        </header>

        <section class="grid gap-4 sm:grid-cols-2 xl:grid-cols-4" aria-label="Summary">
          <.dm_card id="proxy-rules-generation" variant="bordered">
            <:title>Generation</:title>
            <p>{display_value(@state.generation)}</p>
          </.dm_card>
          <.dm_card id="proxy-rules-compiled-at" variant="bordered">
            <:title>Compiled at</:title>
            <p>{display_value(@state.compiled_at)}</p>
          </.dm_card>
          <.dm_card id="proxy-rules-proxy-count" variant="bordered">
            <:title>Proxy rules</:title>
            <p>{display_value(@state.proxy_count)}</p>
          </.dm_card>
          <.dm_card id="proxy-rules-direct-count" variant="bordered">
            <:title>Direct rules</:title>
            <p>{display_value(@state.direct_count)}</p>
          </.dm_card>
        </section>

        <section class="space-y-4" aria-labelledby="proxy-rules-sources-heading">
          <h2 id="proxy-rules-sources-heading" class="text-2xl font-semibold">Sources</h2>
          <div class="grid gap-4 lg:grid-cols-3">
            <.dm_card
              :for={source <- @state.sources}
              id={"proxy-rules-source-#{source.id}"}
              variant="bordered"
            >
              <:title>{source.label}</:title>
              <.dm_badge variant="ghost" soft>Not available</.dm_badge>
            </.dm_card>
          </div>
        </section>

        <section aria-labelledby="proxy-rules-artifacts-heading">
          <.dm_card id="proxy-rules-artifacts" variant="bordered" body_class="space-y-4">
            <:title>
              <h2 id="proxy-rules-artifacts-heading" class="text-2xl font-semibold">
                Artifacts
              </h2>
            </:title>
            <.dm_table id="proxy-rules-artifacts-table" data={@state.artifacts} border hover>
              <:col :let={_artifact} label="List">—</:col>
              <:col :let={_artifact} label="Format">—</:col>
              <:col :let={_artifact} label="Size">—</:col>
              <:col :let={_artifact} label="ETag">—</:col>
              <:col :let={_artifact} label="Last modified">—</:col>
              <:col :let={_artifact} label="Download">—</:col>
            </.dm_table>
            <p id="proxy-rules-artifacts-empty" class="text-sm text-on-surface-variant">
              No artifacts have been published.
            </p>
          </.dm_card>
        </section>

        <section class="space-y-4" aria-labelledby="proxy-rules-diagnostics-heading">
          <h2 id="proxy-rules-diagnostics-heading" class="text-2xl font-semibold">
            Diagnostics
          </h2>
          <div id="proxy-rules-diagnostics" class="grid gap-4 sm:grid-cols-2 xl:grid-cols-5">
            <.dm_card
              :for={diagnostic <- @state.diagnostics}
              id={"proxy-rules-diagnostic-#{diagnostic.id}"}
              variant="bordered"
            >
              <:title>{diagnostic.label}</:title>
              <p>{display_value(diagnostic.value)}</p>
            </.dm_card>
          </div>
          <p id="proxy-rules-diagnostic-sample-empty" class="text-sm text-on-surface-variant">
            No diagnostic entries are available.
          </p>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp display_value(nil), do: "Not available"
  defp display_value(value), do: to_string(value)
end
