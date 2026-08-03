defmodule GSMLG.AdminWeb.ProxyRulesLive.Index do
  use GSMLG.AdminWeb, :live_view

  alias GSMLG.AdminWeb.ProxyRulesTelemetryBridge
  alias GSMLG.ProxyRules

  @diagnostic_sample_limit 2
  @local_proxy_error_limit 101
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
       state: load_state(ProxyRules.metadata()),
       local_proxy_form: to_form(%{"domains" => ""}, as: :local_proxy),
       local_proxy_errors: []
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

  def handle_event(
        "add_local_proxy",
        %{"local_proxy" => %{"domains" => domains}},
        socket
      )
      when is_binary(domains) do
    case ProxyRules.add_local_proxy_domains(domains) do
      {:ok, result} ->
        socket =
          socket
          |> assign(
            local_proxy_form: to_form(%{"domains" => ""}, as: :local_proxy),
            local_proxy_errors: []
          )
          |> put_flash(:info, add_result_message(result))
          |> push_event("proxy-rules:source-changed", %{source: "local-proxy"})

        {:noreply, socket}

      {:error, {:invalid_batch, errors}} ->
        {:noreply,
         assign(socket,
           local_proxy_form: to_form(%{"domains" => domains}, as: :local_proxy),
           local_proxy_errors: Enum.take(errors, @local_proxy_error_limit)
         )}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(
           local_proxy_form: to_form(%{"domains" => domains}, as: :local_proxy),
           local_proxy_errors: []
         )
         |> put_flash(:error, add_error_message(reason))}
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
              variant="outline"
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

        <section
          id="proxy-rules-local-source-controls"
          class="grid gap-4 lg:grid-cols-2"
          aria-label="Local proxy controls and source viewer"
        >
          <.dm_card
            id="proxy-rules-local-proxy-card"
            variant="bordered"
            body_class="space-y-4"
          >
            <:title>Add Local Proxy</:title>
            <p class="text-sm text-on-surface-variant">
              Add bare domains to the Local proxy source. The whole batch is rejected if any line
              is invalid.
            </p>

            <.dm_form
              for={@local_proxy_form}
              id="proxy-rules-add-local-proxy"
              class="space-y-3"
              phx-submit="add_local_proxy"
            >
              <.dm_textarea
                field={@local_proxy_form[:domains]}
                id="proxy-rules-local-proxy-domains"
                name={@local_proxy_form[:domains].name}
                label="One domain per line"
                rows={8}
                placeholder="example.com\nsubdomain.example.net"
                aria-describedby="proxy-rules-local-proxy-help proxy-rules-local-proxy-errors"
                aria-invalid={to_string(@local_proxy_errors != [])}
              />
              <p id="proxy-rules-local-proxy-help" class="text-sm text-on-surface-variant">
                Enter one bare domain per line. URLs, wildcards, IP addresses, CIDRs, and comments
                are not accepted.
              </p>
              <ul
                id="proxy-rules-local-proxy-errors"
                role={@local_proxy_errors != [] && "alert"}
                aria-live="polite"
                class="space-y-1 text-sm text-error"
              >
                <li :for={error <- @local_proxy_errors}>
                  Line {display_value(error.line)}: {local_proxy_error_label(error.reason)}
                </li>
              </ul>
              <:actions>
                <.dm_btn id="proxy-rules-add-local-proxy-submit" variant="primary" type="submit">
                  Add domains
                </.dm_btn>
              </:actions>
            </.dm_form>
          </.dm_card>

          <.dm_card
            id="proxy-rules-source-viewer-card"
            variant="bordered"
            body_class="space-y-4"
          >
            <:title>Source viewer</:title>
            <div
              id="proxy-rules-source-viewer"
              phx-hook="ProxyRulesSourceViewer"
              data-page-size="200"
              data-gfwlist-url={~p"/proxy-rules/sources/gfwlist"}
              data-local-proxy-url={~p"/proxy-rules/sources/local-proxy"}
              class="space-y-4"
            >
              <div class="grid gap-3 sm:grid-cols-2" aria-label="Source selection">
                <div class="rounded-lg border border-outline-variant bg-surface-container p-3 text-on-surface">
                  <.dm_btn
                    id="proxy-rules-viewer-source-gfwlist"
                    variant="secondary"
                    size="sm"
                    type="button"
                    data-source="gfwlist"
                    data-loaded="false"
                    aria-controls="proxy-rules-source-viewport"
                    aria-pressed="true"
                  >
                    GFWList
                  </.dm_btn>
                  <.dm_badge
                    id="proxy-rules-viewer-gfwlist-status"
                    variant={source_variant(@state.viewer_gfwlist.availability)}
                    soft
                  >
                    {source_label(@state.viewer_gfwlist.availability)}
                  </.dm_badge>
                  <p
                    id="proxy-rules-viewer-gfwlist-metadata"
                    class="mt-2 text-xs text-on-surface-variant"
                  >
                    {source_line_count(@state.viewer_gfwlist)} · updated {display_datetime(
                      @state.viewer_gfwlist.updated_at
                    )}
                  </p>
                </div>
                <div class="rounded-lg border border-outline-variant bg-surface-container p-3 text-on-surface">
                  <.dm_btn
                    id="proxy-rules-viewer-source-local-proxy"
                    variant="outline"
                    size="sm"
                    type="button"
                    data-source="local-proxy"
                    data-loaded="false"
                    aria-controls="proxy-rules-source-viewport"
                    aria-pressed="false"
                  >
                    Local proxy
                  </.dm_btn>
                  <.dm_badge
                    id="proxy-rules-viewer-local-proxy-status"
                    variant={source_variant(@state.viewer_local_proxy.availability)}
                    soft
                  >
                    {source_label(@state.viewer_local_proxy.availability)}
                  </.dm_badge>
                  <p
                    id="proxy-rules-viewer-local-proxy-metadata"
                    class="mt-2 text-xs text-on-surface-variant"
                  >
                    {source_line_count(@state.viewer_local_proxy)} · updated {display_datetime(
                      @state.viewer_local_proxy.updated_at
                    )}
                  </p>
                </div>
              </div>

              <div class="flex flex-wrap items-center gap-3">
                <.dm_btn
                  id="proxy-rules-view-content"
                  variant="outline"
                  type="button"
                  aria-controls="proxy-rules-source-viewport"
                >
                  View content
                </.dm_btn>
                <p
                  id="proxy-rules-viewer-loading"
                  role="status"
                  aria-live="polite"
                  class="text-sm text-on-surface-variant"
                >
                </p>
                <p
                  id="proxy-rules-viewer-error"
                  role="alert"
                  aria-live="assertive"
                  class="text-sm text-error"
                >
                </p>
              </div>

              <div
                id="proxy-rules-source-viewport"
                phx-update="ignore"
                tabindex="0"
                role="region"
                aria-label="Proxy rule source content"
                class="relative h-96 overflow-auto rounded-lg border border-outline-variant bg-surface-container-low text-on-surface"
              >
                <div id="proxy-rules-source-spacer" aria-hidden="true"></div>
                <div
                  id="proxy-rules-source-rows"
                  class="absolute inset-x-0 top-0 font-mono text-sm"
                >
                </div>
              </div>
            </div>
          </.dm_card>
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
    sources = source_rows(Map.get(metadata, :sources, %{}))

    %{
      status: Map.get(metadata, :readiness, :not_ready),
      refresh_available: Map.has_key?(metadata, :sources),
      generation: Map.get(metadata, :generation),
      compiled_at: Map.get(metadata, :compiled_at),
      proxy_count: Map.get(statistics, :proxy_rule_count),
      direct_count: Map.get(statistics, :direct_rule_count),
      sources: sources,
      viewer_gfwlist: source_for_viewer(sources, :remote_gfwlist),
      viewer_local_proxy: source_for_viewer(sources, :local_proxy),
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
        key: key,
        id: id,
        label: label,
        availability: Map.get(source, :availability, :missing),
        version: Map.get(source, :version),
        line_count: Map.get(source, :line_count, 0),
        observed_at: Map.get(source, :observed_at),
        last_success_at: Map.get(source, :last_success_at),
        updated_at:
          Map.get(source, :fetched_at) || Map.get(source, :last_success_at) ||
            Map.get(source, :observed_at),
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

  defp source_for_viewer(sources, key) do
    Enum.find(
      sources,
      %{availability: :missing, line_count: 0, updated_at: nil},
      &(&1.key == key)
    )
  end

  defp add_result_message(result) do
    added_count = Map.get(result, :added_count, 0)
    duplicate_count = Map.get(result, :duplicate_count, 0)

    add_count_message(added_count)
    |> append_duplicate_message(duplicate_count)
    |> append_durability_warning(Map.get(result, :durability))
    |> append_reconciliation_warning(Map.get(result, :reconciliation))
  end

  defp add_count_message(0), do: "No domains were added."
  defp add_count_message(1), do: "Added 1 domain."
  defp add_count_message(count), do: "Added #{count} domains."

  defp append_duplicate_message(message, 0), do: message

  defp append_duplicate_message(message, 1),
    do: message <> " The batch ignored 1 duplicate."

  defp append_duplicate_message(message, count),
    do: message <> " The batch ignored #{count} duplicates."

  defp append_durability_warning(message, :unknown),
    do: message <> " The source was saved, but durable storage confirmation is unknown."

  defp append_durability_warning(message, _durability), do: message

  defp append_reconciliation_warning(message, {:error, _reason}),
    do:
      message <>
        " The source was saved, but the viewer may be stale because reconciliation failed."

  defp append_reconciliation_warning(message, _reconciliation), do: message

  defp add_error_message(:empty_batch), do: "Enter at least one domain."
  defp add_error_message(:body_too_large), do: "The submitted domains exceed the 8 MiB limit."

  defp add_error_message(:too_many_domains),
    do: "Submit at most 10,000 distinct domains at a time."

  defp add_error_message(:not_available),
    do: "Local proxy source is not available right now."

  defp add_error_message(:outcome_unknown),
    do: "The request timed out and its outcome is unknown. Check the source before retrying."

  defp add_error_message(:permission_denied),
    do: "Local proxy source could not be written: permission denied."

  defp add_error_message(reason)
       when reason in [
              :open_failed,
              :write_failed,
              :sync_failed,
              :close_failed,
              :mode_failed,
              :rename_failed,
              :invalid_target,
              :target_probe_failed
            ],
       do: "Local proxy source could not be written. The existing source was left unchanged."

  defp add_error_message(_reason), do: "Local proxy domains could not be added."

  defp local_proxy_error_label(:leading_dot_not_allowed),
    do: "Leading dots are not allowed"

  defp local_proxy_error_label(:trailing_dot_not_allowed),
    do: "Trailing dots are not allowed"

  defp local_proxy_error_label(:comment_not_allowed), do: "Comments are not allowed"
  defp local_proxy_error_label(:url_not_allowed), do: "URLs are not allowed"
  defp local_proxy_error_label(:path_not_allowed), do: "Paths and CIDRs are not allowed"
  defp local_proxy_error_label(:wildcard_not_allowed), do: "Wildcards are not allowed"
  defp local_proxy_error_label(:invalid_utf8), do: "The domain is not valid UTF-8"

  defp local_proxy_error_label(:too_many_errors),
    do: "Additional invalid lines were omitted"

  defp local_proxy_error_label(:ip_literal), do: "IP addresses are not allowed"
  defp local_proxy_error_label(:domain_too_long), do: "The domain is too long"
  defp local_proxy_error_label(:empty_label), do: "Domain labels cannot be empty"
  defp local_proxy_error_label(:label_too_long), do: "A domain label is too long"
  defp local_proxy_error_label(:invalid_idna), do: "The international domain is invalid"
  defp local_proxy_error_label(:invalid_label), do: "The domain contains an invalid label"
  defp local_proxy_error_label(_reason), do: "The domain is invalid"

  defp source_line_count(%{line_count: 1}), do: "1 line"
  defp source_line_count(%{line_count: count}) when is_integer(count), do: "#{count} lines"
  defp source_line_count(_source), do: "0 lines"

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
