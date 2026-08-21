defmodule GSMLG.ProxyRules do
  alias GSMLG.ProxyRules.{Coordinator, Output, SourcePage, Store}
  alias GSMLG.ProxyRules.Source.Local
  alias GSMLG.ProxyRules.ZeroOmega.{Export, PublishedPolicy, RenderedRuleList}

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

  @type zeroomega_format :: :switchy | :pac

  @spec export_zeroomega(zeroomega_format(), keyword()) ::
          {:ok,
           %{
             generation: non_neg_integer(),
             compiled_at: DateTime.t(),
             output: RenderedRuleList.t()
           }}
          | {:error, :not_ready | :not_found | [GSMLG.ProxyRules.ZeroOmega.Diagnostic.t()]}
  def export_zeroomega(format, options)
      when format in [:switchy, :pac] and is_list(options) do
    with {:ok, snapshot} <- Store.current(),
         {:ok, policy} <- PublishedPolicy.to_policy(snapshot.zeroomega_policy),
         {:ok, output} <-
           policy
           |> Export.normalize()
           |> Export.validate_for(format, options)
           |> Export.render() do
      {:ok,
       %{
         generation: snapshot.generation,
         compiled_at: snapshot.compiled_at,
         output: output
       }}
    end
  end

  def export_zeroomega(_format, _options), do: {:error, :not_found}

  @spec metadata() :: {:ok, map()} | {:error, :not_available}
  def metadata do
    with {:ok, metadata} <- safe_store_metadata() do
      {:ok, merge_source_metadata(metadata)}
    end
  end

  @spec refresh() :: {:ok, :accepted} | {:error, :not_available}
  def refresh, do: Coordinator.refresh()

  @spec add_local_proxy_domains(binary()) ::
          {:ok, Local.mutation_result()} | {:error, Local.mutation_failure()}
  def add_local_proxy_domains(text), do: add_local_proxy_domains(text, Local, 30_000)

  @doc false
  @spec add_local_proxy_domains(binary(), GenServer.server(), timeout()) ::
          {:ok, Local.mutation_result()} | {:error, Local.mutation_failure()}
  def add_local_proxy_domains(text, server, timeout) when is_binary(text) do
    Local.add_proxy_domains(server, text, timeout)
  catch
    :exit, _reason -> {:error, :not_available}
  end

  def add_local_proxy_domains(_text, _server, _timeout), do: {:error, {:invalid_batch, []}}

  @spec add_local_direct_domains(binary()) ::
          {:ok, Local.mutation_result()} | {:error, Local.mutation_failure()}
  def add_local_direct_domains(text), do: add_local_direct_domains(text, Local, 30_000)

  @doc false
  @spec add_local_direct_domains(binary(), GenServer.server(), timeout()) ::
          {:ok, Local.mutation_result()} | {:error, Local.mutation_failure()}
  def add_local_direct_domains(text, server, timeout) when is_binary(text) do
    Local.add_domains(server, :direct, text, timeout)
  catch
    :exit, _reason -> {:error, :not_available}
  end

  def add_local_direct_domains(_text, _server, _timeout), do: {:error, {:invalid_batch, []}}

  @spec get_source_page(:remote_gfwlist | :local_proxy | :local_direct, binary() | nil, keyword()) ::
          {:ok, map()}
          | {:error,
             :invalid_cursor
             | :source_changed
             | :page_too_large
             | :not_found
             | :not_available}
  def get_source_page(source, cursor \\ nil, options \\ [])

  def get_source_page(source, cursor, options)
      when source in [:remote_gfwlist, :local_proxy, :local_direct] and is_list(options) do
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
