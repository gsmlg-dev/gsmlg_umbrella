defmodule GSMLG.Scout.Agent.Lightpanda.CLI do
  @moduledoc """
  Lightpanda CLI adapter using native Markdown output.
  """

  @behaviour GSMLG.Scout.Agent.Lightpanda

  alias GSMLG.Scout.Agent.RedirectGuard
  alias GSMLG.Scout.Markdown
  alias GSMLG.Scout.Settings

  @impl true
  def fetch(url, opts) do
    executable = opts["lightpanda_path"] || opts[:lightpanda_path] || "lightpanda"
    timeout_ms = opts["timeout_ms"] || opts[:timeout_ms] || 30_000
    deadline = deadline(timeout_ms)

    with {:ok, path} <- executable_path(executable),
         :ok <- ensure_task_supervisor(),
         {:ok, page} <- RedirectGuard.fetch(url, Settings.get(), timeout_ms),
         {:ok, local_page} <- serve_local_page(page) do
      try do
        with {:ok, render_timeout} <- remaining_timeout(deadline),
             {:ok, payload} <- run(path, build_args(local_page.url, opts), render_timeout) do
          {:ok,
           payload
           |> Map.put(:final_url, page.final_url)
           |> Map.put(:status_code, page.status_code)}
        end
      after
        stop_local_page(local_page)
      end
    end
  end

  defp ensure_task_supervisor do
    if Process.whereis(GSMLG.Scout.Agent.TaskSupervisor) do
      :ok
    else
      {:error,
       %{
         type: "agent_not_started",
         message: "Scout agent task supervisor is not running",
         retryable: true
       }}
    end
  end

  defp executable_path(executable) do
    cond do
      Path.type(executable) == :absolute and File.exists?(executable) ->
        {:ok, executable}

      path = relative_executable_path(executable) ->
        {:ok, path}

      path = System.find_executable(executable) ->
        {:ok, path}

      true ->
        {:error,
         %{
           type: "browser_unavailable",
           message: "Lightpanda executable was not found: #{executable}",
           retryable: true
         }}
    end
  end

  defp relative_executable_path(executable) do
    if Path.type(executable) == :relative and executable != Path.basename(executable) do
      path = Path.expand(executable)
      if File.exists?(path), do: path
    end
  end

  defp run(path, args, timeout_ms) do
    if Process.whereis(GSMLG.Scout.Agent.TaskSupervisor) do
      task =
        Task.Supervisor.async_nolink(GSMLG.Scout.Agent.TaskSupervisor, fn ->
          System.cmd(path, args, stderr_to_stdout: true)
        end)

      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {output, 0}} ->
          {:ok,
           %{
             markdown: output,
             title: Markdown.title(output),
             status_code: nil
           }}

        {:ok, {output, status}} ->
          {:error,
           %{
             type: "command_failed",
             message: "Lightpanda exited with status #{status}: #{String.trim(output)}",
             retryable: status in [124, 125, 126, 127]
           }}

        {:exit, reason} ->
          {:error,
           %{
             type: "browser_crash",
             message: inspect(reason),
             retryable: true
           }}

        nil ->
          {:error,
           %{
             type: "timeout",
             message: "Fetch timed out after #{timeout_ms}ms",
             retryable: true
           }}
      end
    else
      {:error,
       %{
         type: "agent_not_started",
         message: "Scout agent task supervisor is not running",
         retryable: true
       }}
    end
  rescue
    error ->
      {:error,
       %{
         type: "browser_crash",
         message: Exception.message(error),
         retryable: true
       }}
  end

  defp serve_local_page(page) do
    body = local_body(page)

    with {:ok, listen_socket} <-
           :gen_tcp.listen(0, [
             :binary,
             packet: :raw,
             active: false,
             reuseaddr: true,
             ip: {127, 0, 0, 1}
           ]),
         {:ok, port} <- :inet.port(listen_socket) do
      task =
        Task.Supervisor.async_nolink(GSMLG.Scout.Agent.TaskSupervisor, fn ->
          serve_once(listen_socket, body)
        end)

      {:ok, %{url: "http://127.0.0.1:#{port}/", listen_socket: listen_socket, task: task}}
    end
  end

  defp stop_local_page(%{listen_socket: listen_socket, task: task}) do
    :gen_tcp.close(listen_socket)
    Task.shutdown(task, 1_000)
    :ok
  end

  defp serve_once(listen_socket, body) do
    with {:ok, socket} <- :gen_tcp.accept(listen_socket, 30_000) do
      :gen_tcp.recv(socket, 0, 5_000)

      response = [
        "HTTP/1.1 200 OK\r\n",
        "content-type: text/plain; charset=utf-8\r\n",
        "content-security-policy: default-src 'none'; navigate-to 'none'; form-action 'none'; base-uri 'none'\r\n",
        "x-content-type-options: nosniff\r\n",
        "content-length: ",
        Integer.to_string(byte_size(body)),
        "\r\n",
        "connection: close\r\n\r\n",
        body
      ]

      :gen_tcp.send(socket, response)
      :gen_tcp.close(socket)
    end
  after
    :gen_tcp.close(listen_socket)
  end

  defp local_body(%{body: body, content_type: content_type}) do
    if html_content_type?(content_type) do
      body
      |> to_string()
      |> html_to_text()
    else
      to_string(body)
    end
  end

  defp html_content_type?(content_type) when is_binary(content_type) do
    content_type
    |> String.downcase()
    |> String.contains?("html")
  end

  defp html_content_type?(_content_type), do: true

  defp html_to_text(html) do
    html
    |> then(
      &Regex.replace(
        ~r/<(script|style|iframe|object|embed|video|audio)\b[^>]*>.*?<\/\1>/is,
        &1,
        " "
      )
    )
    |> then(&Regex.replace(~r/<br\s*\/?>/i, &1, "\n"))
    |> then(&Regex.replace(~r/<\/(p|div|section|article|header|footer|li|h[1-6])>/i, &1, "\n"))
    |> then(&Regex.replace(~r/<[^>]+>/, &1, " "))
    |> decode_entities()
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/\n\s+\n/, "\n\n")
    |> String.trim()
  end

  defp decode_entities(text) do
    text
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
  end

  defp deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms

  defp remaining_timeout(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      {:ok, remaining}
    else
      {:error, %{type: "timeout", message: "fetch timed out", retryable: true}}
    end
  end

  defp build_args(url, opts) do
    ["fetch", "--dump", "markdown"]
    |> Kernel.++(wait_until_args(opts["wait_until"] || opts[:wait_until]))
    |> Kernel.++(wait_for_args(opts["wait_for"] || opts[:wait_for]))
    |> Kernel.++([url])
  end

  defp wait_until_args(nil), do: []
  defp wait_until_args(""), do: []
  defp wait_until_args("network_idle"), do: ["--wait-until", "networkidle"]
  defp wait_until_args(value), do: ["--wait-until", to_string(value)]

  defp wait_for_args(nil), do: []
  defp wait_for_args(""), do: []
  defp wait_for_args(selector), do: ["--wait-selector", to_string(selector)]
end
