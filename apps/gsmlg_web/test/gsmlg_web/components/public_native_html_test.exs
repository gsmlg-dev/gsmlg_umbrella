defmodule GSMLG.Web.PublicNativeHTMLTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias GSMLG.Web.{Layouts, PageHTML, SignHTML}

  test "root has a usable browser color before JavaScript loads" do
    document =
      render_component(&Layouts.root/1, inner_content: "")
      |> native_document()

    assert [theme_color] = Floki.find(document, "meta[name=theme-color]")
    assert [color] = Floki.attribute(theme_color, "content")
    assert color =~ ~r/^#[0-9a-f]{6}$/i
    assert [_root] = Floki.find(document, "html[data-theme=sunshine]")
    assert [_body] = Floki.find(document, "body.bg-surface.text-on-surface")
  end

  test "repository groups render native tabs with matching accessible panels" do
    repo = %{
      "name" => "native-ui",
      "full_name" => "gsmlg-dev/native-ui",
      "owner" => %{"login" => "gsmlg-dev"},
      "stargazers_count" => 1,
      "description" => "A repository card",
      "updated_at" => "2026-11-21T00:00:00Z",
      "has_pages" => false,
      "language" => "Elixir"
    }

    groups = [{"gsmlg-dev", [repo]}, {"gsmlg-opt", []}, {"gsmlg-app", []}]

    document =
      render_component(&PageHTML.index/1,
        flash: %{},
        group_repos: groups,
        active_repo_group: "gsmlg-dev"
      )
      |> native_document()

    assert [first, second, third] = Floki.find(document, "button[role=tab]")
    assert Floki.attribute(first, "aria-selected") == ["true"]
    assert Floki.attribute(second, "aria-selected") == ["false"]
    assert Floki.attribute(third, "aria-selected") == ["false"]
    assert [visible] = Floki.find(document, "section[role=tabpanel]:not([hidden])")
    assert Floki.attribute(visible, "aria-labelledby") == Floki.attribute(first, "id")
    assert [_card] = Floki.find(visible, "article")
    assert [_link] = Floki.find(visible, "a[href='https://github.com/gsmlg-dev/native-ui']")

    for tab <- [first, second, third] do
      [panel_id] = Floki.attribute(tab, "aria-controls")
      assert [_panel] = Floki.find(document, "section[role=tabpanel]##{panel_id}")
    end
  end

  test "legacy authentication buttons stay native without enabling the unwired POST routes" do
    for component <- [&SignHTML.sign_in/1, &SignHTML.sign_up/1] do
      document =
        render_component(component,
          flash: %{},
          changeset: Phoenix.Component.to_form(%{}, as: :auth)
        )
        |> native_document()

      assert [_button] = Floki.find(document, "form#user-form button[type=button]")
      assert Floki.find(document, "form#user-form button[type=submit]") == []
      assert [_password] = Floki.find(document, "form#user-form input[type=password]")
    end
  end

  defp native_document(html) do
    document = Floki.parse_document!(html)

    custom_tags =
      document
      |> Floki.find("*")
      |> Enum.map(&elem(&1, 0))
      |> Enum.filter(&String.contains?(&1, "-"))
      |> Enum.uniq()

    assert custom_tags == []
    document
  end
end
