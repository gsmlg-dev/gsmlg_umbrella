defmodule GSMLG.Web.ApiSpec do
  @moduledoc false

  @behaviour OpenApiSpex.OpenApi

  alias GSMLG.Web.OpenApi.{Operations, Schemas}
  alias OpenApiSpex.OpenApi

  @impl OpenApiSpex.OpenApi
  def spec do
    OpenApi.from_map(%{
      "openapi" => "3.0.3",
      "info" => %{
        "title" => "GSMLG Web API",
        "version" => to_string(Application.spec(:gsmlg_web, :vsn) || "0.1.0"),
        "description" => "REST API published by the GSMLG public web application"
      },
      "servers" => [%{"url" => "/"}],
      "paths" => Operations.paths(),
      "components" => Schemas.components()
    })
  end
end
