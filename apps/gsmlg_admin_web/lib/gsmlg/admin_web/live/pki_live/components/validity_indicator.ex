defmodule GSMLG.AdminWeb.PKILive.Components.ValidityIndicator do
  @moduledoc """
  Component for displaying certificate validity with visual indicators.
  """
  use GSMLG.AdminWeb, :html

  attr :not_after, :any, required: true
  attr :not_before, :any, default: nil
  attr :class, :string, default: ""

  def validity_indicator(assigns) do
    now = DateTime.utc_now()
    days_remaining = DateTime.diff(assigns.not_after, now, :day)

    assigns =
      assigns
      |> assign(:days_remaining, days_remaining)
      |> assign(:alert_level, get_alert_level(days_remaining))
      |> assign(:now, now)

    ~H"""
    <div class={["flex items-center gap-2", @class]}>
      <div class={["w-3 h-3 rounded-full", alert_color(@alert_level)]}></div>
      <span class={text_color(@alert_level)}>
        <%= if @days_remaining > 0 do %>
          Expires in {@days_remaining} days
        <% else %>
          Expired {abs(@days_remaining)} days ago
        <% end %>
      </span>
    </div>
    """
  end

  defp get_alert_level(days) when days < 0, do: :critical
  defp get_alert_level(days) when days <= 7, do: :critical
  defp get_alert_level(days) when days <= 30, do: :warning
  defp get_alert_level(_), do: :normal

  defp alert_color(:critical), do: "bg-red-500"
  defp alert_color(:warning), do: "bg-yellow-500"
  defp alert_color(:normal), do: "bg-green-500"

  defp text_color(:critical), do: "text-red-600 font-semibold"
  defp text_color(:warning), do: "text-yellow-600"
  defp text_color(:normal), do: "text-gray-600"
end
