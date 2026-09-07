defmodule GSMLG.Browser.JobState do
  @moduledoc false

  @terminal ~w(completed failed cancelled)
  @edges %{
    "queued" => ~w(dispatching cancelled),
    "dispatching" => ~w(accepted unknown failed cancelled),
    "unknown" =>
      ~w(accepted running waiting_human collecting_artifacts completed failed cancelled),
    "accepted" =>
      ~w(running waiting_human collecting_artifacts completed failed cancelled unknown),
    "running" => ~w(waiting_human collecting_artifacts completed failed cancelled unknown),
    "waiting_human" => ~w(running collecting_artifacts completed failed cancelled unknown),
    "collecting_artifacts" => ~w(completed failed cancelled unknown)
  }

  def terminal?(status), do: status in @terminal
  def valid?(status, status), do: true
  def valid?(from, to), do: to in Map.get(@edges, from, [])

  def validate(from, to) do
    if valid?(from, to), do: :ok, else: {:error, :illegal_job_transition}
  end
end
