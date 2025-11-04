defmodule GSMLG.AdminWeb.PKILive.SearchLive.Index do
  use GSMLG.AdminWeb, :user_live_view
  alias GSMLG.AdminWeb.PKIContext

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        search_query: "",
        search_type: :subject,
        results: [],
        page_title: "Certificate Search"
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("search", %{"query" => query, "type" => type}, socket) do
    search_type = String.to_existing_atom(type)

    results =
      if query != "" do
        case PKIContext.search_certificates(query, type: search_type) do
          {:ok, certs} -> certs
          _ -> []
        end
      else
        []
      end

    {:noreply, assign(socket, search_query: query, search_type: search_type, results: results)}
  end
end
