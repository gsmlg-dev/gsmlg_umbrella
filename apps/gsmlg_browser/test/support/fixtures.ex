defmodule GSMLG.Browser.Fixtures do
  alias GSMLG.Browser.{Job, Node, Profile}
  alias GSMLG.Repo

  def node_fixture(attrs \\ %{}) do
    suffix = System.unique_integer([:positive])

    defaults = %{
      commander_id: "browser-node-#{suffix}",
      status: "offline",
      default_backend: "cloakbrowser",
      capabilities: [],
      limits: %{}
    }

    %Node{}
    |> Node.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  def profile_fixture(node, attrs \\ %{}) do
    suffix = System.unique_integer([:positive])

    defaults = %{
      node_id: node.id,
      external_id: "profile-#{suffix}",
      name: "Research #{suffix}",
      backend: "cloakbrowser",
      is_default: true,
      runtime_status: "stopped",
      automation_status: "available",
      policy: %{"allowed_origins" => ["https://gemini.google.com"]}
    }

    %Profile{}
    |> Profile.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  def job_fixture(actor, node, profile, attrs \\ %{}) do
    suffix = System.unique_integer([:positive])

    defaults = %{
      node_id: node.id,
      profile_id: profile.id,
      workflow: "gemini.deep_research",
      workflow_version: 1,
      status: "queued",
      input: %{
        "prompt" => "Research OTP",
        "output_locale" => "en-US",
        "research_scope" => "Public technical sources",
        "required_sections" => ["Summary", "Evidence"],
        "auto_approve_plan" => true
      },
      output_formats: ["report.markdown", "report.json", "sources.json"],
      idempotency_key: "job-#{suffix}",
      requested_by_actor_id: actor.id,
      deadline_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    }

    %Job{}
    |> Job.create_changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end
end
