defmodule GSMLG.Browser.Enabled do
  @moduledoc false

  def ensure do
    if Application.get_env(:gsmlg_browser, :enabled, false) == true,
      do: :ok,
      else: {:error, :service_unavailable}
  end
end
