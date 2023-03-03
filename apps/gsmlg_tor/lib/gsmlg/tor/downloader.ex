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
    body =
      case System.fetch_env("HTTP_PROXY") do
        {:ok, proxy} ->
          Logger.debug("Download tor using proxy: #{proxy}")

          %HTTPoison.Response{status_code: 200, body: body} =
            download_url() |> HTTPoison.get!([], proxy: proxy, follow_redirect: true)

          body

        :error ->
          Logger.debug("Download tor")

          %HTTPoison.Response{status_code: 200, body: body} =
            download_url() |> HTTPoison.get!([], follow_redirect: true)

          body
      end

    p = Application.app_dir(:gsmlg_tor, "priv")
    f = p <> "/" <> filename()

    File.write!(f, body)

    {_, code} = System.cmd("tar", ["zxf", f, "-C", p])

    code
  end

  def download_url() do
    "https://dist.torproject.org/torbrowser/12.0/" <> filename()
  end

  def filename() do
    {os, arch} = os_arch()
    "tor-expert-bundle-12.0-#{os}-#{arch}.tar.gz"
  end

  def os_arch() do
    {arch, os_str} =
      case :erlang.system_info(:system_architecture) |> to_string() do
        "aarch64-" <> os_info ->
          {"aarch64", os_info}

        "x86_64-" <> os_info ->
          {"x86_64", os_info}

        _ ->
          IO.puts("unsupported")
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
