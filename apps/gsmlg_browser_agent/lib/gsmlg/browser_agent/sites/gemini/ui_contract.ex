defmodule GSMLG.BrowserAgent.Sites.Gemini.UIContract do
  @moduledoc "Versioned, semantic Gemini page recognition independent of workflow state."

  @id "gemini.ui/v1"
  @known_testids [
    {"gemini-login", :login_required},
    {"gemini-reauth", :reauth_required},
    {"gemini-passkey", :passkey_required},
    {"gemini-two-factor", :two_factor_required},
    {"gemini-captcha", :captcha_required},
    {"gemini-account-warning", :account_warning},
    {"gemini-quota", :quota},
    {"gemini-error", :error},
    {"gemini-video-unavailable", :video_unavailable},
    {"gemini-video-age-restricted", :age_restricted},
    {"gemini-video-region-restricted", :region_restricted},
    {"gemini-video-inaccessible", :video_inaccessible},
    {"gemini-video-title-only", :title_only},
    {"gemini-researching", :researching},
    {"gemini-generating", :researching},
    {"gemini-report", :report},
    {"gemini-plan", :plan},
    {"gemini-prompt", :chat}
  ]

  @selector_candidates %{
    prompt: [
      %{"role" => "textbox", "accessible_name" => "Enter a prompt"},
      %{"attribute" => %{"name" => "type", "value" => "text"}},
      %{"placeholder" => "Enter a prompt"},
      %{"label" => "Prompt"}
    ],
    submit: [
      %{"role" => "button", "accessible_name" => "Send message"},
      %{"label" => "Send"}
    ],
    deep_research: [
      %{"role" => "button", "accessible_name" => "Deep Research"},
      %{"text" => "Deep Research"}
    ],
    plan_approve: [
      %{"role" => "button", "accessible_name" => "Start research"},
      %{"text" => "Start research"}
    ],
    report: [
      %{"role" => "article", "accessible_name" => "Final report"},
      %{"text" => "Final report"}
    ]
  }

  @css_fallbacks %{
    prompt: "[data-testid='gemini-prompt']",
    submit: "[data-testid='gemini-submit']",
    deep_research: "[data-testid='gemini-deep-research']",
    plan_approve: "[data-testid='gemini-plan-approve']",
    report: "[data-testid='gemini-report']"
  }

  def id, do: @id

  def selectors do
    Map.new(@selector_candidates, fn {name, [primary | _rest]} -> {name, primary} end)
  end

  def selector_candidates(name, opts \\ []) do
    candidates = Map.get(@selector_candidates, name, [])

    if Keyword.get(opts, :allow_css, false) and is_map_key(@css_fallbacks, name),
      do: candidates ++ [%{"css" => Map.fetch!(@css_fallbacks, name)}],
      else: candidates
  end

  def recognize(observation) when is_map(observation) do
    with true <- valid_observation?(observation),
         nodes when is_list(nodes) <- observation["semantic_tree"] do
      kind = recognize_kind(nodes, observation["alerts"])
      {:ok, snapshot(kind, nodes)}
    else
      _invalid -> {:error, :ui_contract_invalid_observation}
    end
  end

  def recognize(_observation), do: {:error, :ui_contract_invalid_observation}

  def canonical_hash(text) when is_binary(text) do
    text
    |> String.normalize(:nfc)
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.join(" ")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp valid_observation?(observation) do
    Map.keys(observation) --
      ~w(session_id lease_id revision url origin title loading_state page_kind alerts visible_controls semantic_tree focused_element observed_at expires_at) ==
      [] and
      is_binary(observation["url"]) and is_list(observation["alerts"]) and
      is_list(observation["semantic_tree"])
  end

  defp recognize_kind(nodes, alerts) do
    primary_aria_kind(nodes) || stable_attribute_kind(nodes) || structural_kind(nodes) ||
      localized_alias_kind(nodes) || alert_kind(alerts) || :unknown
  end

  defp primary_aria_kind(nodes) do
    Enum.find_value(nodes, fn node ->
      case {node["role"], normalize_name(node["name"])} do
        {"textbox", "enter a prompt"} -> :chat
        {"textbox", "ask gemini"} -> :chat
        {"heading", "sign in"} -> :login_required
        {"article", "research plan"} -> :plan
        {"article", "final report"} -> :report
        {"status", name} when name in ["researching", "generating"] -> :researching
        _other -> nil
      end
    end)
  end

  defp stable_attribute_kind(nodes) do
    ids = Enum.map(nodes, &get_in(&1, ["attributes", "data-testid"]))
    Enum.find_value(@known_testids, fn {testid, kind} -> if testid in ids, do: kind end)
  end

  defp structural_kind(nodes) do
    cond do
      Enum.any?(nodes, &report_node?/1) and Enum.any?(nodes, &(&1["role"] == "heading")) ->
        :report

      Enum.any?(nodes, &plan_node?/1) ->
        :plan

      true ->
        nil
    end
  end

  defp localized_alias_kind(nodes) do
    Enum.find_value(nodes, fn node ->
      name = normalize_name(node["name"])

      cond do
        node["role"] == "textbox" and name in ["输入提示", "introduce una petición"] -> :chat
        node["role"] == "heading" and name in ["登录", "iniciar sesión"] -> :login_required
        true -> nil
      end
    end)
  end

  defp alert_kind(alerts) do
    text = alerts |> Enum.filter(&is_binary/1) |> Enum.join(" ") |> String.downcase()

    cond do
      String.contains?(text, "quota") or String.contains?(text, "limit") -> :quota
      String.contains?(text, "error") or String.contains?(text, "failed") -> :error
      true -> nil
    end
  end

  defp snapshot(:chat, nodes) do
    %{
      kind: :chat,
      prompt_ready?:
        semantic?(nodes, "textbox", ["enter a prompt", "ask gemini"]) or
          testid?(nodes, "gemini-prompt"),
      deep_research_available?:
        semantic?(nodes, "button", ["deep research"]) or
          testid?(nodes, "gemini-deep-research"),
      submit_available?:
        semantic?(nodes, "button", ["send message", "send"]) or
          testid?(nodes, "gemini-submit")
    }
  end

  defp snapshot(:plan, nodes) do
    %{
      kind: :plan,
      approve_available?:
        semantic?(nodes, "button", ["start research"]) or
          testid?(nodes, "gemini-plan-approve"),
      plan_text: text_for(nodes, "gemini-plan", &plan_node?/1)
    }
  end

  defp snapshot(:researching, nodes) do
    %{
      kind: :researching,
      generating?:
        testid?(nodes, "gemini-generating") or semantic?(nodes, "status", ["generating"])
    }
  end

  defp snapshot(:report, nodes) do
    markdown = report_text(nodes)
    sections = section_names(nodes)

    %{
      kind: :report,
      complete?: markdown != "",
      generating?: testid?(nodes, "gemini-researching") or testid?(nodes, "gemini-generating"),
      markdown: markdown,
      html: render_html(markdown),
      structured: %{"sections" => sections},
      sections: sections,
      sources: source_entries(nodes),
      canonical_hash: canonical_hash(markdown)
    }
  end

  defp snapshot(kind, _nodes), do: %{kind: kind}

  defp semantic?(nodes, role, names) do
    Enum.any?(nodes, fn node -> node["role"] == role and normalize_name(node["name"]) in names end)
  end

  defp testid?(nodes, testid),
    do: Enum.any?(nodes, &(get_in(&1, ["attributes", "data-testid"]) == testid))

  defp text_for(nodes, testid, structural_match) do
    nodes
    |> Enum.filter(fn node ->
      get_in(node, ["attributes", "data-testid"]) == testid or structural_match.(node)
    end)
    |> Enum.flat_map(fn node -> Enum.filter([node["name"], node["value"]], &is_binary/1) end)
    |> Enum.uniq()
    |> Enum.join("\n")
  end

  defp report_text(nodes), do: text_for(nodes, "gemini-report", &report_node?/1)

  defp section_names(nodes) do
    nodes
    |> Enum.filter(fn node ->
      get_in(node, ["attributes", "data-testid"]) == "gemini-report-section" or
        node["role"] == "heading"
    end)
    |> Enum.map(& &1["name"])
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp source_entries(nodes) do
    nodes
    |> Enum.filter(fn node ->
      get_in(node, ["attributes", "data-testid"]) == "gemini-source" or node["role"] == "link"
    end)
    |> Enum.flat_map(fn node ->
      case safe_source_url(get_in(node, ["attributes", "href"])) do
        {:ok, url} -> [%{"title" => node["name"] || "Source", "url" => url}]
        :error -> []
      end
    end)
    |> Enum.uniq()
  end

  defp safe_source_url(url) when is_binary(url) and byte_size(url) in 1..2_048 do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) and host != "" ->
        {:ok, url}

      _unsafe ->
        :error
    end
  end

  defp safe_source_url(_url), do: :error

  defp report_node?(node),
    do: node["role"] == "article" and contains?(node["name"], "final report")

  defp plan_node?(node),
    do: node["role"] == "article" and contains?(node["name"], "research plan")

  defp contains?(value, text) when is_binary(value),
    do: String.contains?(String.downcase(value), text)

  defp contains?(_value, _text), do: false

  defp normalize_name(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_name(_value), do: ""

  defp render_html(markdown) do
    escaped =
      markdown
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")
      |> String.replace("\"", "&quot;")
      |> String.replace("'", "&#39;")

    "<pre>#{escaped}</pre>"
  end
end
