defmodule GSMLG.Scout.Agent.Lightpanda.CLI do
  @moduledoc """
  Lightpanda CLI adapter using native Markdown output.
  """

  @behaviour GSMLG.Scout.Agent.Lightpanda

  alias GSMLG.Scout.Markdown

  @impl true
  def fetch(url, opts) do
    executable = opts["lightpanda_path"] || opts[:lightpanda_path] || "lightpanda"
    timeout_ms = opts["timeout_ms"] || opts[:timeout_ms] || 30_000

    with {:ok, path} <- executable_path(executable) do
      run(path, build_args(url, opts), timeout_ms)
    end
  end

  defp executable_path(executable) do
    cond do
      Path.type(executable) == :absolute and File.exists?(executable) ->
        {:ok, executable}

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
