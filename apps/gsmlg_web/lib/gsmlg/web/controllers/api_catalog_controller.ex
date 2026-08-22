defmodule GSMLG.Web.ApiCatalogController do
  use GSMLG.Web, :controller

  @profile "https://www.rfc-editor.org/info/rfc9727"
  @content_type ~s(application/linkset+json; profile="#{@profile}")
  @link_header ~s(</.well-known/api-catalog>; rel="api-catalog")

  def show(conn, _params) do
    body =
      Jason.encode!(%{
        "linkset" => [
          %{
            "anchor" => "/api",
            "service-desc" => [
              %{"href" => "/api/openapi.json", "type" => "application/json"}
            ]
          },
          %{
            "anchor" => "/rules/zeroomega",
            "service-desc" => [
              %{"href" => "/api/openapi.json", "type" => "application/json"}
            ]
          }
        ]
      })

    conn
    |> put_resp_header("content-type", @content_type)
    |> put_resp_header("link", @link_header)
    |> send_resp(200, body)
  end
end
