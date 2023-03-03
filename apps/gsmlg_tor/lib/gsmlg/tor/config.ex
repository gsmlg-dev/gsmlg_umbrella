defmodule GSMLG.Tor.Config do
  @moduledoc """

  Documentation for `GSMLG.Tor.Config`.

  """

  require Logger
  alias GSMLG.Tor.Downloader

  def init() do
    etc_dir = Application.app_dir(:gsmlg_tor, "priv") <> "/etc"
    unless File.exists?(etc_dir), do: File.mkdir_p(etc_dir)
    File.write!(torrc_file(), torrc())
  end

  def torrc_file() do
    Application.app_dir(:gsmlg_tor, "priv") <> "/etc/torrc"
  end

  def torrc() do
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

  def command_path() do
    tor_cmd = Application.app_dir(:gsmlg_tor, "priv/tor/tor")

    unless File.exists?(tor_cmd) do
      Logger.info("cmd not exists, downloading...")

      case Downloader.download() do
        0 -> tor_cmd
        _ -> :error
      end
    else
      tor_cmd
    end
  end
end
