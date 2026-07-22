defmodule GSMLG.ProxyRules do
  alias GSMLG.ProxyRules.{Coordinator, Output, Store}

  @type list_name :: :proxy | :direct
  @type renderer :: :raw | :squid | :clash

  @spec get_artifact(list_name(), renderer()) ::
          {:ok, Output.t()} | {:error, :not_ready | :not_found}
  def get_artifact(list, renderer)
      when list in [:proxy, :direct] and renderer in [:raw, :squid, :clash] do
    with {:ok, snapshot} <- Store.current(),
         {:ok, outputs} <- Map.fetch(snapshot, :rendered_outputs),
         {:ok, list_outputs} <- Map.fetch(outputs, list),
         {:ok, %Output{} = artifact} <- Map.fetch(list_outputs, renderer) do
      {:ok, artifact}
    else
      {:error, :not_ready} = error -> error
      :error -> {:error, :not_found}
    end
  end

  def get_artifact(_list, _renderer), do: {:error, :not_found}

  @spec metadata() :: {:ok, map()} | {:error, :not_available}
  def metadata, do: safe_store_metadata()

  @spec refresh() :: {:ok, :accepted} | {:error, :not_available}
  def refresh, do: Coordinator.refresh()

  defp safe_store_metadata do
    Store.metadata()
  catch
    :exit, _reason -> {:error, :not_available}
  end
end
