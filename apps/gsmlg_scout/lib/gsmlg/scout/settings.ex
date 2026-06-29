defmodule GSMLG.Scout.Settings do
  @moduledoc """
  Pure settings access for Scout core.
  """

  @default_allowed_schemes ["http", "https"]

  @default_settings %{
    "general" => %{
      "instance_name" => "Scout",
      "default_region" => "local",
      "request_timeout_ms" => 30_000
    },
    "rabbitmq" => %{
      "enabled" => false,
      "url" => "amqp://guest:guest@localhost:5672",
      "queues" => %{
        "jobs" => "scout.fetch.jobs",
        "results" => "scout.fetch.results",
        "failed" => "scout.fetch.failed",
        "heartbeat" => "scout.agent.heartbeat"
      },
      "regional_queues" => %{
        "eu" => "scout.fetch.jobs.eu",
        "us" => "scout.fetch.jobs.us",
        "asia" => "scout.fetch.jobs.asia"
      }
    },
    "fetch" => %{
      "default_timeout_ms" => 30_000,
      "max_timeout_ms" => 60_000,
      "max_page_size_bytes" => 5_000_000,
      "browser" => %{
        "wait_until" => "network_idle",
        "wait_for" => nil,
        "javascript" => true
      },
      "retry" => %{
        "max_attempts" => 3,
        "base_backoff_ms" => 500,
        "max_backoff_ms" => 5_000,
        "jitter" => true
      }
    },
    "agent" => %{
      "id" => nil,
      "region" => "local",
      "heartbeat_interval_ms" => 10_000,
      "capacity" => 16,
      "browser_instances" => 2,
      "page_concurrency" => 16,
      "lightpanda_path" => "lightpanda"
    },
    "security" => %{
      "allowed_schemes" => @default_allowed_schemes,
      "redirect_limit" => 5,
      "blocked_cidrs" => [
        "0.0.0.0/8",
        "127.0.0.0/8",
        "10.0.0.0/8",
        "100.64.0.0/10",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "192.0.0.0/24",
        "192.0.2.0/24",
        "192.31.196.0/24",
        "192.52.193.0/24",
        "192.88.99.0/24",
        "192.175.48.0/24",
        "198.18.0.0/15",
        "198.51.100.0/24",
        "203.0.113.0/24",
        "169.254.0.0/16",
        "224.0.0.0/4",
        "240.0.0.0/4",
        "255.255.255.255/32",
        "::/128",
        "::/96",
        "::1/128",
        "::ffff:0:0/96",
        "64:ff9b::/96",
        "64:ff9b:1::/48",
        "100::/64",
        "100:0:0:1::/64",
        "fe80::/10",
        "fc00::/7",
        "ff00::/8",
        "2001::/23",
        "2001::/32",
        "2001:1::1/128",
        "2001:1::2/128",
        "2001:1::3/128",
        "2001:2::/48",
        "2001:3::/32",
        "2001:4:112::/48",
        "2001:10::/28",
        "2001:20::/28",
        "2001:30::/28",
        "2001:db8::/32",
        "2002::/16",
        "2620:4f:8000::/48",
        "3fff::/20",
        "5f00::/16"
      ]
    }
  }

  @default_blocked_cidrs Map.fetch!(Map.fetch!(@default_settings, "security"), "blocked_cidrs")

  def get do
    :gsmlg_scout
    |> Application.get_env(:settings, %{})
    |> normalize()
  end

  def default_settings, do: @default_settings

  def normalize(raw) when is_map(raw) do
    raw
    |> deep_stringify_keys()
    |> then(&deep_merge(@default_settings, &1))
    |> enforce_allowed_schemes()
    |> enforce_blocked_cidrs()
    |> normalize_agent_id()
  end

  def normalize(_raw), do: raise(ArgumentError, "settings must contain a top-level map")

  defp normalize_agent_id(settings) do
    id =
      blank_to_nil(settings["agent"]["id"]) ||
        blank_to_nil(System.get_env("SCOUT_AGENT_ID")) ||
        "#{settings["agent"]["region"]}-agent-#{System.get_env("HOSTNAME") || "local"}"

    put_in(settings, ["agent", "id"], id)
  end

  defp enforce_allowed_schemes(settings) do
    configured =
      settings
      |> get_in(["security", "allowed_schemes"])
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.downcase/1)
      |> Enum.filter(&(&1 in @default_allowed_schemes))

    put_in(settings, ["security", "allowed_schemes"], configured)
  end

  defp enforce_blocked_cidrs(settings) do
    configured =
      settings
      |> get_in(["security", "blocked_cidrs"])
      |> List.wrap()
      |> Enum.map(&to_string/1)

    put_in(
      settings,
      ["security", "blocked_cidrs"],
      Enum.uniq(@default_blocked_cidrs ++ configured)
    )
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp blank_to_nil(value), do: value

  defp deep_stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} ->
      {to_string(key), deep_stringify_keys(nested_value)}
    end)
  end

  defp deep_stringify_keys(value) when is_list(value), do: Enum.map(value, &deep_stringify_keys/1)
  defp deep_stringify_keys(value), do: value

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge(left_value, right_value)
    end)
  end

  defp deep_merge(_left, right), do: right
end
