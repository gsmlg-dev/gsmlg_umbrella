defmodule GSMLG.ProxyRules.ZeroOmega.Export do
  @moduledoc """
  Pure normalize, format-validation, render, and metadata pipeline.
  """

  alias GSMLG.ProxyRules.ZeroOmega.{
    Diagnostic,
    Normalizer,
    PAC,
    Policy,
    RenderedRuleList,
    Switchy
  }

  @switchy_content_type "text/plain; charset=utf-8"
  @pac_content_type "application/x-ns-proxy-autoconfig; charset=utf-8"

  @type validated ::
          {:validated, Policy.t(), RenderedRuleList.format(), binary(), binary()}

  @spec normalize(Policy.t()) :: {:ok, Policy.t()} | {:error, [Diagnostic.t()]}
  def normalize(policy), do: Normalizer.normalize_policy(policy)

  @spec validate_for(
          {:ok, Policy.t()} | {:error, [Diagnostic.t()]},
          RenderedRuleList.format(),
          keyword()
        ) :: {:ok, validated()} | {:error, [Diagnostic.t()]}
  def validate_for(result, format, options)

  def validate_for({:ok, %Policy{} = policy}, :switchy, options) do
    case Switchy.render(policy, options) do
      {:ok, body} ->
        {:ok, {:validated, policy, :switchy, body, @switchy_content_type}}

      {:error, diagnostics} ->
        {:error, diagnostics}
    end
  end

  def validate_for({:ok, %Policy{} = policy}, :pac, options) do
    case PAC.render(policy, options) do
      {:ok, body} ->
        {:ok, {:validated, policy, :pac, body, @pac_content_type}}

      {:error, diagnostics} ->
        {:error, diagnostics}
    end
  end

  def validate_for({:ok, %Policy{}}, _format, _options) do
    {:error, [Diagnostic.error(:unsupported_condition, "Export format is not supported")]}
  end

  def validate_for({:error, diagnostics}, _format, _options), do: {:error, diagnostics}

  def validate_for(_result, _format, _options) do
    {:error, [Diagnostic.error(:invalid_rule, "Export validation input is invalid")]}
  end

  @spec render({:ok, validated()} | {:error, [Diagnostic.t()]}) ::
          {:ok, RenderedRuleList.t()} | {:error, [Diagnostic.t()]}
  def render({:ok, {:validated, policy, format, body, content_type}}) do
    {:ok, RenderedRuleList.new(body, content_type, format, policy.revision)}
  end

  def render({:error, diagnostics}), do: {:error, diagnostics}

  def render(_result) do
    {:error, [Diagnostic.error(:invalid_rule, "Export rendering input is invalid")]}
  end
end
