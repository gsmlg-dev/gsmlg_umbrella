defmodule GSMLG.BrowserAgent.SafeBrowser.Adapter do
  @moduledoc false

  alias GSMLG.BrowserAgent.Action

  @callback observe(term(), pos_integer()) :: {:ok, map()} | {:error, atom()}
  @callback execute(term(), Action.t(), map() | nil, pos_integer()) ::
              {:ok,
               map()
               | {:artifact, String.t(), String.t(), binary()}
               | {:artifact, String.t(), String.t(), binary(), map()}
               | {:artifact, String.t(), String.t(), binary(), map(), term()}}
              | {:error, atom() | tuple()}
  @callback observation_epoch(term()) :: {:ok, non_neg_integer()} | {:error, atom()}
  @callback cleanup_output(term(), term()) :: :ok | {:error, atom()}
  @callback resolve_locator(term(), GSMLG.BrowserAgent.Locator.t(), pos_integer()) ::
              {:ok, map()} | {:error, atom()}
  @optional_callbacks observation_epoch: 1, cleanup_output: 2, resolve_locator: 3
end

defmodule GSMLG.BrowserAgent.SafeBrowser do
  @moduledoc "Lease-checked, revisioned, durably journaled safe browser boundary."

  alias GSMLG.BrowserAgent.{Action, ArtifactOutbox, Journal, Locator, Observation, OriginPolicy}
  alias GSMLG.BrowserAgent.{Postcondition, ProfileLease, ProfileLeaseServer}

  @action_history_limit 16
  @action_result_overhead_bytes 65_536

  @enforce_keys [
    :session_id,
    :central_session_id,
    :profile_id,
    :lease_id,
    :journal,
    :lease_server,
    :client,
    :adapter,
    :origin_policy,
    :clock
  ]
  defstruct [
    :session_id,
    :central_session_id,
    :profile_id,
    :lease_id,
    :journal,
    :lease_server,
    :client,
    :adapter,
    :origin_policy,
    :resolver,
    :clock,
    :monotonic_ms,
    :sleeper,
    :observation_epoch,
    :artifact_job_id,
    :artifact_remote_execution_id,
    revision: 0,
    observation: nil,
    allow_css_locator: false,
    allow_screenshots: false,
    allow_downloads: false,
    state_dir: nil,
    max_artifact_bytes: 10_485_760,
    observation_ttl_ms: 30_000,
    max_observation_nodes: 2_000,
    max_observation_depth: 16,
    max_observation_bytes: 1_048_576,
    wait_poll_ms: 100
  ]

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_safe_browser}
  def new(opts) do
    required = [
      :session_id,
      :central_session_id,
      :profile_id,
      :lease_id,
      :journal,
      :lease_server,
      :client,
      :adapter,
      :origin_policy,
      :clock
    ]

    if Enum.all?(required, &Keyword.has_key?(opts, &1)) do
      {:ok,
       struct!(__MODULE__,
         session_id: opts[:session_id],
         central_session_id: Keyword.get(opts, :central_session_id),
         profile_id: opts[:profile_id],
         lease_id: opts[:lease_id],
         journal: opts[:journal],
         lease_server: opts[:lease_server],
         client: opts[:client],
         adapter: opts[:adapter],
         origin_policy: opts[:origin_policy],
         resolver: Keyword.get(opts, :resolver),
         clock: opts[:clock],
         monotonic_ms:
           Keyword.get(opts, :monotonic_ms, fn -> System.monotonic_time(:millisecond) end),
         sleeper: Keyword.get(opts, :sleeper, &Process.sleep/1),
         observation_epoch: Keyword.get(opts, :observation_epoch),
         artifact_job_id: Keyword.get(opts, :artifact_job_id),
         artifact_remote_execution_id: Keyword.get(opts, :artifact_remote_execution_id),
         revision: Keyword.get(opts, :revision, 0),
         observation: Keyword.get(opts, :observation),
         allow_css_locator: Keyword.get(opts, :allow_css_locator, false),
         allow_screenshots: Keyword.get(opts, :allow_screenshots, false),
         allow_downloads: Keyword.get(opts, :allow_downloads, false),
         state_dir: Keyword.get(opts, :state_dir),
         max_artifact_bytes: Keyword.get(opts, :max_artifact_bytes, 10_485_760),
         observation_ttl_ms: Keyword.get(opts, :observation_ttl_ms, 30_000),
         max_observation_nodes: Keyword.get(opts, :max_observation_nodes, 2_000),
         max_observation_depth: Keyword.get(opts, :max_observation_depth, 16),
         max_observation_bytes: Keyword.get(opts, :max_observation_bytes, 1_048_576),
         wait_poll_ms: Keyword.get(opts, :wait_poll_ms, 100)
       )}
    else
      {:error, :invalid_safe_browser}
    end
  end

  @spec observe(t(), keyword()) :: {:ok, map(), t()} | {:error, atom(), t()}
  def observe(%__MODULE__{} = browser, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, 5_000)

    with :ok <- validate_lease(browser),
         {:ok, raw} <- browser.adapter.observe(browser.client, timeout),
         :ok <- authorize_observation(browser, raw),
         {:ok, observation} <- build_observation(browser, raw),
         {:ok, epoch} <- adapter_epoch(browser) do
      {:ok, observation,
       %{
         browser
         | revision: observation["revision"],
           observation: observation,
           observation_epoch: epoch
       }}
    else
      {:error, reason} -> {:error, normalize_observation_error(reason), browser}
    end
  end

  @spec execute(t(), map()) :: {:ok, map(), t()} | {:error, atom(), t()}
  def execute(%__MODULE__{} = browser, action_map) when is_map(action_map) do
    with {:ok, action} <- Action.decode(action_map, allow_css_locator: browser.allow_css_locator),
         deadline = browser.monotonic_ms.() + action.timeout_ms,
         true <- action.session_id == browser.session_id,
         {:execute, entry} <- begin_action(browser, action_map),
         {:ok, browser} <- validate_action(browser, action, entry, deadline),
         {:ok, target} <- resolve_target(browser, action),
         {:ok, result, browser} <- dispatch_and_verify(browser, action, target, entry, deadline) do
      {:ok, result, browser}
    else
      {:replay, {:ok, result}} -> {:ok, result, browser}
      {:replay, {:error, reason}} -> {:error, reason, browser}
      {:error, reason, %__MODULE__{} = changed} -> {:error, reason, changed}
      {:error, reason} -> {:error, normalize_action_error(reason), browser}
      false -> {:error, :action_not_allowed, browser}
    end
  end

  def execute(%__MODULE__{} = browser, _action), do: {:error, :action_not_allowed, browser}

  @spec recover_actions(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def recover_actions(journal, session_id) do
    with {:ok, entries} <-
           Journal.recovery_list(journal, :pending_action,
             session_id: session_id,
             statuses: [
               :received,
               :journaled,
               :validating,
               :executing,
               :verifying,
               :outcome_unknown
             ]
           ) do
      Enum.reduce_while(entries, :ok, fn
        {{^session_id, _action_id} = key, %{status: status} = entry}, :ok
        when status in [:received, :journaled, :validating] ->
          recovered =
            entry
            |> Map.merge(%{status: :failed, retryable: true, error_code: :action_not_executed})
            |> append_history(:failed)

          persist_recovery(journal, key, recovered)

        {{^session_id, _action_id} = key, %{status: status} = entry}, :ok
        when status in [:executing, :verifying] ->
          recovered =
            entry
            |> Map.merge(%{
              status: :outcome_unknown,
              retryable: false,
              error_code: :action_outcome_unknown
            })
            |> append_history(:outcome_unknown)

          persist_recovery(journal, key, recovered)

        _entry, :ok ->
          {:cont, :ok}
      end)
    end
  catch
    :exit, _reason -> {:error, :journal_unavailable}
  end

  defp begin_action(browser, action_map) do
    key = {browser.session_id, action_map["action_id"]}
    fingerprint = fingerprint(action_map)

    case journal_get(browser.journal, key) do
      :error ->
        entry = %{
          action_id: action_map["action_id"],
          session_id: browser.session_id,
          fingerprint: fingerprint,
          status: :journaled,
          retryable: false,
          retention_reserved_bytes: action_result_reservation(browser),
          history: [:received, :journaled]
        }

        case journal_put(browser.journal, key, entry) do
          :ok -> {:execute, entry}
          {:error, _reason} -> {:error, :journal_unavailable}
        end

      {:ok, %{fingerprint: existing}} when existing != fingerprint ->
        {:error, :action_id_collision}

      {:ok, %{status: :completed, result: result}} ->
        {:replay, {:ok, result}}

      {:ok, %{status: :outcome_unknown}} ->
        {:replay, {:error, :action_outcome_unknown}}

      {:ok, %{status: :failed, retryable: true} = previous} ->
        entry =
          previous
          |> Map.merge(%{status: :journaled, retryable: false, error_code: nil})
          |> Map.put_new(:retention_reserved_bytes, action_result_reservation(browser))
          |> append_history(:journaled)

        case journal_put(browser.journal, key, entry) do
          :ok -> {:execute, entry}
          {:error, _reason} -> {:error, :journal_unavailable}
        end

      {:ok, %{status: status, error_code: reason}}
      when status in [:failed, :rejected] and is_atom(reason) ->
        {:replay, {:error, reason}}

      {:ok, _in_progress_or_failed} ->
        {:error, :action_in_progress}
    end
  end

  defp validate_action(browser, action, entry, deadline) do
    validating = transition(entry, :validating)

    with :ok <- journal_put(browser.journal, action_key(browser, action), validating),
         :ok <- validate_revision(browser, action.expected_revision),
         :ok <- validate_observation_available(browser, action),
         :ok <- validate_observation_expiry(browser),
         :ok <- validate_lease(browser),
         :ok <- validate_permission(browser, action),
         :ok <- validate_navigation(browser, action),
         :ok <- validate_document_epoch(browser),
         :ok <- validate_preconditions(browser, action),
         {:ok, _remaining} <- remaining_timeout(browser, deadline) do
      {:ok, browser}
    else
      {:error, reason} ->
        reason = normalize_action_error(reason)

        case reject_action(browser, action, validating, reason) do
          :ok -> {:error, reason}
          {:error, _journal_reason} -> {:error, :journal_unavailable}
        end
    end
  end

  defp dispatch_and_verify(browser, %Action{type: type} = action, target, entry, deadline)
       when type != :wait_for do
    key = action_key(browser, action)
    validating = transition(entry, :validating)
    executing = transition(validating, :executing)

    with :ok <- journal_put(browser.journal, key, executing),
         {:ok, timeout} <- remaining_timeout(browser, deadline),
         {:ok, raw_output} <-
           browser.adapter.execute(browser.client, action, target, timeout),
         {:ok, _remaining} <- remaining_timeout(browser, deadline),
         {:ok, output} <- materialize_output(browser, action, raw_output),
         {:ok, _remaining} <- remaining_timeout(browser, deadline),
         verifying = transition(executing, :verifying),
         :ok <- journal_put(browser.journal, key, verifying),
         {:ok, observation_timeout} <- remaining_timeout(browser, deadline) do
      case observe(browser, timeout_ms: observation_timeout) do
        {:ok, observation, changed} ->
          case remaining_timeout(changed, deadline) do
            {:ok, _remaining} ->
              verify_and_complete(changed, action, observation, output, verifying)

            {:error, _expired} ->
              unknown_action(changed, action, verifying)
          end

        {:error, _reason, changed} ->
          unknown_action(changed, action, verifying)
      end
    else
      {:error, reason} ->
        finish_after_dispatch_error(browser, action, executing, reason)
    end
  end

  defp dispatch_and_verify(
         browser,
         %Action{type: :wait_for} = action,
         _target,
         entry,
         deadline
       ) do
    key = action_key(browser, action)
    validating = transition(entry, :validating)
    executing = transition(validating, :executing)
    verifying = transition(executing, :verifying)

    with :ok <- journal_put(browser.journal, key, executing),
         :ok <- journal_put(browser.journal, key, verifying),
         {:ok, observation, browser} <- poll_for_locator(browser, action, deadline) do
      result = %{
        "action_id" => action.action_id,
        "revision" => observation["revision"],
        "observation" => observation,
        "output" => %{}
      }

      completed =
        verifying
        |> Map.merge(%{status: :completed, retryable: false, result: result})
        |> append_history(:completed)

      case journal_put(browser.journal, key, completed) do
        :ok -> {:ok, result, browser}
        {:error, _reason} -> {:error, :journal_unavailable, browser}
      end
    else
      {:error, reason, %__MODULE__{} = changed} ->
        finish_after_read_error(changed, action, verifying, reason)

      {:error, reason} ->
        finish_after_read_error(browser, action, verifying, reason)
    end
  end

  defp verify_and_complete(browser, action, observation, output, verifying) do
    case Postcondition.verify_all(action.postconditions, observation) do
      :ok ->
        result = %{
          "action_id" => action.action_id,
          "revision" => observation["revision"],
          "observation" => observation,
          "output" => output
        }

        completed =
          verifying
          |> Map.merge(%{status: :completed, retryable: false, result: result})
          |> append_history(:completed)

        case journal_put(browser.journal, action_key(browser, action), completed) do
          :ok -> {:ok, result, browser}
          {:error, _reason} -> unknown_action(browser, action, verifying)
        end

      {:error, _reason} ->
        unknown_action(browser, action, verifying)
    end
  end

  defp finish_after_dispatch_error(browser, %Action{type: :download} = action, entry, _reason),
    do: unknown_action(browser, action, entry)

  defp finish_after_dispatch_error(browser, action, entry, {:cdp_error, _code}),
    do: unknown_action(browser, action, entry)

  defp finish_after_dispatch_error(browser, action, entry, reason)
       when reason in [
              :action_outcome_unknown,
              :cdp_disconnected,
              :cdp_invalid_response,
              :cdp_timeout,
              :journal_unavailable,
              :navigation_not_allowed,
              :observation_failed
            ] do
    unknown_action(browser, action, entry)
  end

  defp finish_after_dispatch_error(browser, action, entry, reason) do
    reason = normalize_action_error(reason)

    failed =
      entry
      |> Map.merge(%{status: :failed, retryable: false, error_code: reason})
      |> append_history(:failed)

    case journal_put(browser.journal, action_key(browser, action), failed) do
      :ok -> {:error, reason, browser}
      {:error, _journal_reason} -> {:error, :action_outcome_unknown, browser}
    end
  end

  defp unknown_action(browser, action, entry) do
    unknown =
      entry
      |> Map.merge(%{
        status: :outcome_unknown,
        retryable: false,
        error_code: :action_outcome_unknown
      })
      |> append_history(:outcome_unknown)

    _ = journal_put(browser.journal, action_key(browser, action), unknown)
    {:error, :action_outcome_unknown, browser}
  end

  defp reject_action(browser, action, entry, reason) do
    rejected =
      entry
      |> Map.merge(%{status: :rejected, retryable: false, error_code: reason})
      |> append_history(:rejected)

    journal_put(browser.journal, action_key(browser, action), rejected)
  end

  defp validate_revision(_browser, nil), do: :ok
  defp validate_revision(%{revision: revision}, revision), do: :ok
  defp validate_revision(_browser, _expected), do: {:error, :stale_observation}

  defp validate_observation_available(_browser, %Action{type: :navigate}), do: :ok

  defp validate_observation_available(%{observation: nil}, _action),
    do: {:error, :stale_observation}

  defp validate_observation_available(_browser, _action), do: :ok

  defp validate_observation_expiry(%{observation: nil}), do: :ok

  defp validate_observation_expiry(%{observation: %{"expires_at" => expires_at}, clock: clock}) do
    with {:ok, expires_at, _offset} <- DateTime.from_iso8601(expires_at),
         :gt <- DateTime.compare(expires_at, clock.()) do
      :ok
    else
      _expired_or_invalid -> {:error, :stale_observation}
    end
  end

  defp validate_lease(browser) do
    case ProfileLeaseServer.get(browser.lease_server, browser.profile_id) do
      {:ok,
       %ProfileLease{
         lease_id: lease_id,
         owner_type: :automation,
         owner_id: session_id,
         expires_at: expires_at
       }}
      when lease_id == browser.lease_id and session_id == browser.session_id ->
        if DateTime.compare(expires_at, browser.clock.()) == :gt,
          do: :ok,
          else: {:error, :lease_conflict}

      _missing_or_changed ->
        {:error, :lease_conflict}
    end
  catch
    :exit, _reason -> {:error, :lease_conflict}
  end

  defp validate_navigation(browser, %Action{type: :navigate, input: %{"url" => url}}) do
    OriginPolicy.authorize(browser.origin_policy, url, resolver_opts(browser)) |> ok_only()
  end

  defp validate_navigation(_browser, _action), do: :ok

  defp validate_permission(%{allow_screenshots: true}, %Action{type: :screenshot}), do: :ok

  defp validate_permission(_browser, %Action{type: :screenshot}),
    do: {:error, :action_not_allowed}

  defp validate_permission(%{allow_downloads: true}, %Action{type: :download}), do: :ok
  defp validate_permission(_browser, %Action{type: :download}), do: {:error, :action_not_allowed}
  defp validate_permission(_browser, _action), do: :ok

  defp validate_preconditions(%{observation: observation}, %{preconditions: conditions}) do
    Postcondition.verify_all(conditions, observation || %{})
  end

  defp validate_document_epoch(%{observation: nil}), do: :ok
  defp validate_document_epoch(%{observation_epoch: nil}), do: :ok

  defp validate_document_epoch(browser) do
    case adapter_epoch(browser) do
      {:ok, epoch} when epoch == browser.observation_epoch -> :ok
      {:ok, _changed} -> {:error, :stale_observation}
      {:error, reason} -> {:error, reason}
    end
  end

  defp adapter_epoch(browser) do
    if function_exported?(browser.adapter, :observation_epoch, 1) do
      browser.adapter.observation_epoch(browser.client)
    else
      {:ok, nil}
    end
  rescue
    _exception -> {:error, :cdp_disconnected}
  catch
    :exit, _reason -> {:error, :cdp_disconnected}
  end

  defp resolve_target(_browser, %Action{type: :wait_for, locator: locator}), do: {:ok, locator}
  defp resolve_target(_browser, %Action{locator: nil}), do: {:ok, nil}

  defp resolve_target(_browser, %Action{locator: %Locator{type: :css} = locator}),
    do: {:ok, locator}

  defp resolve_target(%{observation: observation}, %Action{locator: locator}) do
    Locator.find(observation || %{}, locator)
  end

  defp build_observation(browser, raw) do
    Observation.build(raw,
      session_id: browser.session_id,
      lease_id: browser.lease_id,
      revision: browser.revision + 1,
      observed_at: browser.clock.(),
      ttl_ms: browser.observation_ttl_ms,
      max_nodes: browser.max_observation_nodes,
      max_depth: browser.max_observation_depth,
      max_bytes: browser.max_observation_bytes
    )
  end

  defp authorize_observation(browser, %{"url" => url}) do
    OriginPolicy.authorize(browser.origin_policy, url, resolver_opts(browser)) |> ok_only()
  end

  defp authorize_observation(_browser, _raw), do: {:error, :invalid_observation}

  defp resolver_opts(%{resolver: nil}), do: []
  defp resolver_opts(%{resolver: resolver}), do: [resolver: resolver]

  defp poll_for_locator(browser, action, deadline) do
    remaining = deadline - browser.monotonic_ms.()

    if remaining <= 0 do
      {:error, :action_target_not_found, browser}
    else
      poll_for_locator(browser, action, deadline, remaining)
    end
  end

  defp poll_for_locator(browser, action, deadline, remaining) do
    case observe(browser, timeout_ms: min(remaining, 5_000)) do
      {:ok, observation, changed} ->
        with {:ok, _node} <- find_wait_target(changed, observation, action.locator, remaining),
             :ok <- Postcondition.verify_all(action.postconditions, observation) do
          {:ok, observation, changed}
        else
          {:error, _reason} -> retry_wait(changed, action, deadline)
        end

      {:error, reason, changed} ->
        {:error, reason, changed}
    end
  end

  defp find_wait_target(browser, _observation, %Locator{type: :css} = locator, timeout) do
    if function_exported?(browser.adapter, :resolve_locator, 3) do
      browser.adapter.resolve_locator(browser.client, locator, min(timeout, 5_000))
    else
      {:error, :action_target_not_found}
    end
  rescue
    _exception -> {:error, :cdp_disconnected}
  catch
    :exit, _reason -> {:error, :cdp_disconnected}
  end

  defp find_wait_target(_browser, observation, locator, _timeout),
    do: Locator.find(observation, locator)

  defp retry_wait(browser, action, deadline) do
    if browser.monotonic_ms.() >= deadline do
      {:error, :action_target_not_found, browser}
    else
      remaining = deadline - browser.monotonic_ms.()
      browser.sleeper.(min(browser.wait_poll_ms, max(remaining, 0)))
      poll_for_locator(browser, action, deadline)
    end
  end

  defp remaining_timeout(browser, deadline) do
    case deadline - browser.monotonic_ms.() do
      remaining when remaining > 0 -> {:ok, remaining}
      _expired -> {:error, :cdp_timeout}
    end
  end

  defp finish_after_read_error(browser, action, entry, reason) do
    reason = normalize_action_error(reason)

    failed =
      entry
      |> Map.merge(%{status: :failed, retryable: true, error_code: reason})
      |> append_history(:failed)

    case journal_put(browser.journal, action_key(browser, action), failed) do
      :ok -> {:error, reason, browser}
      {:error, _journal_reason} -> {:error, :journal_unavailable, browser}
    end
  end

  defp materialize_output(
         browser,
         action,
         {:artifact, kind, mime, content}
       )
       when kind in ["screenshot", "download"] and is_binary(mime) and is_binary(content) do
    persist_artifact(browser, action, kind, mime, content, %{})
  end

  defp materialize_output(
         browser,
         action,
         {:artifact, "download" = kind, mime, content, metadata, cleanup}
       )
       when is_binary(mime) and is_binary(content) and is_map(metadata) do
    result =
      with {:ok, source_origin} <- authorize_artifact_source(browser, metadata["source_url"]),
           {:ok, filename} <- safe_artifact_filename(metadata["suggested_filename"]) do
        persist_artifact(browser, action, kind, mime, content, %{
          "source_origin" => source_origin,
          "suggested_filename" => filename
        })
      end

    cleanup_result = cleanup_output(browser, cleanup)

    case {result, cleanup_result} do
      {{:ok, _output} = success, :ok} -> success
      {{:error, _reason} = error, _cleanup} -> error
      {_persisted, {:error, reason}} -> {:error, reason}
    end
  end

  defp materialize_output(
         browser,
         action,
         {:artifact, "download" = kind, mime, content, metadata}
       )
       when is_binary(mime) and is_binary(content) and is_map(metadata) do
    with {:ok, source_origin} <- authorize_artifact_source(browser, metadata["source_url"]),
         {:ok, filename} <- safe_artifact_filename(metadata["suggested_filename"]) do
      persist_artifact(browser, action, kind, mime, content, %{
        "source_origin" => source_origin,
        "suggested_filename" => filename
      })
    end
  end

  defp materialize_output(_browser, _action, {:artifact, _kind, _mime, _content, _metadata}),
    do: {:error, :artifact_unavailable}

  defp materialize_output(_browser, _action, output) when is_map(output), do: {:ok, output}
  defp materialize_output(_browser, _action, _output), do: {:error, :action_failed}

  defp cleanup_output(browser, cleanup) do
    if function_exported?(browser.adapter, :cleanup_output, 2) do
      case browser.adapter.cleanup_output(browser.client, cleanup) do
        :ok -> :ok
        {:error, _reason} -> {:error, :action_outcome_unknown}
        _invalid -> {:error, :action_outcome_unknown}
      end
    else
      {:error, :action_outcome_unknown}
    end
  rescue
    _exception -> {:error, :action_outcome_unknown}
  catch
    :exit, _reason -> {:error, :action_outcome_unknown}
  end

  defp persist_artifact(browser, action, kind, mime, content, artifact_metadata) do
    attrs = artifact_attrs(browser, action, kind, mime, artifact_metadata)

    if is_binary(browser.state_dir) do
      case ArtifactOutbox.put(
             browser.journal,
             browser.state_dir,
             attrs,
             content,
             max_bytes: browser.max_artifact_bytes
           ) do
        {:ok, manifest} -> {:ok, %{"artifact" => manifest}}
        {:error, :artifact_too_large} -> {:error, :artifact_too_large}
        {:error, _promotion_ambiguous} -> {:error, :action_outcome_unknown}
        _invalid -> {:error, :action_outcome_unknown}
      end
    else
      {:error, :artifact_unavailable}
    end
  end

  defp artifact_attrs(
         %{artifact_job_id: job_id, artifact_remote_execution_id: execution_id},
         _action,
         "screenshot",
         "image/png",
         _metadata
       )
       when is_binary(job_id) and is_binary(execution_id) do
    %{
      "artifact_id" =>
        GSMLG.BrowserAgent.WorkflowArtifacts.artifact_id(execution_id, "screenshot.png"),
      "job_id" => job_id,
      "kind" => "screenshot.png",
      "mime" => "image/png",
      "filename" => "report.png",
      "metadata" => %{"remote_execution_id" => execution_id}
    }
  end

  defp artifact_attrs(browser, action, kind, mime, artifact_metadata) do
    {wire_kind, extension} =
      if kind == "screenshot", do: {"screenshot.png", "png"}, else: {"download", "bin"}

    filename =
      Map.get(artifact_metadata, "suggested_filename", "#{action.action_id}.#{extension}")

    %{
      "artifact_id" =>
        GSMLG.BrowserAgent.WorkflowArtifacts.artifact_id(
          browser.central_session_id,
          "#{action.action_id}:#{wire_kind}"
        ),
      "session_id" => browser.central_session_id,
      "kind" => wire_kind,
      "mime" => mime,
      "filename" => filename,
      "metadata" =>
        artifact_metadata
        |> Map.delete("suggested_filename")
        |> Map.merge(%{
          "remote_session_id" => browser.session_id
        })
    }
  end

  defp authorize_artifact_source(browser, source_url) when is_binary(source_url) do
    OriginPolicy.authorize(browser.origin_policy, source_url, resolver_opts(browser))
  end

  defp authorize_artifact_source(_browser, _source_url), do: {:error, :navigation_not_allowed}

  defp safe_artifact_filename(value) when is_binary(value) and byte_size(value) <= 1_024 do
    if String.valid?(value) do
      filename =
        value
        |> String.split(["/", "\\"], trim: true)
        |> List.last()
        |> case do
          nil -> "download.bin"
          basename -> basename
        end
        |> String.replace(~r/[^A-Za-z0-9._ -]/u, "_")
        |> truncate_filename(128)

      if filename in ["", ".", ".."], do: {:ok, "download.bin"}, else: {:ok, filename}
    else
      {:error, :artifact_unavailable}
    end
  end

  defp safe_artifact_filename(_value), do: {:error, :artifact_unavailable}

  defp truncate_filename(value, max_bytes) do
    value
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn grapheme, {items, bytes} ->
      if bytes + byte_size(grapheme) <= max_bytes,
        do: {:cont, {[grapheme | items], bytes + byte_size(grapheme)}},
        else: {:halt, {items, bytes}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp persist_recovery(journal, key, entry) do
    case journal_put(journal, key, entry) do
      :ok -> {:cont, :ok}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp transition(entry, status), do: entry |> Map.put(:status, status) |> append_history(status)

  defp append_history(entry, status) do
    Map.update(entry, :history, [status], fn history ->
      history |> Kernel.++([status]) |> Enum.take(-@action_history_limit)
    end)
  end

  defp action_result_reservation(browser) do
    browser.max_observation_bytes * 2 + @action_result_overhead_bytes
  end

  defp action_key(browser, action), do: {browser.session_id, action.action_id}

  defp journal_get(journal, key), do: Journal.get(journal, :pending_action, key)

  defp journal_put(journal, key, entry), do: Journal.put(journal, :pending_action, key, entry)

  defp fingerprint(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp ok_only({:ok, _value}), do: :ok
  defp ok_only({:error, _reason} = error), do: error

  defp normalize_observation_error(:navigation_not_allowed), do: :navigation_not_allowed
  defp normalize_observation_error(:lease_conflict), do: :lease_conflict
  defp normalize_observation_error(:observation_too_large), do: :observation_too_large
  defp normalize_observation_error(:stale_observation), do: :stale_observation
  defp normalize_observation_error(:cdp_timeout), do: :cdp_timeout
  defp normalize_observation_error(_reason), do: :observation_failed

  defp normalize_action_error(reason)
       when reason in [
              :action_id_collision,
              :action_in_progress,
              :action_not_allowed,
              :action_outcome_unknown,
              :action_postcondition_failed,
              :action_target_not_found,
              :artifact_too_large,
              :journal_unavailable,
              :lease_conflict,
              :navigation_not_allowed,
              :stale_observation
            ],
       do: reason

  defp normalize_action_error(_reason), do: :action_failed
end
