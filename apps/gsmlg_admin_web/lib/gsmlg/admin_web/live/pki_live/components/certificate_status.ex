defmodule GSMLG.AdminWeb.PKILive.Components.CertificateStatus do
  @moduledoc """
  Component for displaying certificate status badges.
  """
  use GSMLG.AdminWeb, :html

  attr :status, :atom, required: true
  attr :class, :string, default: ""

  def certificate_status(assigns) do
    ~H"""
    <span class={["badge", status_class(@status), @class]}>
      {status_label(@status)}
    </span>
    """
  end

  defp status_class(:active), do: "badge-success"
  defp status_class(:revoked), do: "badge-error"
  defp status_class(:expired), do: "badge-warning"
  defp status_class(:not_yet_valid), do: "badge-info"
  defp status_class(_), do: "badge-ghost"

  defp status_label(:active), do: "Active"
  defp status_label(:revoked), do: "Revoked"
  defp status_label(:expired), do: "Expired"
  defp status_label(:not_yet_valid), do: "Not Yet Valid"
  defp status_label(_), do: "Unknown"
end
