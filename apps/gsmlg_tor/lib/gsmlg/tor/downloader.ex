defmodule GSMLG.Tor.Downloader do
  @moduledoc """

  Documentation for `GSMLG.Tor.Downloader`.

  """

  require Logger

  @doc """
  Download tor from website.

  https://www.torproject.org/download/tor/

  linux x86_64 is `https://www.torproject.org/dist/torbrowser/12.0/tor-expert-bundle-12.0-linux-x86_64.tar.gz`

  ## Examples

      iex> GSMLG.Tor.download()
      0

  """
  def download do
    body = fetch_archive!()

    p = Application.app_dir(:gsmlg_tor, "priv")
    f = p <> "/" <> filename()

    File.write!(f, body)

    {_, code} = System.cmd("tar", ["zxf", f, "-C", p])

    code
  end

  @doc """
  Return url for download.

  `https://dist.torproject.org/torbrowser/12.0/tor-expert-bundle-12.0-{os}-{arch}.tar.gz`

  """
  def download_url() do
    "https://dist.torproject.org/torbrowser/12.0/" <> filename()
  end

  defp fetch_archive! do
    log_download()

    case download_url()
         |> fetch(method: :get, redirect: :follow)
         |> await_http_response() do
      {:ok, %HTTP.Response{status: 200} = response} ->
        HTTP.Response.read_all(response)

      {:ok, %HTTP.Response{status: status}} ->
        raise "failed to download tor archive: HTTP #{status}"

      {:error, reason} ->
        raise "failed to download tor archive: #{inspect(reason)}"
    end
  end

  defp log_download do
    case System.fetch_env("HTTP_PROXY") do
      {:ok, proxy} ->
        Logger.warning(
          "Download tor directly; HTTP_PROXY is set but unsupported by http_fetch",
          proxy: proxy
        )

      :error ->
        Logger.debug("Download tor")
    end
  end

  defp fetch(url, options) do
    client = Application.get_env(:gsmlg_tor, :http_client, HTTP)

    case ensure_http_client_started(client) do
      :ok -> client.fetch(url, options)
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_http_client_started(HTTP) do
    case Application.ensure_all_started(:http_fetch) do
      {:ok, _apps} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_http_client_started(_client), do: :ok

  defp await_http_response(%HTTP.Promise{} = promise) do
    case HTTP.Promise.await(promise) do
      %HTTP.Response{} = response -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp await_http_response({:ok, %HTTP.Response{}} = result), do: result
  defp await_http_response({:error, _reason} = error), do: error

  defp filename() do
    {os, arch} = os_arch()
    "tor-expert-bundle-12.0-#{os}-#{arch}.tar.gz"
  end

  defp os_arch() do
    {arch, os_str} =
      case :erlang.system_info(:system_architecture) |> to_string() do
        "aarch64-" <> os_info ->
          {"aarch64", os_info}

        "x86_64-" <> os_info ->
          {"x86_64", os_info}

        _ ->
          Logger.error("unsupported")
          :error
      end

    {ostype} =
      cond do
        String.contains?(os_str, "darwin") -> {"macos"}
        String.contains?(os_str, "linux") -> {"linux"}
        true -> :error
      end

    {ostype, arch}
  end
end
