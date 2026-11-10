defmodule GSMLG.AdminWeb.AWSManagementRemovalTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias GSMLG.AdminWeb.{ApiProviderLive, PageHTML, Router}

  test "AWS management URLs no longer route to LiveViews" do
    paths = [
      "/aws/dynamo_db",
      "/aws/dynamo_db/example/scan",
      "/aws/route53/hosted_zones",
      "/aws/route53/hosted_zones/example/records",
      "/aws/s3/buckets",
      "/aws/lightsail"
    ]

    for path <- paths do
      assert Phoenix.Router.route_info(Router, "GET", path, "localhost") == :error
    end
  end

  test "admin home omits AWS management while retaining the other service links" do
    html =
      render_component(&PageHTML.index/1,
        flash: %{},
        page_title: "Home",
        data: %{blog_count: 0, user_count: 0, token_count: 0}
      )

    document = Floki.parse_fragment!(html)

    refute html =~ "AWS"
    assert Floki.find(document, ~s(a[href^="/aws"])) == []

    for path <- ["/storage", "/storage/config", "/gao_notes/notes", "/commander/list", "/scout"] do
      assert Floki.find(document, ~s(a[href="#{path}"])) != []
    end
  end

  test "API provider form no longer advertises AWS management credentials" do
    html =
      render_component(&ApiProviderLive.Index.render/1,
        flash: %{},
        page_title: "New API Provider",
        active_menu: "api_providers",
        live_action: :new,
        changeset: GSMLG.ApiProviders.change_api_provider(%GSMLG.ApiProvider{}),
        credentials_json: "",
        metadata_json: "{}"
      )

    refute html =~ "AWS"
    refute html =~ "github, aws"
    refute html =~ "secret_access_key"
    assert html =~ "OpenAI/DeepSeek"
    assert html =~ "GitHub"
  end
end
