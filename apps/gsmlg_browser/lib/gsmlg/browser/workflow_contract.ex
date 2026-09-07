defmodule GSMLG.Browser.WorkflowContract do
  @moduledoc false

  @workflows %{
    {"gemini.deep_research", 1} => %{
      required: ~w(prompt output_locale research_scope required_sections auto_approve_plan),
      optional: []
    },
    {"gemini.youtube_analysis", 1} => %{
      required:
        ~w(youtube_url analysis_profile output_locale custom_instructions use_deep_research),
      optional: []
    }
  }
  @required_output_formats ~w(report.markdown report.json sources.json)
  @output_formats @required_output_formats ++ ~w(report.html screenshot.png)
  @analysis_profiles ~w(summary technical_review timeline fact_check action_items)

  def validate(workflow, version, input, output_formats) do
    with %{required: required, optional: optional} <- @workflows[{workflow, version}],
         true <- is_map(input) and string_keys?(input),
         true <-
           Enum.sort(Map.keys(input)) ==
             Enum.sort(required ++ Enum.filter(optional, &Map.has_key?(input, &1))),
         true <- valid_input(workflow, input),
         true <- is_list(output_formats) and Enum.uniq(output_formats) == output_formats,
         true <- Enum.all?(output_formats, &(&1 in @output_formats)),
         true <- Enum.all?(@required_output_formats, &(&1 in output_formats)) do
      :ok
    else
      nil -> {:error, :unsupported_workflow}
      _invalid -> {:error, :invalid_workflow_input}
    end
  end

  def full_id(workflow, version), do: "#{workflow}/v#{version}"

  defp valid_input("gemini.deep_research", input) do
    bounded_string?(input["prompt"], 65_536) and
      locale?(input["output_locale"]) and
      bounded_string?(input["research_scope"], 1_024) and
      valid_sections?(input["required_sections"]) and
      is_boolean(input["auto_approve_plan"])
  end

  defp valid_input("gemini.youtube_analysis", input) do
    youtube_url?(input["youtube_url"]) and input["analysis_profile"] in @analysis_profiles and
      locale?(input["output_locale"]) and
      is_binary(input["custom_instructions"]) and
      byte_size(input["custom_instructions"]) <= 8_192 and
      is_boolean(input["use_deep_research"])
  end

  defp valid_sections?(sections) when is_list(sections) and length(sections) in 1..32,
    do: sections == Enum.uniq(sections) and Enum.all?(sections, &bounded_string?(&1, 128))

  defp valid_sections?(_sections), do: false

  defp youtube_url?(url) do
    with true <- bounded_string?(url, 2_048),
         true <- youtube_video_id?(URI.parse(url)) do
      true
    else
      _invalid -> false
    end
  rescue
    _exception -> false
  end

  defp youtube_video_id?(%URI{
         scheme: "https",
         host: host,
         port: port,
         path: "/watch",
         userinfo: nil,
         fragment: nil,
         query: query
       })
       when host in ["youtube.com", "www.youtube.com"] and port in [nil, 443] do
    query
    |> decode_query()
    |> Map.get("v")
    |> valid_video_id?()
  end

  defp youtube_video_id?(%URI{
         scheme: "https",
         host: "youtu.be",
         port: port,
         path: "/" <> video_id,
         userinfo: nil,
         fragment: nil
       })
       when port in [nil, 443],
       do: not String.contains?(video_id, "/") and valid_video_id?(video_id)

  defp youtube_video_id?(_uri), do: false

  defp decode_query(nil), do: %{}

  defp decode_query(query) do
    URI.decode_query(query)
  rescue
    _exception -> %{}
  end

  defp valid_video_id?(video_id),
    do:
      is_binary(video_id) and byte_size(video_id) in 6..64 and
        Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, video_id)

  defp locale?(value),
    do:
      bounded_string?(value, 32) and
        Regex.match?(~r/\A[a-zA-Z]{2,3}(?:-[a-zA-Z0-9]{2,8})*\z/, value)

  defp string_keys?(map), do: Enum.all?(Map.keys(map), &is_binary/1)
  defp bounded_string?(value, max), do: is_binary(value) and byte_size(value) in 1..max
end
