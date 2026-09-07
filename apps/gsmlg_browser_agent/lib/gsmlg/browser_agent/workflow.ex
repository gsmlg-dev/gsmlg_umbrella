defmodule GSMLG.BrowserAgent.Workflow do
  @moduledoc "Versioned pure workflow contract and finite decision/event vocabularies."

  @decision_types [:action, :wait, :emit_event, :request_human, :complete, :fail]
  @event_vocabulary ~w(workflow.accepted workflow.started workflow.phase_changed intervention.required intervention.cleared artifact.available result.available workflow.failed workflow.cancelled workflow.completed)

  @callback id() :: String.t()
  @callback version() :: pos_integer()
  @callback phases() :: [atom()]
  @callback input_schema() :: map()
  @callback output_schema() :: map()
  @callback required_origins() :: [String.t()]
  @callback profile_capabilities() :: [String.t()]
  @callback initial_state(map()) :: {:ok, map()} | {:error, atom()}
  @callback transition(map(), map()) ::
              {:ok, map(), GSMLG.BrowserAgent.Workflow.Decision.t()} | {:error, atom()}
  @callback extract_result(map(), map()) :: {:ok, map()} | {:error, atom()}

  def decision_types, do: @decision_types
  def event_vocabulary, do: @event_vocabulary

  def module("gemini.deep_research/v1"),
    do: {:ok, GSMLG.BrowserAgent.Workflows.Gemini.DeepResearch}

  def module("gemini.youtube_analysis/v1"),
    do: {:ok, GSMLG.BrowserAgent.Workflows.Gemini.YouTubeAnalysis}

  def module(_unknown), do: {:error, :workflow_not_supported}
end

defmodule GSMLG.BrowserAgent.Workflow.Decision do
  @moduledoc "A closed, data-only workflow decision."

  @enforce_keys [:type]
  defstruct [:type, :action, :wait_ms, :event, :metadata, :reason, :result, :code]

  @type t :: %__MODULE__{}

  def action(action) when is_map(action), do: %__MODULE__{type: :action, action: action}

  def wait(wait_ms) when is_integer(wait_ms) and wait_ms > 0,
    do: %__MODULE__{type: :wait, wait_ms: wait_ms}

  def emit(event, metadata \\ %{}) when is_binary(event) and is_map(metadata),
    do: %__MODULE__{type: :emit_event, event: event, metadata: metadata}

  def request_human(reason) when is_atom(reason),
    do: %__MODULE__{type: :request_human, reason: reason}

  def complete(result) when is_map(result), do: %__MODULE__{type: :complete, result: result}
  def fail(code) when is_atom(code), do: %__MODULE__{type: :fail, code: code}
end
