defmodule GSMLG.Web.OpenApi.BlogOperations do
  @moduledoc false

  alias GSMLG.Web.OpenApi.Operation

  def paths do
    %{
      "/api/blogs" => %{
        "get" =>
          Operation.operation(
            "listBlogs",
            "Blog",
            "List published blogs",
            %{"200" => Operation.json_response("Published blogs", "BlogList")},
            security: Operation.anonymous_or_bearer()
          )
      }
    }
  end
end
