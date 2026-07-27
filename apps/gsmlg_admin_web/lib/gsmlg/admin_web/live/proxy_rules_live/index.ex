defmodule GSMLG.AdminWeb.ProxyRulesLive.Index do
  use GSMLG.AdminWeb, :live_view

  alias GSMLG.AdminWeb.ProxyRulesTelemetryBridge
  alias GSMLG.ProxyRules

  @diagnostic_sample_limit 2
  @artifact_paths [
    {:proxy, "Proxy", :raw, "Raw", "proxy-list", "raw"},
    {:proxy, "Proxy", :squid, "Squid", "proxy-list", "squid"},
    {:proxy, "Proxy", :clash, "Clash", "proxy-list", "clash"},
    {:direct, "Direct", :raw, "Raw", "direct-list", "raw"},
    {:direct, "Direct", :squid, "Squid", "direct-list", "squid"},
    {:direct, "Direct", :clash, "Clash", "direct-list", "clash"}
  ]
  @source_defaults [
    {:remote_gfwlist, "remote-gfwlist", "Remote GFWList"},
    {:local_proxy, "local-proxy-list", "Local proxy list"},
    {:local_direct, "local-direct-list", "Local direct list"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(GSMLG.PubSub, ProxyRulesTelemetryBridge.topic())
    end

    {:ok,
     assign(socket,
       page_title: "Proxy Rules",
       state: load_state(ProxyRules.metadata())
     )}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    case ProxyRules.refresh() do
      {:ok, :accepted} ->
        {:noreply, assign(socket, state: %{socket.assigns.state | status: :refreshing})}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, refresh_error(reason))}
    end
  end

  @impl true
  def handle_info({:proxy_rules_status_changed, _measurements, _metadata}, socket) do
    {:noreply, assign(socket, state: load_state(ProxyRules.metadata()))}
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
              <.dm_badge
                id="proxy-rules-status"
                variant={status_variant(@state.status)}
                soft
              >
                {status_label(@state.status)}
              </.dm_badge>
            </div>
            <p id="proxy-rules-summary" class="text-on-surface-variant">
              {status_summary(@state.status)}
            </p>
            <p
              :if={@state.failure}
              id="proxy-rules-last-failure"
              class="text-sm text-error"
            >
              Latest failure: {failure_label(@state.failure)}
            </p>
          </div>

          <div class="space-y-2">
            <.dm_btn
              id="proxy-rules-refresh"
              variant="primary"
              disabled={!refresh_enabled?(@state)}
              phx-click={refresh_enabled?(@state) && "refresh"}
              aria-disabled={to_string(!refresh_enabled?(@state))}
              aria-describedby="proxy-rules-refresh-help"
            >
              <.dm_mdi name="refresh" class="h-4 w-4" /> Refresh remote source
            </.dm_btn>
            <p id="proxy-rules-refresh-help" class="text-sm text-on-surface-variant">
              {refresh_help(@state)}
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
            <p>{display_datetime(@state.compiled_at)}</p>
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
              body_class="space-y-3"
            >
              <:title>{source.label}</:title>
              <.dm_badge variant={source_variant(source.availability)} soft>
                {source_label(source.availability)}
              </.dm_badge>
              <dl class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-sm">
                <dt class="text-on-surface-variant">Version</dt>
                <dd class="min-w-0 truncate font-mono" title={source.version}>
                  {short_hash(source.version)}
                </dd>
                <dt class="text-on-surface-variant">Observed</dt>
                <dd>{display_datetime(source.observed_at)}</dd>
                <dt class="text-on-surface-variant">Last success</dt>
                <dd>{display_datetime(source.last_success_at)}</dd>
                <dt :if={source.etag} class="text-on-surface-variant">ETag</dt>
                <dd :if={source.etag} class="min-w-0 truncate font-mono" title={source.etag}>
                  {short_etag(source.etag)}
                </dd>
                <dt :if={source.last_modified} class="text-on-surface-variant">Last modified</dt>
                <dd :if={source.last_modified}>{source.last_modified}</dd>
              </dl>
            </.dm_card>
          </div>
        </section>

        <section class="space-y-4" aria-labelledby="proxy-rules-artifacts-heading">
          <h2 id="proxy-rules-artifacts-heading" class="text-2xl font-semibold">Artifacts</h2>
          <.dm_card id="proxy-rules-artifacts" variant="bordered">
            <.dm_table
              :if={@state.artifacts != []}
              id="proxy-rules-artifacts-table"
              data={@state.artifacts}
              border
              hover
            >
              <:col :let={artifact} label="List">{artifact.list_label}</:col>
              <:col :let={artifact} label="Format">{artifact.format_label}</:col>
              <:col :let={artifact} label="Size">{format_bytes(artifact.content_length)}</:col>
              <:col :let={artifact} label="ETag">
                <span class="font-mono" title={artifact.etag}>{short_etag(artifact.etag)}</span>
              </:col>
              <:col :let={artifact} label="Last modified">
                {display_datetime(artifact.last_modified)}
              </:col>
              <:col :let={artifact} label="Download">
                <a
                  href={artifact.url}
                  class="text-primary underline-offset-4 hover:underline"
                  aria-label={"Download #{artifact.list_label} #{artifact.format_label}"}
                >
                  Download
                </a>
              </:col>
            </.dm_table>
            <p
              :if={@state.artifacts == []}
              id="proxy-rules-artifacts-empty"
              class="text-sm text-on-surface-variant"
            >
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
              :for={diagnostic <- @state.diagnostic_counts}
              id={"proxy-rules-diagnostic-#{diagnostic.id}"}
              variant="bordered"
            >
              <:title>{diagnostic.label}</:title>
              <p>{display_value(diagnostic.value)}</p>
            </.dm_card>
          </div>
          <ul
            :if={@state.diagnostic_samples != []}
            id="proxy-rules-diagnostic-samples"
            class="space-y-2 text-sm"
          >
            <li
              :for={sample <- @state.diagnostic_samples}
              class="rounded border border-outline-variant p-3"
            >
              <span class="font-medium">
                {atom_label(sample.kind)} · {atom_label(sample.source)}
              </span>
              <span class="text-on-surface-variant">
                · {atom_label(sample.reason)} · {display_value(sample.location)}
              </span>
              <code :if={sample.sample} class="mt-1 block break-all">{sample.sample}</code>
            </li>
          </ul>
          <p
            :if={@state.diagnostic_samples == []}
            id="proxy-rules-diagnostic-sample-empty"
            class="text-sm text-on-surface-variant"
          >
            No diagnostic entries are available.
          </p>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp load_state({:ok, metadata}) do
    statistics = Map.get(metadata, :statistics, %{})
    source_statistics = Map.get(statistics, :sources, %{})

    %{
      status: Map.get(metadata, :readiness, :not_ready),
      refresh_available: Map.has_key?(metadata, :sources),
      generation: Map.get(metadata, :generation),
      compiled_at: Map.get(metadata, :compiled_at),
      proxy_count: Map.get(statistics, :proxy_rule_count),
      direct_count: Map.get(statistics, :direct_rule_count),
      sources: source_rows(Map.get(metadata, :sources, %{})),
      artifacts: artifact_rows(Map.get(metadata, :rendered_outputs, %{})),
      diagnostic_counts: diagnostic_counts(statistics, source_statistics),
      diagnostic_samples:
        metadata |> Map.get(:diagnostics, []) |> Enum.take(@diagnostic_sample_limit),
      failure: Map.get(metadata, :operational_status) || Map.get(metadata, :last_error)
    }
  end

  defp load_state({:error, :not_available}) do
    load_state({:ok, %{readiness: :not_ready}})
  end

  defp source_rows(sources) do
    Enum.map(@source_defaults, fn {key, id, label} ->
      source = Map.get(sources, key, %{})

      %{
        id: id,
        label: label,
        availability: Map.get(source, :availability, :missing),
        version: Map.get(source, :version),
        observed_at: Map.get(source, :observed_at),
        last_success_at: Map.get(source, :last_success_at),
        etag: Map.get(source, :etag),
        last_modified: Map.get(source, :last_modified)
      }
    end)
  end

  defp artifact_rows(outputs) do
    base_url = GSMLG.Web.Endpoint.url()

    Enum.flat_map(@artifact_paths, fn
      {list, list_label, format, format_label, list_path, format_path} ->
        case get_in(outputs, [list, format]) do
          output when is_map(output) ->
            [
              %{
                list_label: list_label,
                format_label: format_label,
                content_length: Map.get(output, :content_length),
                etag: Map.get(output, :etag),
                last_modified: Map.get(output, :last_modified),
                url: "#{base_url}/api/proxy-rules/#{list_path}/#{format_path}"
              }
            ]

          _missing ->
            []
        end
    end)
  end

  defp diagnostic_counts(statistics, source_statistics) do
    [
      %{id: "invalid", label: "Invalid", value: sum_source_stat(source_statistics, :invalid)},
      %{
        id: "unsupported",
        label: "Unsupported",
        value: sum_source_stat(source_statistics, :unsupported)
      },
      %{id: "duplicate", label: "Duplicate", value: Map.get(statistics, :duplicate_count)},
      %{id: "collapsed", label: "Collapsed", value: Map.get(statistics, :collapsed_count)},
      %{id: "conflict", label: "Conflict", value: Map.get(statistics, :conflict_count)}
    ]
  end

  defp sum_source_stat(source_statistics, _key) when map_size(source_statistics) == 0, do: nil

  defp sum_source_stat(source_statistics, key) do
    Enum.reduce([:gfwlist, :local_proxy, :local_direct], 0, fn source, total ->
      total + (get_in(source_statistics, [source, key]) || 0)
    end)
  end

  defp refresh_enabled?(state),
    do: state.refresh_available and state.status != :refreshing

  defp status_label(:not_ready), do: "Not ready"
  defp status_label(:refreshing), do: "Refreshing"
  defp status_label(:ready), do: "Ready"
  defp status_label(:stale), do: "Stale"
  defp status_label(_status), do: "Not ready"

  defp status_variant(:ready), do: "success"
  defp status_variant(:refreshing), do: "info"
  defp status_variant(:stale), do: "warning"
  defp status_variant(_status), do: "warning"

  defp status_summary(:not_ready),
    do: "No artifact has been published. Source and compilation details may still be available."

  defp status_summary(:refreshing),
    do:
      "A source refresh or compilation is in progress. Published artifacts, if any, remain available."

  defp status_summary(:ready), do: "The latest successful generation is ready for download."

  defp status_summary(:stale),
    do: "The last successful generation remains available while a source or operation is stale."

  defp status_summary(_status), do: status_summary(:not_ready)

  defp refresh_help(%{refresh_available: false}),
    do: "Remote source service is not available."

  defp refresh_help(%{status: :refreshing}), do: "A refresh is already in progress."
  defp refresh_help(_state), do: "Fetch the remote source and compile a new generation."

  defp source_label(:ready), do: "Ready"
  defp source_label(:stale), do: "Stale"
  defp source_label(:missing), do: "Missing"
  defp source_label(_availability), do: "Missing"

  defp source_variant(:ready), do: "success"
  defp source_variant(:stale), do: "warning"
  defp source_variant(_availability), do: "ghost"

  defp refresh_error(:not_available), do: "Refresh is not available right now."
  defp refresh_error(_reason), do: "Refresh could not be started."

  defp failure_label(%{kind: kind, reason: reason}),
    do: "#{atom_label(kind)}: #{atom_label(reason)}"

  defp failure_label(_failure), do: "Operation failed"

  defp display_value(nil), do: "Not available"
  defp display_value(:system), do: "System"
  defp display_value(value), do: to_string(value)

  defp display_datetime(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%SZ")

  defp display_datetime(_value), do: "Not available"

  defp short_hash(nil), do: "Not available"
  defp short_hash(value) when is_binary(value), do: String.slice(value, 0, 12)

  defp short_etag(nil), do: "Not available"
  defp short_etag(value) when is_binary(value), do: String.slice(value, 0, 20)

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 0, do: "#{bytes} B"
  defp format_bytes(_bytes), do: "Not available"

  defp atom_label(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> String.replace("_", " ")
  end

  defp atom_label(_value), do: "unknown"
end
