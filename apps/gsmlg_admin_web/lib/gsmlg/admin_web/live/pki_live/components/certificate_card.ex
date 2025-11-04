defmodule GSMLG.AdminWeb.PKILive.Components.CertificateCard do
  @moduledoc """
  Component for displaying certificate information in a card format.
  """
  use GSMLG.AdminWeb, :html
  alias GSMLG.AdminWeb.PKILive.Components.{CertificateStatus, ValidityIndicator}

  attr :certificate, :map, required: true
  attr :show_actions, :boolean, default: true
  attr :class, :string, default: ""

  def certificate_card(assigns) do
    ~H"""
    <div class={["card bg-base-100 shadow-md hover:shadow-lg transition-shadow", @class]}>
      <div class="card-body">
        <div class="flex justify-between items-start">
          <div class="flex-1">
            <h3 class="card-title text-lg">
              <%= @certificate.subject %>
            </h3>
            <p class="text-sm text-gray-500">Serial: <%= @certificate.serial %></p>
          </div>
          <CertificateStatus.certificate_status status={@certificate.status} />
        </div>

        <div class="divider my-2"></div>

        <div class="grid grid-cols-2 gap-4 text-sm">
          <div>
            <span class="font-semibold">Issued:</span>
            <span class="ml-2"><%= format_date(@certificate.not_before) %></span>
          </div>
          <div>
            <span class="font-semibold">Expires:</span>
            <span class="ml-2"><%= format_date(@certificate.not_after) %></span>
          </div>
        </div>

        <ValidityIndicator.validity_indicator not_after={@certificate.not_after} class="mt-2" />

        <%= if @certificate[:subject_alt_names] && length(@certificate.subject_alt_names) > 0 do %>
          <div class="mt-3">
            <span class="text-sm font-semibold">Subject Alternative Names:</span>
            <div class="flex flex-wrap gap-1 mt-1">
              <%= for san <- Enum.take(@certificate.subject_alt_names, 5) do %>
                <span class="badge badge-sm badge-ghost"><%= san %></span>
              <% end %>
              <%= if length(@certificate.subject_alt_names) > 5 do %>
                <span class="badge badge-sm badge-ghost">
                  +<%= length(@certificate.subject_alt_names) - 5 %> more
                </span>
              <% end %>
            </div>
          </div>
        <% end %>

        <%= if @show_actions do %>
          <div class="card-actions justify-end mt-4">
            <.link
              navigate={~p"/pki/certificates/#{@certificate.serial}"}
              class="btn btn-sm btn-primary"
            >
              View Details
            </.link>
            <%= if @certificate.status == :active do %>
              <.link
                navigate={~p"/pki/certificates/#{@certificate.serial}/revoke"}
                class="btn btn-sm btn-error btn-outline"
              >
                Revoke
              </.link>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp format_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  end

  defp format_date(date_string) when is_binary(date_string) do
    case DateTime.from_iso8601(date_string) do
      {:ok, dt, _} -> format_date(dt)
      _ -> date_string
    end
  end

  defp format_date(_), do: "N/A"
end
