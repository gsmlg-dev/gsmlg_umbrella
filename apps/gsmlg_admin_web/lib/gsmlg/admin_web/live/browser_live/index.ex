defmodule GSMLG.AdminWeb.BrowserLive.Index do
  @moduledoc "Authenticated Browser Control management interface."

  use GSMLG.AdminWeb, :live_view

  alias GSMLG.Browser
  alias GSMLG.Browser.{ChatURL, Error}

  @job_actions ~w(cancel retry resume reconcile manual_acquire manual_release)
  @workflows [
    {"gemini.deep_research", "Deep Research"},
    {"gemini.youtube_analysis", "YouTube Analysis"}
  ]
  @analysis_profiles [
    {"summary", "Summary"},
    {"technical_review", "Technical review"},
    {"timeline", "Timeline"},
    {"fact_check", "Fact check"},
    {"action_items", "Action items"}
  ]
  @intervention_instructions %{
    "login_required" => "Sign in through the remote browser, then resume the workflow.",
    "reauth_required" => "Complete account reauthentication in the remote browser, then resume.",
    "passkey_required" => "Complete the passkey prompt manually, then resume the workflow.",
    "two_factor_required" =>
      "Complete two-factor verification manually, then resume the workflow.",
    "captcha_required" => "Complete the CAPTCHA manually, then resume the workflow.",
    "account_warning" => "Review and resolve the account warning manually, then resume.",
    "ui_contract_mismatch" =>
      "Inspect the unknown Gemini page and place it in a supported state.",
    "action_outcome_unknown" => "Inspect whether the last action completed before resuming.",
    "plan_approval_required" => "Review and approve the research plan manually, then resume."
  }

  @impl true
  def mount(params, _session, socket) do
    actor = socket.assigns[:current_user]

    if connected?(socket) do
      Browser.subscribe(actor, :updates)
      Phoenix.PubSub.subscribe(GSMLG.PubSub, "commander_updates")
    end

    {:ok,
     socket
     |> assign(:actor, actor)
     |> assign(:page_title, "Browser Control")
     |> assign(:active_menu, "browser_dashboard")
     |> assign(:page, :dashboard)
     |> assign(:commander_id, params["name"])
     |> assign(:nodes, [])
     |> assign(:profiles, [])
     |> assign(:sessions, [])
     |> assign(:jobs, [])
     |> assign(:job, nil)
     |> assign(:job_session, nil)
     |> assign(:events, [])
     |> assign(:artifacts, [])
     |> assign(:loading?, false)
     |> assign(:service_error, nil)
     |> assign(:job_form, job_form())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    page = page_for(socket.assigns.live_action)

    socket =
      socket
      |> assign(:page, page)
      |> assign(:active_menu, active_menu(page))
      |> assign(:commander_id, params["name"] || socket.assigns.commander_id)
      |> assign(:page_title, page_title(page))
      |> load_page(params)

    {:noreply, socket}
  end

  @impl true
  def handle_info(:commander_updates, socket), do: reload(socket)
  def handle_info({:agent_disconnected, _commander_id}, socket), do: reload(socket)
  def handle_info({:browser_changed, _invalidation}, socket), do: reload(socket)

  def handle_info(
        {:browser_job_changed, %{job_id: job_id}},
        %{assigns: %{job: %{id: job_id}}} = socket
      ),
      do: reload(socket)

  def handle_info({:browser_job_changed, _invalidation}, socket), do: reload(socket)
  def handle_info({:reload_browser_page, params}, socket), do: reload(socket, params)
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("refresh", _params, socket), do: begin_reload(socket)

  def handle_event("configure_profile", %{"profile" => %{"id" => id} = params}, socket) do
    attrs = %{
      enabled: truthy?(params["enabled"]),
      is_default: truthy?(params["is_default"]),
      allowed_origins: parse_origins(params["allowed_origins"])
    }

    case Browser.configure_profile(socket.assigns.actor, id, attrs) do
      {:ok, _profile} ->
        socket
        |> put_flash(:info, "Profile policy saved.")
        |> reload()

      {:error, %Error{} = error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_event("configure_profile", _params, socket),
    do: {:noreply, put_flash(socket, :error, "Invalid profile policy.")}

  def handle_event(
        "job_action",
        %{"action" => action},
        %{assigns: %{job: job}} = socket
      )
      when action in @job_actions and not is_nil(job) do
    result = run_job_action(socket.assigns.actor, socket.assigns.job, action)

    case result do
      {:ok, _job} ->
        socket = put_flash(socket, :info, "Job #{action} accepted.")
        reload(socket)

      {:error, %Error{} = error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_event("job_action", _params, socket),
    do: {:noreply, put_flash(socket, :error, "Unsupported job action.")}

  def handle_event("create_job", %{"job" => params}, socket) do
    attrs = %{
      workflow: params["workflow"],
      workflow_version: parse_integer(params["workflow_version"]),
      input: workflow_input(params),
      output_formats: selected_output_formats(params),
      idempotency_key: params["idempotency_key"]
    }

    attrs = optional_id(attrs, :node_id, params["node_id"])
    attrs = optional_id(attrs, :profile_id, params["profile_id"])

    case Browser.create_job(socket.assigns.actor, attrs) do
      {:ok, job} ->
        {:noreply,
         socket
         |> put_flash(:info, "Browser job queued.")
         |> push_navigate(to: ~p"/browser/jobs/#{job.id}")}

      {:error, %Error{} = error} ->
        {:noreply,
         socket
         |> assign(:job_form, to_form(params, as: :job))
         |> put_flash(:error, error.message)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title} active_menu={@active_menu}>
      <main id="browser-control" class="space-y-6 p-6 lg:p-8">
        <header class="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
          <div>
            <p class="text-sm font-semibold uppercase tracking-[0.2em] text-primary">
              Remote operations
            </p>
            <h1 class="text-3xl font-bold text-on-surface">{@page_title}</h1>
            <p class="mt-2 max-w-3xl text-on-surface-variant">
              Durable, policy-bound browser sessions and workflows over Commander.
            </p>
          </div>
          <.dm_btn id="browser-refresh" variant="outline" phx-click="refresh">Refresh</.dm_btn>
        </header>

        <nav id="browser-navigation" aria-label="Browser Control" class="flex flex-wrap gap-2">
          <.browser_nav href={~p"/browser"} active={@page == :dashboard}>Dashboard</.browser_nav>
          <.browser_nav href={~p"/browser/nodes"} active={@page in [:nodes, :commander]}>
            Nodes
          </.browser_nav>
          <.browser_nav href={~p"/browser/profiles"} active={@page == :profiles}>
            Profiles
          </.browser_nav>
          <.browser_nav href={~p"/browser/sessions"} active={@page == :sessions}>
            Sessions
          </.browser_nav>
          <.browser_nav href={~p"/browser/jobs"} active={@page in [:jobs, :job, :new_job]}>
            Jobs
          </.browser_nav>
          <.browser_nav href={~p"/browser/settings"} active={@page == :settings}>
            Settings
          </.browser_nav>
        </nav>

        <.service_error :if={@service_error} error={@service_error} />

        <div
          :if={@loading?}
          id="browser-loading"
          role="status"
          aria-live="polite"
          class="rounded-xl border border-outline-variant bg-surface-container p-4 text-on-surface-variant"
        >
          Refreshing Browser Control state…
        </div>

        <%= case @page do %>
          <% :dashboard -> %>
            <.dashboard
              nodes={@nodes}
              profiles={@profiles}
              sessions={@sessions}
              jobs={@jobs}
              artifacts={@artifacts}
            />
          <% :nodes -> %>
            <.nodes nodes={@nodes} commander_id={nil} />
          <% :commander -> %>
            <.nodes nodes={@nodes} commander_id={@commander_id} />
          <% :profiles -> %>
            <.profiles profiles={@profiles} />
          <% :sessions -> %>
            <.sessions sessions={@sessions} />
          <% :jobs -> %>
            <.jobs jobs={@jobs} />
          <% :new_job -> %>
            <.new_job form={@job_form} nodes={@nodes} profiles={@profiles} />
          <% :job -> %>
            <.job_detail
              job={@job}
              session={@job_session}
              events={@events}
              artifacts={@artifacts}
            />
          <% :settings -> %>
            <.settings />
        <% end %>
      </main>
    </Layouts.app>
    """
  end

  attr :href, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  defp browser_nav(assigns) do
    ~H"""
    <.link
      navigate={@href}
      aria-current={@active && "page"}
      class={[
        "rounded-full px-4 py-2 text-sm font-medium transition-colors",
        @active && "bg-primary-container text-on-primary-container",
        !@active && "bg-surface-container text-on-surface-variant hover:bg-surface-container-high"
      ]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :error, :any, required: true

  defp service_error(assigns) do
    ~H"""
    <.dm_alert id="browser-service-state" variant="warning" title="Browser Control unavailable">
      {@error.message}
    </.dm_alert>
    """
  end

  attr :nodes, :list, required: true
  attr :profiles, :list, required: true
  attr :sessions, :list, required: true
  attr :jobs, :list, required: true
  attr :artifacts, :list, required: true

  defp dashboard(assigns) do
    assigns =
      assigns
      |> assign(
        :online_nodes,
        Enum.count(assigns.nodes, &(effective_node_status(&1) == "online"))
      )
      |> assign(
        :available_profiles,
        Enum.count(assigns.profiles, &(&1.automation_status == "available"))
      )
      |> assign(
        :active_sessions,
        Enum.count(assigns.sessions, &(&1.status not in ~w(closed failed)))
      )
      |> assign(
        :active_jobs,
        Enum.count(
          assigns.jobs,
          &(&1.status in ~w(queued dispatching accepted running waiting_human collecting_artifacts))
        )
      )
      |> assign(:waiting_jobs, Enum.filter(assigns.jobs, &(&1.status == "waiting_human")))
      |> assign(:recent_errors, recent_errors(assigns.nodes, assigns.jobs))
      |> assign(:node_states, state_counts(assigns.nodes, &effective_node_status/1))
      |> assign(:profile_states, state_counts(assigns.profiles, & &1.automation_status))
      |> assign(:job_states, state_counts(assigns.jobs, & &1.status))
      |> assign(:artifact_states, state_counts(assigns.artifacts, & &1.status))
      |> assign(:manager_states, state_counts(assigns.nodes, &health_label(&1.metadata)))
      |> assign(:tls_states, state_counts(assigns.nodes, &tls_status(&1.metadata)))

    ~H"""
    <section id="browser-dashboard" aria-labelledby="browser-dashboard-heading" class="space-y-6">
      <h2 id="browser-dashboard-heading" class="sr-only">Browser fleet summary</h2>
      <div id="browser-summary" class="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <.metric id="browser-online-nodes" label="Online nodes" value={@online_nodes} />
        <.metric
          id="browser-available-profiles"
          label="Available profiles"
          value={@available_profiles}
        />
        <.metric id="browser-active-sessions" label="Active sessions" value={@active_sessions} />
        <.metric id="browser-active-jobs" label="Active jobs" value={@active_jobs} />
      </div>

      <div class="grid gap-6 xl:grid-cols-2">
        <.dm_card id="browser-operational-states" variant="bordered">
          <:title>Operational states</:title>
          <dl class="grid gap-3 text-sm sm:grid-cols-2">
            <.state_row
              id="browser-node-states"
              label="Nodes"
              summary={state_summary(@node_states, ["online", "degraded", "offline", "disabled"])}
            />
            <.state_row
              id="browser-profile-states"
              label="Profiles"
              summary={state_summary(@profile_states, ["available", "leased", "manual", "disabled"])}
            />
            <.state_row
              id="browser-job-states"
              label="Jobs"
              summary={state_summary(@job_states, ["queued", "running", "waiting_human", "failed"])}
            />
            <.state_row
              id="browser-artifact-states"
              label="Artifacts"
              summary={
                state_summary(@artifact_states, ["pending", "uploading", "verified", "rejected"])
              }
            />
          </dl>
        </.dm_card>

        <.dm_card id="browser-transport-summary" variant="bordered">
          <:title>Commander, Manager, and transfer health</:title>
          <dl class="grid gap-3 text-sm">
            <.state_row
              id="browser-manager-states"
              label="Manager"
              summary={state_summary(@manager_states)}
            />
            <.state_row
              id="browser-tls-states"
              label="Commander TLS"
              summary={state_summary(@tls_states)}
            />
            <.state_row
              id="browser-backends"
              label="Backends"
              summary={@nodes |> Enum.map(& &1.default_backend) |> Enum.uniq() |> Enum.join(", ")}
            />
          </dl>
        </.dm_card>
      </div>

      <div class="grid gap-6 xl:grid-cols-2">
        <.dm_card id="browser-interventions" variant="bordered">
          <:title>Human intervention</:title>
          <div
            :if={@waiting_jobs == []}
            id="browser-interventions-empty"
            class="text-on-surface-variant"
          >
            No jobs are waiting for an operator.
          </div>
          <ul :if={@waiting_jobs != []} class="space-y-3">
            <li :for={job <- @waiting_jobs} id={"browser-intervention-#{job.id}"}>
              <.link
                navigate={~p"/browser/jobs/#{job.id}"}
                class="font-medium text-primary hover:underline"
              >
                {job.workflow} · {job.phase || "waiting"}
              </.link>
            </li>
          </ul>
        </.dm_card>

        <.dm_card id="browser-recent-errors" variant="bordered">
          <:title>Recent errors</:title>
          <div :if={@recent_errors == []} id="browser-errors-empty" class="text-on-surface-variant">
            No recent browser errors.
          </div>
          <ul :if={@recent_errors != []} class="space-y-3">
            <li
              :for={error <- @recent_errors}
              class="rounded-lg bg-error-container p-3 text-on-error-container"
            >
              {error}
            </li>
          </ul>
        </.dm_card>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :summary, :string, required: true

  defp state_row(assigns) do
    ~H"""
    <div id={@id}>
      <dt class="font-semibold text-on-surface">{@label}</dt>
      <dd class="text-on-surface-variant">{if @summary == "", do: "none", else: @summary}</dd>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :integer, required: true

  defp metric(assigns) do
    ~H"""
    <.dm_card id={@id} variant="bordered" class="bg-surface-container-low">
      <p class="text-sm text-on-surface-variant">{@label}</p>
      <p class="mt-2 text-3xl font-bold tabular-nums text-on-surface">{@value}</p>
    </.dm_card>
    """
  end

  attr :nodes, :list, required: true
  attr :commander_id, :any, default: nil

  defp nodes(assigns) do
    nodes =
      if assigns.commander_id,
        do: Enum.filter(assigns.nodes, &(&1.commander_id == assigns.commander_id)),
        else: assigns.nodes

    assigns = assign(assigns, :visible_nodes, nodes)

    ~H"""
    <section id="browser-nodes" aria-labelledby="browser-nodes-heading" class="space-y-4">
      <div class="flex items-end justify-between gap-4">
        <div>
          <h2 id="browser-nodes-heading" class="text-2xl font-semibold">
            {if @commander_id, do: "Browser node · #{@commander_id}", else: "Browser nodes"}
          </h2>
          <p class="text-on-surface-variant">Capability, backend, health, limits, and TLS summary.</p>
        </div>
      </div>
      <.empty_state
        :if={@visible_nodes == []}
        id="browser-nodes-empty"
        message="No browser-capable nodes found."
      />
      <div class="grid gap-4 lg:grid-cols-2">
        <.dm_card :for={node <- @visible_nodes} id={"browser-node-#{node.id}"} variant="bordered">
          <:title>{node.commander_id}</:title>
          <div class="space-y-3">
            <div class="flex flex-wrap items-center gap-2">
              <.status_badge status={effective_node_status(node)} />
              <.dm_badge variant="ghost">{node.default_backend}</.dm_badge>
              <.dm_badge :if={node.online?} variant="success">live</.dm_badge>
            </div>
            <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-2 text-sm">
              <dt class="text-on-surface-variant">Capability</dt>
              <dd class="font-mono">browser.control/v1</dd>
              <dt class="text-on-surface-variant">Manager</dt>
              <dd>{health_label(node.metadata)}</dd>
              <dt class="text-on-surface-variant">Browser Agent</dt>
              <dd>{version_label(node.metadata, "agent_version")}</dd>
              <dt class="text-on-surface-variant">Browser binary</dt>
              <dd>{version_label(node.metadata, "browser_version")}</dd>
              <dt class="text-on-surface-variant">TLS</dt>
              <dd id={"browser-node-#{node.id}-tls"}>{tls_label(node.metadata)}</dd>
              <dt class="text-on-surface-variant">Last seen</dt>
              <dd>{format_datetime(node.last_seen_at)}</dd>
            </dl>
            <details>
              <summary class="cursor-pointer font-medium text-primary">Advertised limits</summary>
              <pre class="mt-2 overflow-auto rounded-lg bg-surface-container p-3 text-xs">{safe_json(node.limits)}</pre>
            </details>
          </div>
        </.dm_card>
      </div>
    </section>
    """
  end

  attr :profiles, :list, required: true

  defp profiles(assigns) do
    ~H"""
    <section id="browser-profiles" aria-labelledby="browser-profiles-heading" class="space-y-4">
      <div>
        <h2 id="browser-profiles-heading" class="text-2xl font-semibold">Browser profiles</h2>
        <p class="text-on-surface-variant">
          Only non-sensitive profile metadata is retained centrally.
        </p>
      </div>
      <.empty_state
        :if={@profiles == []}
        id="browser-profiles-empty"
        message="No profiles have been synchronized."
      />
      <div :if={@profiles != []} class="overflow-x-auto rounded-xl border border-outline-variant">
        <table class="w-full text-left text-sm">
          <thead class="bg-surface-container text-on-surface-variant">
            <tr>
              <th>Name</th><th>Backend</th><th>Runtime</th><th>Lease</th><th>Locale</th><th>
                Policy
              </th>
            </tr>
          </thead>
          <tbody class="divide-y divide-outline-variant">
            <tr :for={profile <- @profiles} id={"browser-profile-#{profile.id}"}>
              <td class="font-medium">
                {profile.name}<span :if={profile.is_default} class="ml-2 text-xs text-primary">default</span>
              </td>
              <td>{profile.backend}</td>
              <td><.status_badge status={profile.runtime_status} /></td>
              <td><.status_badge status={profile.automation_status} /></td>
              <td>{profile.locale || "—"}</td>
              <td><.profile_policy profile={profile} /></td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  attr :profile, :any, required: true

  defp profile_policy(assigns) do
    form =
      to_form(
        %{
          "id" => assigns.profile.id,
          "enabled" => assigns.profile.enabled,
          "is_default" => assigns.profile.is_default,
          "allowed_origins" => profile_origins(assigns.profile)
        },
        as: :profile,
        id: "browser-profile-policy-#{assigns.profile.id}"
      )

    assigns = assign(assigns, :form, form)

    ~H"""
    <.form
      for={@form}
      id={"browser-profile-policy-#{@profile.id}"}
      phx-submit="configure_profile"
      class="min-w-72 space-y-2"
    >
      <input type="hidden" name={@form[:id].name} value={@profile.id} />
      <div class="flex flex-wrap gap-3">
        <.dm_input field={@form[:enabled]} type="checkbox" label="Enabled" />
        <.dm_input field={@form[:is_default]} type="checkbox" label="Default" />
      </div>
      <.dm_input
        field={@form[:allowed_origins]}
        type="textarea"
        label="Allowed HTTPS origins"
        rows="2"
        placeholder="https://gemini.google.com"
        class="font-mono text-xs"
      />
      <.dm_btn type="submit" size="sm" variant="outline">Save policy</.dm_btn>
    </.form>
    """
  end

  attr :sessions, :list, required: true

  defp sessions(assigns) do
    ~H"""
    <section id="browser-sessions" aria-labelledby="browser-sessions-heading" class="space-y-4">
      <div>
        <h2 id="browser-sessions-heading" class="text-2xl font-semibold">Browser sessions</h2>
        <p class="text-on-surface-variant">Actor-owned automation and manual lease state.</p>
      </div>
      <.empty_state
        :if={@sessions == []}
        id="browser-sessions-empty"
        message="No sessions for this account."
      />
      <div class="grid gap-4 lg:grid-cols-2">
        <.dm_card :for={session <- @sessions} id={"browser-session-#{session.id}"} variant="bordered">
          <:title>Session {short_id(session.id)}</:title>
          <div class="space-y-3 text-sm">
            <div class="flex gap-2">
              <.status_badge status={session.status} /><.dm_badge variant="ghost">
                {session.mode}
              </.dm_badge>
            </div>
            <p>
              <span class="text-on-surface-variant">Revision</span>
              <span class="font-mono">{session.revision}</span>
            </p>
            <p>
              <span class="text-on-surface-variant">Expires</span> {format_datetime(
                session.expires_at
              )}
            </p>
            <p
              :if={session.status == "waiting_human"}
              class="rounded-lg bg-warning-container p-3 text-on-warning-container"
            >
              Automation is paused. Acquire the manual lease through the job intervention before resuming.
            </p>
          </div>
        </.dm_card>
      </div>
    </section>
    """
  end

  attr :jobs, :list, required: true

  defp jobs(assigns) do
    ~H"""
    <section id="browser-jobs" aria-labelledby="browser-jobs-heading" class="space-y-4">
      <div class="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h2 id="browser-jobs-heading" class="text-2xl font-semibold">Workflow jobs</h2>
          <p class="text-on-surface-variant">
            Durable remote executions with resumable events and artifacts.
          </p>
        </div>
        <.link navigate={~p"/browser/jobs/new"}><.dm_btn id="browser-new-job" variant="primary">
          New job
        </.dm_btn></.link>
      </div>
      <.empty_state
        :if={@jobs == []}
        id="browser-jobs-empty"
        message="No browser jobs for this account."
      />
      <div :if={@jobs != []} class="overflow-x-auto rounded-xl border border-outline-variant">
        <table class="w-full text-left text-sm">
          <thead class="bg-surface-container text-on-surface-variant">
            <tr>
              <th>Workflow</th><th>Status</th><th>Phase</th><th>Attempt</th><th>Updated</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-outline-variant">
            <tr :for={job <- @jobs} id={"browser-job-#{job.id}"}>
              <td>
                <.link
                  navigate={~p"/browser/jobs/#{job.id}"}
                  class="font-medium text-primary hover:underline"
                >{job.workflow} v{job.workflow_version}</.link>
              </td>
              <td><.status_badge status={job.status} /></td>
              <td>{job.phase || "—"}</td>
              <td>{job.attempt}</td>
              <td>{format_datetime(job.updated_at)}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  attr :form, :map, required: true
  attr :nodes, :list, required: true
  attr :profiles, :list, required: true

  defp new_job(assigns) do
    node_options = Enum.map(assigns.nodes, &{&1.id, &1.commander_id})
    profile_options = Enum.map(assigns.profiles, &{&1.id, &1.name})

    assigns =
      assigns
      |> assign(:node_options, node_options)
      |> assign(:profile_options, profile_options)
      |> assign(:workflows, @workflows)
      |> assign(:analysis_profiles, @analysis_profiles)

    ~H"""
    <section id="browser-job-new" aria-labelledby="browser-job-new-heading" class="space-y-4">
      <div>
        <h2 id="browser-job-new-heading" class="text-2xl font-semibold">New browser job</h2>
        <p id="browser-job-form-help" class="text-on-surface-variant">
          Select a bounded workflow. A default online node and profile are used when omitted.
        </p>
      </div>
      <.dm_card variant="bordered" class="max-w-3xl">
        <.form
          for={@form}
          id="browser-job-form"
          phx-submit="create_job"
          aria-describedby="browser-job-form-help"
          class="space-y-5"
        >
          <.dm_select field={@form[:workflow]} label="Workflow" options={@workflows} />
          <.dm_input
            field={@form[:workflow_version]}
            type="number"
            label="Workflow version"
            min="1"
            required
          />
          <.dm_input
            field={@form[:prompt]}
            type="textarea"
            label="Deep Research prompt"
            rows="7"
          />
          <.dm_input field={@form[:output_locale]} label="Output locale" maxlength="32" required />
          <.dm_input
            field={@form[:research_scope]}
            label="Research scope"
            maxlength="1024"
          />
          <.dm_input
            field={@form[:required_sections]}
            type="textarea"
            label="Required sections (one per line)"
            rows="3"
          />
          <.dm_input
            field={@form[:youtube_url]}
            type="url"
            label="YouTube URL (YouTube workflow only)"
          />
          <.dm_select
            field={@form[:analysis_profile]}
            label="YouTube analysis profile"
            options={@analysis_profiles}
          />
          <.dm_input
            field={@form[:custom_instructions]}
            type="textarea"
            label="YouTube custom instructions"
            rows="3"
          />
          <div class="grid gap-4 sm:grid-cols-2">
            <.dm_select
              field={@form[:node_id]}
              label="Node"
              prompt="Use configured default"
              options={@node_options}
            />
            <.dm_select
              field={@form[:profile_id]}
              label="Profile"
              prompt="Use node default"
              options={@profile_options}
            />
          </div>
          <.dm_input field={@form[:idempotency_key]} label="Idempotency key" maxlength="512" required />
          <fieldset class="space-y-2">
            <legend class="font-medium">Output formats</legend>
            <p class="text-sm text-on-surface-variant">Every workflow includes:</p>
            <ul class="flex flex-wrap gap-2" aria-label="Required output formats">
              <li id="browser-required-output-report-markdown">Markdown report</li>
              <li id="browser-required-output-report-json">Structured JSON</li>
              <li id="browser-required-output-sources-json">Sources JSON</li>
            </ul>
            <div class="grid gap-2 sm:grid-cols-2" aria-label="Optional output formats">
              <.dm_input
                id="browser-job-report-html"
                field={@form[:report_html]}
                type="checkbox"
                label="HTML report"
              />
              <.dm_input
                id="browser-job-screenshot-png"
                field={@form[:screenshot_png]}
                type="checkbox"
                label="Screenshot"
              />
            </div>
          </fieldset>
          <.dm_input
            field={@form[:auto_approve_plan]}
            type="checkbox"
            label="Auto-approve bounded research plan"
          />
          <.dm_input
            field={@form[:use_deep_research]}
            type="checkbox"
            label="Use Deep Research for YouTube analysis"
          />
          <.dm_btn id="browser-job-submit" type="submit" variant="primary">Queue workflow</.dm_btn>
        </.form>
      </.dm_card>
    </section>
    """
  end

  attr :job, :any, required: true
  attr :session, :any, default: nil
  attr :events, :list, required: true
  attr :artifacts, :list, required: true

  defp job_detail(%{job: nil} = assigns) do
    ~H"""
    <section id="browser-job-not-found">
      <.empty_state id="browser-job-missing" message="Job not found or not authorized." />
    </section>
    """
  end

  defp job_detail(assigns) do
    intervention = active_intervention(assigns.events, assigns.job.status)
    chat_url = authorized_chat_url(assigns.job)
    {intervention_code, intervention_instruction} = intervention_details(intervention)

    assigns =
      assigns
      |> assign(:intervention, intervention)
      |> assign(:intervention_code, intervention_code)
      |> assign(:intervention_instruction, intervention_instruction)
      |> assign(:chat_url, chat_url)

    ~H"""
    <section
      id={"browser-job-detail-#{@job.id}"}
      aria-labelledby="browser-job-heading"
      class="space-y-6"
    >
      <div class="flex flex-wrap items-end justify-between gap-4">
        <div>
          <p class="font-mono text-xs text-on-surface-variant">{@job.id}</p>
          <h2 id="browser-job-heading" class="text-2xl font-semibold">
            {@job.workflow} v{@job.workflow_version}
          </h2>
          <div class="mt-2 flex flex-wrap gap-2">
            <.status_badge status={@job.status} /><.dm_badge variant="ghost">
              phase: {@job.phase || "—"}
            </.dm_badge><.dm_badge variant="ghost">attempt {@job.attempt}</.dm_badge>
          </div>
        </div>
        <div id="browser-job-actions" class="flex flex-wrap gap-2" aria-label="Job actions">
          <.dm_btn
            id="browser-job-cancel"
            variant="error"
            phx-click="job_action"
            phx-value-action="cancel"
            disabled={
              @job.status not in ~w(queued accepted unknown running waiting_human collecting_artifacts)
            }
          >
            Cancel
          </.dm_btn>
          <.dm_btn
            id="browser-job-retry"
            variant="outline"
            phx-click="job_action"
            phx-value-action="retry"
            disabled={@job.status not in ~w(failed cancelled)}
          >
            Retry
          </.dm_btn>
          <.dm_btn
            id="browser-job-resume"
            variant="primary"
            phx-click="job_action"
            phx-value-action="resume"
            disabled={@job.status != "waiting_human"}
          >
            Resume
          </.dm_btn>
          <.dm_btn
            id="browser-job-reconcile"
            variant="outline"
            phx-click="job_action"
            phx-value-action="reconcile"
          >
            Reconcile
          </.dm_btn>
        </div>
      </div>

      <.dm_alert
        :if={@intervention}
        id="browser-job-intervention"
        variant="warning"
        title="Human intervention required"
      >
        <dl class="grid gap-2 text-sm sm:grid-cols-2">
          <div>
            <dt class="font-semibold">Reason code</dt>
            <dd id="browser-job-intervention-reason" class="font-mono">{@intervention_code}</dd>
          </div>
          <div>
            <dt class="font-semibold">Profile</dt>
            <dd id="browser-job-intervention-profile" class="font-mono">{@job.profile_id}</dd>
          </div>
          <div>
            <dt class="font-semibold">Manual lease</dt>
            <dd id="browser-job-manual-lease-state">{manual_lease_label(@session)}</dd>
          </div>
        </dl>
        <p id="browser-job-intervention-instructions" class="mt-3">
          {@intervention_instruction}
        </p>
        <div class="mt-3 rounded-lg bg-surface-container p-3 text-sm">
          <p>Open WebVNC only through an approved SSH tunnel:</p>
          <code id="browser-job-ssh-tunnel" class="mt-1 block overflow-x-auto whitespace-nowrap">
            ssh -N -L 18080:127.0.0.1:8080 &lt;browser-host&gt;
          </code>
        </div>
        <p class="mt-3 text-sm">
          Acquire the manual lease, complete the human-only step, release the lease, then select Resume. Automation remains paused until Resume reacquires authority and takes a fresh observation.
        </p>
        <div :if={@job.session_id} class="mt-4 flex flex-wrap gap-2">
          <.dm_btn
            id="browser-job-manual-acquire"
            variant="warning"
            phx-click="job_action"
            phx-value-action="manual_acquire"
          >
            Acquire manual lease
          </.dm_btn>
          <.dm_btn
            id="browser-job-manual-release"
            variant="outline"
            phx-click="job_action"
            phx-value-action="manual_release"
          >
            Release manual lease
          </.dm_btn>
        </div>
      </.dm_alert>

      <.dm_card id="browser-job-input" variant="bordered">
        <:title>Input summary</:title>
        <dl class="grid gap-3 text-sm sm:grid-cols-2">
          <div>
            <dt class="text-on-surface-variant">Node</dt><dd class="font-mono">{@job.node_id}</dd>
          </div>
          <div>
            <dt class="text-on-surface-variant">Profile</dt><dd class="font-mono">
              {@job.profile_id}
            </dd>
          </div>
          <div>
            <dt class="text-on-surface-variant">Deadline</dt><dd>
              {format_datetime(@job.deadline_at)}
            </dd>
          </div>
          <div>
            <dt class="text-on-surface-variant">Outputs</dt><dd>
              {Enum.join(@job.output_formats, ", ")}
            </dd>
          </div>
        </dl>
        <a
          :if={@chat_url}
          id="browser-job-chat-url"
          href={@chat_url}
          target="_blank"
          rel="noreferrer"
          class="mt-4 inline-flex font-medium text-primary hover:underline"
        >Open authorized Gemini conversation</a>
      </.dm_card>

      <.dm_card id="browser-job-result-summary" variant="bordered">
        <:title>Result summary</:title>
        <dl class="grid gap-3 text-sm sm:grid-cols-2">
          <div>
            <dt class="text-on-surface-variant">Status</dt>
            <dd id="browser-job-result-status">{@job.status}</dd>
          </div>
          <div>
            <dt class="text-on-surface-variant">Last remote sequence</dt>
            <dd id="browser-job-result-sequence">{result_count(@job.result, "last_sequence")}</dd>
          </div>
          <div>
            <dt class="text-on-surface-variant">Reported artifacts</dt>
            <dd id="browser-job-result-artifacts">{result_count(@job.result, "artifact_count")}</dd>
          </div>
          <div>
            <dt class="text-on-surface-variant">Pending artifacts</dt>
            <dd id="browser-job-result-pending-artifacts">
              {result_count(
                @job.result,
                "pending_artifact_count"
              )}
            </dd>
          </div>
          <div :if={@job.error}>
            <dt class="text-on-surface-variant">Failure code</dt>
            <dd id="browser-job-result-error" class="font-mono">{error_code(@job.error)}</dd>
          </div>
        </dl>
      </.dm_card>

      <.dm_card id="browser-job-events" variant="bordered">
        <:title>Event timeline</:title>
        <.empty_state
          :if={@events == []}
          id="browser-job-events-empty"
          message="No events received yet."
        />
        <ol :if={@events != []} class="relative space-y-4 border-l border-outline-variant pl-6">
          <li :for={event <- @events} id={"browser-job-event-#{event.sequence}"} class="relative">
            <span class="absolute -left-[1.82rem] top-1 h-3 w-3 rounded-full bg-primary"></span>
            <div class="flex flex-wrap items-baseline justify-between gap-2">
              <p class="font-medium">{event.event}</p><time class="text-xs text-on-surface-variant">{format_datetime(
                event.occurred_at || event.inserted_at
              )}</time>
            </div>
            <p :if={event.phase} class="text-sm text-on-surface-variant">Phase: {event.phase}</p>
          </li>
        </ol>
      </.dm_card>

      <.dm_card id="browser-job-artifacts" variant="bordered">
        <:title>Artifacts</:title>
        <.empty_state
          :if={@artifacts == []}
          id="browser-job-artifacts-empty"
          message="No artifacts available yet."
        />
        <ul :if={@artifacts != []} class="divide-y divide-outline-variant">
          <li
            :for={artifact <- @artifacts}
            id={"browser-artifact-#{artifact.id}"}
            class="flex flex-wrap items-center justify-between gap-4 py-4"
          >
            <div>
              <p class="font-medium">{artifact.filename}</p><p class="text-xs text-on-surface-variant">
                {artifact.kind} · {artifact.mime} · {format_bytes(artifact.size)} · SHA-256 {String.slice(
                  artifact.sha256,
                  0,
                  12
                )}…
              </p>
            </div>
            <div class="flex items-center gap-2">
              <.status_badge status={artifact.status} /><a
                :if={artifact.status == "verified"}
                href={~p"/browser/artifacts/#{artifact.id}/content"}
                class="font-medium text-primary hover:underline"
              >Download</a>
            </div>
          </li>
        </ul>
      </.dm_card>
    </section>
    """
  end

  defp settings(assigns) do
    runtime_config = Application.get_all_env(:gsmlg_browser) |> Map.new()
    configured_settings = Map.get(runtime_config, :settings, %{})

    config =
      Map.merge(
        configured_settings,
        Map.take(runtime_config, [
          :enabled,
          :default_node,
          :event_retention_days,
          :inline_artifact_max_bytes
        ])
      )

    assigns = assign(assigns, :config, config)

    ~H"""
    <section id="browser-settings" aria-labelledby="browser-settings-heading" class="space-y-4">
      <div>
        <h2 id="browser-settings-heading" class="text-2xl font-semibold">Browser Control settings</h2><p class="text-on-surface-variant">
          Effective non-secret runtime policy. Secrets and credentials are never rendered.
        </p>
      </div>
      <div class="grid gap-4 lg:grid-cols-2">
        <.dm_card id="browser-settings-service" variant="bordered">
          <:title>Service</:title><dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-2 text-sm">
            <dt>Enabled</dt><dd>{Map.get(@config, :enabled, false)}</dd><dt>Default node</dt><dd>
              {Map.get(@config, :default_node) || "not configured"}
            </dd><dt>Event retention</dt><dd>{Map.get(@config, :event_retention_days, 30)} days</dd>
          </dl>
        </.dm_card>
        <.dm_card id="browser-settings-limits" variant="bordered">
          <:title>Artifact limits</:title><dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-2 text-sm">
            <dt>Inline maximum</dt><dd>
              {format_bytes(Map.get(@config, :inline_artifact_max_bytes, 131_072))}
            </dd><dt>Artifact maximum</dt><dd>
              {format_bytes(get_in(@config, [:security, :max_artifact_bytes]) || 104_857_600)}
            </dd><dt>Observation maximum</dt><dd>
              {format_bytes(get_in(@config, [:security, :max_observation_bytes]) || 1_048_576)}
            </dd>
          </dl>
        </.dm_card>
      </div>
      <.dm_alert id="browser-settings-security" variant="info" title="Security boundary">
        Only HTTPS origins, structured browser actions, authenticated Commander RPC, and verified artifacts are exposed.
      </.dm_alert>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :message, :string, required: true

  defp empty_state(assigns) do
    ~H"""
    <div
      id={@id}
      role="status"
      class="rounded-xl border border-dashed border-outline-variant p-8 text-center text-on-surface-variant"
    >
      {@message}
    </div>
    """
  end

  attr :status, :string, required: true

  defp status_badge(assigns) do
    assigns = assign(assigns, :variant, status_variant(assigns.status))

    ~H"""
    <.dm_badge variant={@variant}>{String.replace(@status, "_", " ")}</.dm_badge>
    """
  end

  defp load_page(socket, params) do
    socket
    |> clear_page_data()
    |> load_for_page(params)
  end

  defp clear_page_data(socket) do
    assign(socket,
      nodes: [],
      profiles: [],
      sessions: [],
      jobs: [],
      job: nil,
      job_session: nil,
      events: [],
      artifacts: [],
      service_error: nil
    )
  end

  defp load_for_page(%{assigns: %{page: :job}} = socket, %{"id" => id}) do
    with {:ok, job} <- Browser.get_job(socket.assigns.actor, id),
         {:ok, session} <- job_session(socket.assigns.actor, job),
         {:ok, events} <- Browser.list_job_events(socket.assigns.actor, id, limit: 100),
         {:ok, artifacts} <- Browser.list_artifacts(socket.assigns.actor, id, limit: 100) do
      if connected?(socket), do: Browser.subscribe(socket.assigns.actor, {:job, id})
      assign(socket, job: job, job_session: session, events: events, artifacts: artifacts)
    else
      {:error, %Error{code: "not_found"}} -> socket
      {:error, %Error{} = error} -> assign(socket, :service_error, error)
    end
  end

  defp load_for_page(%{assigns: %{page: page}} = socket, _params)
       when page in [:dashboard, :new_job] do
    with {:ok, nodes} <- Browser.list_nodes(socket.assigns.actor, limit: 100),
         {:ok, profiles} <- all_profiles(socket.assigns.actor, nodes),
         {:ok, sessions} <- Browser.list_sessions(socket.assigns.actor, limit: 100),
         {:ok, jobs} <- Browser.list_jobs(socket.assigns.actor, limit: 100),
         {:ok, artifacts} <- page_artifacts(page, socket.assigns.actor, jobs) do
      assign(socket,
        nodes: nodes,
        profiles: profiles,
        sessions: sessions,
        jobs: jobs,
        artifacts: artifacts
      )
    else
      {:error, %Error{} = error} -> assign(socket, :service_error, error)
    end
  end

  defp load_for_page(%{assigns: %{page: page}} = socket, _params)
       when page in [:nodes, :commander] do
    put_result(socket, :nodes, Browser.list_nodes(socket.assigns.actor, limit: 100))
  end

  defp load_for_page(%{assigns: %{page: :profiles}} = socket, _params) do
    with {:ok, nodes} <- Browser.list_nodes(socket.assigns.actor, limit: 100),
         {:ok, profiles} <- all_profiles(socket.assigns.actor, nodes) do
      assign(socket, nodes: nodes, profiles: profiles)
    else
      {:error, %Error{} = error} -> assign(socket, :service_error, error)
    end
  end

  defp load_for_page(%{assigns: %{page: :sessions}} = socket, _params),
    do: put_result(socket, :sessions, Browser.list_sessions(socket.assigns.actor, limit: 100))

  defp load_for_page(%{assigns: %{page: :jobs}} = socket, _params),
    do: put_result(socket, :jobs, Browser.list_jobs(socket.assigns.actor, limit: 100))

  defp load_for_page(socket, _params), do: socket

  defp put_result(socket, key, {:ok, value}), do: assign(socket, key, value)

  defp put_result(socket, _key, {:error, %Error{} = error}),
    do: assign(socket, :service_error, error)

  defp reload(socket) do
    {:noreply, load_page(socket, reload_params(socket)) |> assign(:loading?, false)}
  end

  defp reload(socket, params) do
    {:noreply, load_page(socket, params) |> assign(:loading?, false)}
  end

  defp begin_reload(socket) do
    params = reload_params(socket)
    send(self(), {:reload_browser_page, params})
    {:noreply, assign(socket, :loading?, true)}
  end

  defp reload_params(%{assigns: %{page: :job, job: %{id: id}}}), do: %{"id" => id}
  defp reload_params(_socket), do: %{}

  defp all_profiles(actor, nodes) do
    Enum.reduce_while(nodes, {:ok, []}, fn node, {:ok, profiles} ->
      case Browser.list_profiles(actor, node.id, limit: 100) do
        {:ok, node_profiles} -> {:cont, {:ok, profiles ++ node_profiles}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp page_artifacts(:new_job, _actor, _jobs), do: {:ok, []}
  defp page_artifacts(:dashboard, actor, jobs), do: all_artifacts(actor, jobs)

  defp all_artifacts(actor, jobs) do
    Enum.reduce_while(jobs, {:ok, []}, fn job, {:ok, artifacts} ->
      case Browser.list_artifacts(actor, job.id, limit: 100) do
        {:ok, job_artifacts} -> {:cont, {:ok, artifacts ++ job_artifacts}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp run_job_action(actor, job, "cancel"), do: Browser.cancel_job(actor, job.id)
  defp run_job_action(actor, job, "resume"), do: Browser.resume_job(actor, job.id)
  defp run_job_action(actor, job, "reconcile"), do: Browser.reconcile_job(actor, job.id)

  defp run_job_action(actor, %{session_id: session_id}, "manual_acquire")
       when is_binary(session_id),
       do: Browser.manual_acquire(actor, session_id)

  defp run_job_action(actor, %{session_id: session_id}, "manual_release")
       when is_binary(session_id),
       do: Browser.manual_release(actor, session_id)

  defp run_job_action(_actor, _job, action) when action in ~w(manual_acquire manual_release) do
    {:error,
     Error.new(
       "state",
       "invalid_job_state",
       "The job has no manual session.",
       false,
       "none",
       %{}
     )}
  end

  defp run_job_action(actor, job, "retry") do
    Browser.retry_job(actor, job.id, "ui-retry:#{job.id}:#{System.system_time(:millisecond)}")
  end

  defp workflow_input(%{"workflow" => "gemini.deep_research"} = params) do
    %{
      "prompt" => params["prompt"],
      "output_locale" => params["output_locale"],
      "research_scope" => params["research_scope"],
      "required_sections" => parse_required_sections(params["required_sections"]),
      "auto_approve_plan" => truthy?(params["auto_approve_plan"])
    }
  end

  defp workflow_input(%{"workflow" => "gemini.youtube_analysis"} = params) do
    %{
      "youtube_url" => params["youtube_url"],
      "analysis_profile" => params["analysis_profile"],
      "output_locale" => params["output_locale"],
      "custom_instructions" => params["custom_instructions"] || "",
      "use_deep_research" => truthy?(params["use_deep_research"])
    }
  end

  defp workflow_input(_params), do: %{}

  defp selected_output_formats(params) do
    optional =
      [
        {"report_html", "report.html"},
        {"screenshot_png", "screenshot.png"}
      ]
      |> Enum.filter(fn {key, _format} -> truthy?(params[key]) end)
      |> Enum.map(&elem(&1, 1))

    ["report.markdown", "report.json", "sources.json"] ++ optional
  end

  defp job_form do
    to_form(
      %{
        "workflow" => "gemini.deep_research",
        "workflow_version" => "1",
        "prompt" => "",
        "output_locale" => "en",
        "research_scope" => "public web sources",
        "required_sections" => "Summary\nEvidence",
        "youtube_url" => "",
        "analysis_profile" => "technical_review",
        "custom_instructions" => "",
        "node_id" => "",
        "profile_id" => "",
        "idempotency_key" => Ecto.UUID.generate(),
        "report_html" => false,
        "screenshot_png" => false,
        "auto_approve_plan" => false,
        "use_deep_research" => false
      },
      as: :job
    )
  end

  defp optional_id(attrs, _key, value) when value in [nil, ""], do: attrs
  defp optional_id(attrs, key, value), do: Map.put(attrs, key, value)

  defp parse_required_sections(value) when is_binary(value) do
    value
    |> String.split(~r/\R/u)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_required_sections(_value), do: []

  defp parse_origins(value) when is_binary(value) do
    value
    |> String.split(~r/\R/u)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_origins(_value), do: []

  defp profile_origins(%{policy: policy}) when is_map(policy) do
    case policy["allowed_origins"] || policy[:allowed_origins] do
      origins when is_list(origins) ->
        origins
        |> Enum.filter(&is_binary/1)
        |> Enum.take(16)
        |> Enum.join("\n")

      _invalid ->
        ""
    end
  end

  defp profile_origins(_profile), do: ""

  defp truthy?(value), do: value in [true, "true", "on", "1"]

  defp parse_integer(value) do
    case Integer.parse(to_string(value || "")) do
      {integer, ""} -> integer
      _other -> nil
    end
  end

  defp recent_errors(nodes, jobs) do
    node_errors =
      Enum.flat_map(nodes, fn node ->
        if node.last_error, do: [error_summary(node.last_error)], else: []
      end)

    job_errors =
      Enum.flat_map(jobs, fn job -> if job.error, do: [error_summary(job.error)], else: [] end)

    Enum.take(node_errors ++ job_errors, 8)
  end

  defp error_summary(error) when is_map(error),
    do: error["code"] || error[:code] || "Browser operation failed"

  defp error_summary(_error), do: "Browser operation failed"

  defp active_intervention(events, "waiting_human") do
    events
    |> Enum.filter(&(&1.event in ~w(intervention.required intervention.cleared)))
    |> Enum.max_by(& &1.sequence, fn -> nil end)
    |> case do
      %{event: "intervention.required"} = event -> event
      _none -> nil
    end
  end

  defp active_intervention(_events, _status), do: nil

  defp intervention_details(nil), do: {nil, nil}

  defp intervention_details(event) do
    code = event.metadata["intervention_reason"] || event.metadata["reason"]

    case Map.fetch(@intervention_instructions, code) do
      {:ok, instruction} -> {code, instruction}
      :error -> {"ui_contract_mismatch", @intervention_instructions["ui_contract_mismatch"]}
    end
  end

  defp manual_lease_label(%{mode: "manual"}), do: "Manual lease active"
  defp manual_lease_label(%{mode: "automation"}), do: "Automation paused; manual lease not held"
  defp manual_lease_label(_session), do: "Lease state unavailable"

  defp job_session(_actor, %{session_id: nil}), do: {:ok, nil}
  defp job_session(actor, %{session_id: session_id}), do: Browser.get_session(actor, session_id)

  defp authorized_chat_url(%{chat_url: nil}), do: nil

  defp authorized_chat_url(%{chat_url: url}) do
    case ChatURL.validate(url) do
      {:ok, authorized_url} -> authorized_url
      {:error, _reason} -> nil
    end
  end

  defp health_label(metadata) when is_map(metadata) do
    case metadata["manager_status"] || metadata[:manager_status] ||
           metadata["manager_health"] || metadata[:manager_health] do
      status when status in ~w(available degraded healthy unavailable) -> status
      _unknown -> "unknown"
    end
  end

  defp health_label(_metadata), do: "unknown"

  defp version_label(metadata, key) when is_map(metadata) do
    case metadata[key] do
      version when is_binary(version) and byte_size(version) <= 128 -> version
      _unknown -> "unknown"
    end
  end

  defp version_label(_metadata, _key), do: "unknown"

  defp tls_status(metadata) when is_map(metadata) do
    case metadata["tls_status"] || metadata[:tls_status] do
      status
      when status in ~w(verified expired not_yet_valid server_verified plaintext invalid) ->
        status

      _unknown ->
        "unknown"
    end
  end

  defp tls_status(_metadata), do: "unknown"

  defp tls_label(metadata) when is_map(metadata) do
    status = tls_status(metadata)
    expires_at = metadata["tls_expires_at"]
    remaining_seconds = metadata["tls_remaining_seconds"]

    if valid_tls_expiry?(expires_at) and
         is_integer(remaining_seconds) and remaining_seconds in 0..4_294_967_295 do
      "#{status} · expires #{expires_at} · #{remaining_validity(remaining_seconds)}"
    else
      status
    end
  end

  defp tls_label(_metadata), do: "unknown"

  defp valid_tls_expiry?(expires_at) when is_binary(expires_at) and byte_size(expires_at) <= 32 do
    case DateTime.from_iso8601(expires_at) do
      {:ok, datetime, 0} -> DateTime.to_iso8601(datetime) == expires_at
      _invalid -> false
    end
  end

  defp valid_tls_expiry?(_expires_at), do: false

  defp remaining_validity(seconds) when seconds >= 86_400,
    do: "#{div(seconds, 86_400)}d remaining"

  defp remaining_validity(seconds) when seconds >= 3_600,
    do: "#{div(seconds, 3_600)}h remaining"

  defp remaining_validity(seconds) when seconds >= 60,
    do: "#{div(seconds, 60)}m remaining"

  defp remaining_validity(_seconds), do: "<1m remaining"

  defp effective_node_status(%{online?: false, status: "online"}), do: "offline"
  defp effective_node_status(node), do: node.status

  defp state_counts(items, classifier), do: Enum.frequencies_by(items, classifier)

  defp state_summary(counts, order \\ []) do
    ordered =
      order ++
        (counts
         |> Map.keys()
         |> Enum.reject(&(&1 in order))
         |> Enum.sort())

    ordered
    |> Enum.filter(&Map.has_key?(counts, &1))
    |> Enum.map_join(", ", &"#{String.replace(&1, "_", " ")} #{counts[&1]}")
  end

  defp result_count(result, key) when is_map(result) do
    case result[key] do
      value when is_integer(value) and value >= 0 -> value
      _unknown -> "—"
    end
  end

  defp result_count(_result, _key), do: "—"

  defp error_code(error) when is_map(error), do: error["code"] || error[:code] || "unknown"
  defp error_code(_error), do: "unknown"

  defp safe_json(value) do
    JSON.encode!(value)
  rescue
    _error -> "{}"
  end

  defp format_datetime(nil), do: "—"
  defp format_datetime(%DateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S UTC")

  defp format_datetime(%NaiveDateTime{} = value),
    do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S")

  defp format_bytes(bytes) when bytes < 1_024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1_024, 1)} KiB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MiB"

  defp short_id(id), do: String.slice(id || "", 0, 8)

  defp status_variant(status)
       when status in ~w(online running ready available completed verified),
       do: "success"

  defp status_variant(status)
       when status in ~w(queued dispatching accepted opening acting collecting_artifacts uploading),
       do: "info"

  defp status_variant(status)
       when status in ~w(waiting waiting_human degraded unknown manual pending),
       do: "warning"

  defp status_variant(status)
       when status in ~w(failed rejected offline unavailable disabled orphaned cancelled),
       do: "error"

  defp status_variant(_status), do: "ghost"

  defp page_for(:nodes), do: :nodes
  defp page_for(:profiles), do: :profiles
  defp page_for(:sessions), do: :sessions
  defp page_for(:jobs), do: :jobs
  defp page_for(:new_job), do: :new_job
  defp page_for(:job), do: :job
  defp page_for(:settings), do: :settings
  defp page_for(:commander), do: :commander
  defp page_for(_action), do: :dashboard

  defp active_menu(:nodes), do: "browser_nodes"
  defp active_menu(:profiles), do: "browser_profiles"
  defp active_menu(:sessions), do: "browser_sessions"
  defp active_menu(page) when page in [:jobs, :new_job, :job], do: "browser_jobs"
  defp active_menu(:settings), do: "browser_settings"
  defp active_menu(:commander), do: "commander_list"
  defp active_menu(_page), do: "browser_dashboard"

  defp page_title(:nodes), do: "Browser Nodes"
  defp page_title(:profiles), do: "Browser Profiles"
  defp page_title(:sessions), do: "Browser Sessions"
  defp page_title(:jobs), do: "Browser Jobs"
  defp page_title(:new_job), do: "New Browser Job"
  defp page_title(:job), do: "Browser Job"
  defp page_title(:settings), do: "Browser Settings"
  defp page_title(:commander), do: "Commander Browser"
  defp page_title(_page), do: "Browser Control"
end
