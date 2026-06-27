defmodule GSMLG.AdminWeb.ScoutLive.DashboardLive do
  use GSMLG.AdminWeb, :live_view

  alias GSMLG.Scout.Server

  @jobs_topic "gsmlg_scout:jobs"
  @agents_topic "gsmlg_scout:agents"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(GSMLG.PubSub, @jobs_topic)
      Phoenix.PubSub.subscribe(GSMLG.PubSub, @agents_topic)
    end

    {:ok,
     socket
     |> stream_configure(:jobs, dom_id: &"scout-job-#{&1.job_id}")
     |> stream_configure(:agents, dom_id: &"scout-agent-#{&1.agent_id}")
     |> assign(:page_title, "Scout Dashboard")
     |> assign(:form, to_form(%{"url" => ""}, as: :fetch))
     |> assign_job_stats([])
     |> assign_agent_stats([])
     |> stream(:jobs, [])
     |> stream(:agents, [])}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    jobs = Server.list_fetches()
    agents = Server.list_agents()

    {:noreply,
     socket
     |> assign_job_stats(jobs)
     |> assign_agent_stats(agents)
     |> stream(:jobs, jobs, reset: true)
     |> stream(:agents, agents, reset: true)}
  end

  @impl true
  def handle_event("submit_fetch", %{"fetch" => params}, socket) do
    case Server.submit_fetch(params) do
      {:ok, job} ->
        jobs = Server.list_fetches()

        {:noreply,
         socket
         |> put_flash(:info, "Fetch queued")
         |> assign(:form, to_form(%{"url" => ""}, as: :fetch))
         |> assign_job_stats(jobs)
         |> stream_insert(:jobs, job, at: 0)}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  @impl true
  def handle_info({:job_updated, job}, socket) do
    {:noreply,
     socket
     |> assign_job_stats(Server.list_fetches())
     |> stream_insert(:jobs, job, at: 0)}
  end

  def handle_info({:agent_updated, agent}, socket) do
    agents = Server.list_agents()

    {:noreply,
     socket
     |> assign_agent_stats(agents)
     |> stream_insert(:agents, agent)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title} active_menu="scout_dashboard">
      <div class="scout-page">
        <section class="scout-header">
          <div>
            <h1>Scout Dashboard</h1>
          </div>
          <div class="scout-summary" aria-label="Scout status summary">
            <div class="scout-stat" aria-label={"#{@job_count} jobs"}>
              <strong>{@job_count}</strong>
              <span>jobs</span>
            </div>
            <div class="scout-stat" aria-label={"#{@completed_count} completed"}>
              <strong>{@completed_count}</strong>
              <span>completed</span>
            </div>
            <div class="scout-stat" aria-label={"#{@agent_count} agents"}>
              <strong>{@agent_count}</strong>
              <span>agents</span>
            </div>
            <div class="scout-stat" aria-label={"#{@agent_capacity} capacity"}>
              <strong>{@agent_capacity}</strong>
              <span>capacity</span>
            </div>
          </div>
        </section>

        <section class="scout-fetch">
          <.form for={@form} id="scout-fetch-form" phx-submit="submit_fetch" class="scout-fetch-form">
            <.dm_input
              field={@form[:url]}
              type="url"
              placeholder="https://example.com/docs/page"
              autocomplete="url"
            />
            <.dm_btn variant="primary" type="submit">Queue Fetch</.dm_btn>
          </.form>
        </section>

        <section class="scout-grid">
          <div class="scout-panel">
            <div class="scout-panel-heading">
              <h2>Fetch Jobs</h2>
              <span>{@running_count} running</span>
            </div>
            <div id="scout-jobs" phx-update="stream" class="scout-job-list">
              <div id="scout-jobs-empty" class="scout-empty hidden only:block">
                No fetch jobs yet.
              </div>
              <article :for={{id, job} <- @streams.jobs} id={id} class="scout-job-row">
                <div class="scout-job-main">
                  <span class={["scout-status", status_class(job.status)]}>{job.status}</span>
                  <a href={job.url} target="_blank" rel="noreferrer" class="scout-url">
                    {job.url}
                  </a>
                  <.dm_modal
                    :if={markdown = job_markdown(job)}
                    id={"scout-job-content-#{job.job_id}"}
                    size="xl"
                    hide_close
                    dialog_label="Scout fetch content"
                  >
                    <:trigger :let={dialog_id}>
                      <.dm_btn
                        variant="secondary"
                        size="xs"
                        onclick={"document.getElementById('#{dialog_id}').show()"}
                      >
                        Show content
                      </.dm_btn>
                    </:trigger>
                    <:title>
                      <div class="scout-modal-title">
                        <span class={["scout-status", status_class(job.status)]}>{job.status}</span>
                        <span>{job.url}</span>
                      </div>
                    </:title>
                    <:body class="scout-modal-body">
                      <.dm_markdown
                        id={"scout-job-markdown-#{job.job_id}"}
                        class="scout-job-markdown-fullscreen"
                        content={markdown}
                        theme="auto"
                      />
                    </:body>
                    <:footer class="scout-modal-footer">
                      <form id={"scout-job-content-close-#{job.job_id}"} method="dialog">
                        <.dm_btn type="submit" variant="secondary" size="sm">Close</.dm_btn>
                      </form>
                    </:footer>
                  </.dm_modal>
                </div>
                <div class="scout-meta">
                  <span>attempt {job.attempt}/{job.max_attempts}</span>
                  <span>{job.timeout_ms} ms timeout</span>
                  <span :if={job[:region_hint]}>region {job.region_hint}</span>
                  <span :if={result_value(job, :word_count)}>
                    {result_value(job, :word_count)} words
                  </span>
                </div>
                <p :if={job[:error]} class="scout-error">{error_message(job.error)}</p>
              </article>
            </div>
          </div>

          <aside class="scout-panel">
            <div class="scout-panel-heading">
              <h2>Agents</h2>
              <span>{@agent_capacity} capacity</span>
            </div>
            <div id="scout-agents" phx-update="stream" class="scout-agent-list">
              <div id="scout-agents-empty" class="scout-empty hidden only:block">
                Waiting for agent heartbeat.
              </div>
              <article :for={{id, agent} <- @streams.agents} id={id} class="scout-agent-row">
                <div class="scout-agent-head">
                  <strong>{agent.agent_id}</strong>
                  <span class="scout-muted">{agent.region || "-"}</span>
                </div>
                <span class={["scout-status", status_class(agent.status)]}>{agent.status || "unknown"}</span>
                <div class="scout-meta">
                  <span>{agent.running_jobs}/{agent.capacity} running</span>
                  <span>v{agent.version || "-"}</span>
                </div>
              </article>
            </div>
          </aside>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp assign_job_stats(socket, jobs) do
    assign(socket,
      job_count: length(jobs),
      completed_count: Enum.count(jobs, &(&1.status == "completed")),
      running_count: Enum.count(jobs, &(&1.status == "running"))
    )
  end

  defp assign_agent_stats(socket, agents) do
    assign(socket,
      agent_count: length(agents),
      agent_capacity: Enum.reduce(agents, 0, &((&1.capacity || 0) + &2))
    )
  end

  defp status_class("completed"), do: "scout-status-ok"
  defp status_class("healthy"), do: "scout-status-ok"
  defp status_class("running"), do: "scout-status-running"
  defp status_class("queued"), do: "scout-status-queued"
  defp status_class("retrying"), do: "scout-status-running"
  defp status_class(_status), do: "scout-status-error"

  defp job_markdown(%{result: result}) when is_map(result) do
    result
    |> map_value(:markdown)
    |> present_string()
  end

  defp job_markdown(_job), do: nil

  defp result_value(%{result: result}, key) when is_map(result), do: map_value(result, key)
  defp result_value(_job, _key), do: nil

  defp map_value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp present_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      _content -> value
    end
  end

  defp present_string(_value), do: nil

  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(%{"message" => message}) when is_binary(message), do: message
  defp error_message(message) when is_binary(message), do: message
  defp error_message(error), do: inspect(error)
end
