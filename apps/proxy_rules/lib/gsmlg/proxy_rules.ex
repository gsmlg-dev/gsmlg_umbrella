defmodule GSMLG.ProxyRules do
  alias GSMLG.ProxyRules.{Coordinator, Output, SourcePage, Store}

  @type list_name :: :proxy | :direct
  @type renderer :: :raw | :squid | :clash

  @spec get_artifact(list_name(), renderer()) ::
          {:ok, Output.t()} | {:error, :not_ready | :not_found}
  def get_artifact(list, renderer) do
    with {:ok, %{output: output}} <- get_artifact_response(list, renderer) do
      {:ok, output}
    end
  end

  @spec get_artifact_response(list_name(), renderer()) ::
          {:ok, %{generation: non_neg_integer(), output: Output.t()}}
          | {:error, :not_ready | :not_found}
  def get_artifact_response(list, renderer)
      when list in [:proxy, :direct] and renderer in [:raw, :squid, :clash] do
    with {:ok, snapshot} <- Store.current(),
         {:ok, generation} <- Map.fetch(snapshot, :generation),
         {:ok, outputs} <- Map.fetch(snapshot, :rendered_outputs),
         {:ok, list_outputs} <- Map.fetch(outputs, list),
         {:ok, %Output{} = artifact} <- Map.fetch(list_outputs, renderer) do
      {:ok, %{generation: generation, output: artifact}}
    else
      {:error, :not_ready} = error -> error
      :error -> {:error, :not_found}
    end
  end

  def get_artifact_response(_list, _renderer), do: {:error, :not_found}

  @spec metadata() :: {:ok, map()} | {:error, :not_available}
  def metadata do
    with {:ok, metadata} <- safe_store_metadata() do
      {:ok, merge_source_metadata(metadata)}
    end
  end

  @spec refresh() :: {:ok, :accepted} | {:error, :not_available}
  def refresh, do: Coordinator.refresh()

  @spec get_source_page(:remote_gfwlist | :local_proxy, binary() | nil, keyword()) ::
          {:ok, map()}
          | {:error,
             :invalid_cursor
             | :source_changed
             | :page_too_large
             | :not_found
             | :not_available}
  def get_source_page(source, cursor \\ nil, options \\ [])

  def get_source_page(source, cursor, options)
      when source in [:remote_gfwlist, :local_proxy] and is_list(options) do
    with {:ok, snapshot} <- Coordinator.source_snapshot(source) do
      SourcePage.page(source, snapshot, cursor, options)
    end
  end

  def get_source_page(_source, _cursor, _options), do: {:error, :not_found}

  defp safe_store_metadata do
    Store.metadata()
  catch
    :exit, _reason -> {:error, :not_available}
  end

  defp merge_source_metadata(metadata) do
    case Coordinator.source_metadata() do
      sources when is_map(sources) -> Map.put(metadata, :sources, sources)
      {:error, :not_available} -> metadata
    end
  end
end
