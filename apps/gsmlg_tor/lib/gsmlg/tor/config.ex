defmodule GSMLG.Tor.Config do
  @moduledoc """

  Documentation for `GSMLG.Tor.Config`.

  """

  require Logger
  alias GSMLG.Tor.Downloader

  @doc """
  Create config directory and write config file.
  """
  def init() do
    etc_dir = Application.app_dir(:gsmlg_tor, "priv") <> "/etc"
    unless File.exists?(etc_dir), do: File.mkdir_p(etc_dir)
    File.write!(torrc_file(), torrc())
  end

  @doc """
  Return `torrc` file path at `priv/etc/torrc`
  """
  def torrc_file() do
    Application.app_dir(:gsmlg_tor, "priv") <> "/etc/torrc"
  end

  @doc """
  Return torrc file content

  ### `torrc` lookup diagram

  1. At first, read from `Application.get_env(:gsmlg_tor, GSMLG.Tor.Config) |> Keyword.fetch(:conf_path)` if set.
  2. Second, use `Application.get_env(:gsmlg_tor, GSMLG.Tor.Config) |> Keyword.get(:conf)` if not nil.
  3. At last, use default setting as below:
  ```torrc
  SOCKSPort 127.0.0.1:9050 # localhost IPv4
  SOCKSPort [::1]:9050     # localhost IPv6

  SOCKSPolicy accept 127.0.0.1/8
  SOCKSPolicy accept ::1/128

  SOCKSPolicy reject *
  SOCKSPolicy reject6 *


  Scheduler KISTLite,Vanilla

  DataDirectory {Application.app_dir(:gsmlg_tor, "priv")}/data

  FascistFirewall 0


  ## Client Authentication

  HardwareAccel 1
  ```

  """
  def torrc() do
    case Application.get_env(:gsmlg_tor, GSMLG.Tor.Config) |> Keyword.fetch(:conf_path) do
      {:ok, conf_path} when is_binary(conf_path) ->
        Logger.debug("using config file setted in application env: #{conf_path}")
        File.read!(conf_path)

      _ ->
        conf = Application.get_env(:gsmlg_tor, GSMLG.Tor.Config) |> Keyword.get(:conf)

        if is_nil(conf) do
          default_torrc()
        else
          conf
        end
    end
  end

  @doc """
  Get tor command path

  ### `tor` command path lookup diagram

  1. Use config in `Application.get_env(:gsmlg_tor, GSMLG.Tor.Config) |> Keyword.fetch(:bin_path)`
  2. Use `Application.app_dir(:gsmlg_tor, "priv/tor/tor")` if file exists
  3. At last, download by `Downloader.download()` throught internet

  """
  def command_path() do
    case Application.get_env(:gsmlg_tor, GSMLG.Tor.Config) |> Keyword.fetch(:bin_path) do
      {:ok, bin_path} when is_binary(bin_path) ->
        Logger.debug("using bin_path setted in application env: #{bin_path}")
        bin_path

      _ ->
        bin_path = Application.app_dir(:gsmlg_tor, "priv/tor/tor")

        unless File.exists?(bin_path) do
          Logger.info("cmd not exists, downloading...")

          case Downloader.download() do
            0 -> bin_path
            _ -> :error
          end
        else
          bin_path
        end
    end
  end

  defp default_torrc() do
    """

    SOCKSPort 127.0.0.1:9050 # localhost IPv4
    SOCKSPort [::1]:9050     # localhost IPv6

    SOCKSPolicy accept 127.0.0.1/8
    SOCKSPolicy accept ::1/128

    SOCKSPolicy reject *
    SOCKSPolicy reject6 *


    Scheduler KISTLite,Vanilla

    DataDirectory #{Application.app_dir(:gsmlg_tor, "priv")}/data

    FascistFirewall 0


    ## Client Authentication

    HardwareAccel 1

    """
  end
end
