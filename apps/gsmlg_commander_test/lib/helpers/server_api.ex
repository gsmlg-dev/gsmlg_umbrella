defmodule GSMLG.CommanderTest.Helpers.ServerAPI do
  @moduledoc """
  HTTP helpers for interacting with the Commander server.

  Provides functions to call server APIs for:
  - Session management
  - PTY operations
  - Token management

  """

  @default_port 14000

  @doc """
  Get session information for an agent.

  ## Examples

      {:ok, session} = ServerAPI.get_session(agent_id)

  """
  @spec get_session(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_session(agent_id, opts \\ []) do
    port = Keyword.get(opts, :port, @default_port)
    url = ~c"http://localhost:#{port}/api/sessions/#{agent_id}"

    case http_get(url) do
      {:ok, body} ->
        {:ok, Jason.decode!(body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  List all active sessions.
  """
  @spec list_sessions(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_sessions(opts \\ []) do
    port = Keyword.get(opts, :port, @default_port)
    url = ~c"http://localhost:#{port}/api/sessions"

    case http_get(url) do
      {:ok, body} ->
        {:ok, Jason.decode!(body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Spawn a PTY session on an agent.

  ## Options

    * `:shell` - Shell to spawn (default: "/bin/bash")
    * `:rows` - Terminal rows (default: 24)
    * `:cols` - Terminal columns (default: 80)

  """
  @spec spawn_pty(String.t(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def spawn_pty(agent_id, pty_config \\ %{}, opts \\ []) do
    port = Keyword.get(opts, :port, @default_port)
    url = ~c"http://localhost:#{port}/api/sessions/#{agent_id}/pty"

    body =
      %{
        shell: Map.get(pty_config, :shell, "/bin/bash"),
        rows: Map.get(pty_config, :rows, 24),
        cols: Map.get(pty_config, :cols, 80)
      }
      |> Jason.encode!()

    case http_post(url, body) do
      {:ok, response_body} ->
        case Jason.decode(response_body) do
          {:ok, %{"pty_id" => pty_id}} -> {:ok, pty_id}
          {:ok, %{"error" => error}} -> {:error, error}
          {:error, _} -> {:error, :invalid_response}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Send input to a PTY session.
  """
  @spec send_pty_input(String.t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def send_pty_input(agent_id, pty_id, data, opts \\ []) do
    port = Keyword.get(opts, :port, @default_port)
    url = ~c"http://localhost:#{port}/api/sessions/#{agent_id}/pty/#{pty_id}/input"

    body = Jason.encode!(%{data: data})

    case http_post(url, body) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Resize a PTY session.
  """
  @spec resize_pty(String.t(), String.t(), integer(), integer(), keyword()) ::
          :ok | {:error, term()}
  def resize_pty(agent_id, pty_id, rows, cols, opts \\ []) do
    port = Keyword.get(opts, :port, @default_port)
    url = ~c"http://localhost:#{port}/api/sessions/#{agent_id}/pty/#{pty_id}/resize"

    body = Jason.encode!(%{rows: rows, cols: cols})

    case http_post(url, body) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Get PTY session status.
  """
  @spec get_pty_status(String.t(), String.t(), keyword()) :: {:ok, atom()} | {:error, term()}
  def get_pty_status(agent_id, pty_id, opts \\ []) do
    port = Keyword.get(opts, :port, @default_port)
    url = ~c"http://localhost:#{port}/api/sessions/#{agent_id}/pty/#{pty_id}"

    case http_get(url) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"status" => status}} -> {:ok, String.to_atom(status)}
          {:ok, _} -> {:error, :invalid_response}
          {:error, _} -> {:error, :invalid_response}
        end

      {:error, {:not_found, _}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Create a test token for agent authentication.

  ## Options

    * `:capabilities` - List of capabilities to grant
    * `:auto_tags` - Tags to automatically apply
    * `:expires_in` - Token expiration in seconds

  """
  @spec create_token(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def create_token(token_config \\ %{}, opts \\ []) do
    port = Keyword.get(opts, :port, @default_port)
    url = ~c"http://localhost:#{port}/api/tokens"

    body =
      %{
        capabilities: Map.get(token_config, :capabilities, [:shell, :files, :processes]),
        auto_tags: Map.get(token_config, :auto_tags, []),
        expires_in: Map.get(token_config, :expires_in, 3600)
      }
      |> Jason.encode!()

    case http_post(url, body) do
      {:ok, response_body} ->
        case Jason.decode(response_body) do
          {:ok, %{"token" => token}} -> {:ok, token}
          {:ok, %{"error" => error}} -> {:error, error}
          {:error, _} -> {:error, :invalid_response}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Revoke a token.
  """
  @spec revoke_token(String.t(), keyword()) :: :ok | {:error, term()}
  def revoke_token(token, opts \\ []) do
    port = Keyword.get(opts, :port, @default_port)
    url = ~c"http://localhost:#{port}/api/tokens/#{token}"

    case http_delete(url) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Private HTTP helpers

  defp http_get(url) do
    case :httpc.request(:get, {url, []}, [{:timeout, 5000}], []) do
      {:ok, {{_, 200, _}, _, body}} ->
        {:ok, to_string(body)}

      {:ok, {{_, 404, _}, _, body}} ->
        {:error, {:not_found, to_string(body)}}

      {:ok, {{_, status, _}, _, body}} ->
        {:error, {:http_error, status, to_string(body)}}

      {:error, reason} ->
        {:error, {:connection_failed, reason}}
    end
  end

  defp http_post(url, body) do
    headers = [{~c"content-type", ~c"application/json"}]

    case :httpc.request(:post, {url, headers, ~c"application/json", body}, [{:timeout, 5000}], []) do
      {:ok, {{_, status, _}, _, response_body}} when status in [200, 201] ->
        {:ok, to_string(response_body)}

      {:ok, {{_, 404, _}, _, response_body}} ->
        {:error, {:not_found, to_string(response_body)}}

      {:ok, {{_, status, _}, _, response_body}} ->
        {:error, {:http_error, status, to_string(response_body)}}

      {:error, reason} ->
        {:error, {:connection_failed, reason}}
    end
  end

  defp http_delete(url) do
    case :httpc.request(:delete, {url, []}, [{:timeout, 5000}], []) do
      {:ok, {{_, status, _}, _, body}} when status in [200, 204] ->
        {:ok, to_string(body)}

      {:ok, {{_, status, _}, _, body}} ->
        {:error, {:http_error, status, to_string(body)}}

      {:error, reason} ->
        {:error, {:connection_failed, reason}}
    end
  end
end
