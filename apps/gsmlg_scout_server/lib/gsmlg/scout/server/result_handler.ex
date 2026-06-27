defmodule GSMLG.Scout.Server.ResultHandler do
  @moduledoc false

  alias GSMLG.Scout.Fetch.Result
  alias GSMLG.Scout.Server.JobManager

  def handle_result(%Result{} = result) do
    JobManager.handle_result(result)
  end

  def handle_result(map) when is_map(map) do
    map
    |> Result.from_map()
    |> handle_result()
  end
end
