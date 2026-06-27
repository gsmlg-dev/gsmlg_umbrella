defmodule GSMLG.Scout.Fetch.Job do
  @moduledoc """
  Fetch job payload accepted by Scout Server and Scout Agent.
  """

  alias GSMLG.Scout.Security
  alias GSMLG.Scout.Settings

  defstruct [
    :job_id,
    :url,
    timeout_ms: 30_000,
    priority: 5,
    region_hint: nil,
    browser: %{},
    attempt: 1,
    max_attempts: 3
  ]

  def new(params, settings \\ Settings.get()) when is_map(params) do
    url = params |> value("url") |> to_string_safe() |> String.trim()

    with :ok <- require_url(url),
         :ok <- Security.validate_url(url, settings) do
      fetch = settings["fetch"]
      retry = fetch["retry"]

      browser =
        fetch["browser"]
        |> Map.merge(normalize_browser(value(params, "browser")))

      {:ok,
       %__MODULE__{
         job_id: value(params, "job_id") || generate_job_id(),
         url: url,
         timeout_ms:
           normalize_integer(
             value(params, "timeout_ms"),
             fetch["default_timeout_ms"],
             1,
             fetch["max_timeout_ms"]
           ),
         priority: normalize_integer(value(params, "priority"), 5, 0, 10),
         region_hint: blank_to_nil(value(params, "region_hint")),
         browser: browser,
         attempt: normalize_integer(value(params, "attempt"), 1, 1, retry["max_attempts"]),
         max_attempts: retry["max_attempts"]
       }}
    end
  end

  def from_map(params, settings \\ Settings.get()), do: new(params, settings)

  def to_map(%__MODULE__{} = job) do
    %{
      job_id: job.job_id,
      url: job.url,
      timeout_ms: job.timeout_ms,
      priority: job.priority,
      region_hint: job.region_hint,
      browser: job.browser,
      attempt: job.attempt,
      max_attempts: job.max_attempts
    }
  end

  def retry(%__MODULE__{} = job), do: %{job | attempt: job.attempt + 1}

  def error(type, message, retryable) do
    {:error, %{type: to_string(type), message: message, retryable: retryable}}
  end

  defp require_url(""), do: error(:invalid_url, "url is required", false)
  defp require_url(_url), do: :ok

  defp normalize_browser(browser) when is_map(browser) do
    Map.new(browser, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_browser(_browser), do: %{}

  defp normalize_integer(nil, default, _min, _max), do: default
  defp normalize_integer("", default, _min, _max), do: default

  defp normalize_integer(value, default, min, max) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> normalize_integer(integer, default, min, max)
      _ -> default
    end
  end

  defp normalize_integer(value, _default, min, max) when is_integer(value) do
    value
    |> Kernel.max(min)
    |> Kernel.min(max)
  end

  defp normalize_integer(_value, default, _min, _max), do: default

  defp value(map, key), do: Map.get(map, key) || Map.get(map, atom_key(key))

  defp atom_key("attempt"), do: :attempt
  defp atom_key("browser"), do: :browser
  defp atom_key("job_id"), do: :job_id
  defp atom_key("priority"), do: :priority
  defp atom_key("region_hint"), do: :region_hint
  defp atom_key("timeout_ms"), do: :timeout_ms
  defp atom_key("url"), do: :url

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: to_string(value)

  defp to_string_safe(nil), do: ""
  defp to_string_safe(value), do: to_string(value)

  defp generate_job_id do
    encoded = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    <<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>> = encoded
    "#{a}-#{b}-#{c}-#{d}-#{e}"
  end
end
