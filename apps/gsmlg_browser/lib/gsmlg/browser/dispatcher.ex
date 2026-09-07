defmodule GSMLG.Browser.Dispatcher do
  @moduledoc false

  alias GSMLG.Browser

  def dispatch(job_id, opts \\ []), do: Browser.dispatch_job(job_id, opts)
  def reconcile(job_id, opts \\ []), do: Browser.reconcile_job_id(job_id, opts)
end
