defmodule GSMLG.AdminWeb.PKILive.Components.PkiLeftMenu do
  @moduledoc """
  PKI left navigation menu component.
  Provides consistent navigation across all PKI management pages.
  """
  use GSMLG.AdminWeb, :html

  attr :active_menu, :string, default: ""
  attr :class, :string, default: "sticky top-0"

  def pki_left_menu(assigns) do
    ~H"""
    <.dm_left_menu class={@class}>
      <:menu>
        <h2 class="menu-title">Certificate Authorities</h2>
        <ul>
          <li>
            <.link
              class={if(@active_menu == "pki_ca_list", do: "active")}
              navigate={~p"/pki/ca"}
            >
              CA List
            </.link>
          </li>
          <li>
            <.link
              class={if(@active_menu == "pki_ca_new", do: "active")}
              navigate={~p"/pki/ca/new"}
            >
              New CA
            </.link>
          </li>
        </ul>
      </:menu>

      <:menu>
        <h2 class="menu-title">Certificates</h2>
        <ul>
          <li>
            <.link
              class={if(@active_menu == "pki_certificates", do: "active")}
              navigate={~p"/pki/certificates"}
            >
              Certificate List
            </.link>
          </li>
          <li>
            <.link
              class={if(@active_menu == "pki_certificates_issue", do: "active")}
              navigate={~p"/pki/certificates/issue"}
            >
              Issue Certificate
            </.link>
          </li>
        </ul>
      </:menu>

      <:menu>
        <h2 class="menu-title">Certificate Requests</h2>
        <ul>
          <li>
            <.link
              class={if(@active_menu == "pki_csr", do: "active")}
              navigate={~p"/pki/csr"}
            >
              CSR Management
            </.link>
          </li>
          <li>
            <.link
              class={if(@active_menu == "pki_csr_upload", do: "active")}
              navigate={~p"/pki/csr/upload"}
            >
              Upload CSR
            </.link>
          </li>
        </ul>
      </:menu>

      <:menu>
        <h2 class="menu-title">Tools</h2>
        <ul>
          <li>
            <.link
              class={if(@active_menu == "pki_search", do: "active")}
              navigate={~p"/pki/search"}
            >
              Search
            </.link>
          </li>
          <li>
            <.link
              class={if(@active_menu == "pki_analytics", do: "active")}
              navigate={~p"/pki/analytics"}
            >
              Analytics
            </.link>
          </li>
        </ul>
      </:menu>
    </.dm_left_menu>
    """
  end
end
