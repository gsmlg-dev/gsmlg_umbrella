defmodule GSMLG.ComponentTest do
  use ExUnit.Case

  import Phoenix.LiveViewTest

  describe "GSMLG.Component" do
    test "provides __using__ macro for component imports" do
      # The module is a macro that imports shared components
      Code.ensure_loaded!(GSMLG.Component)
      assert macro_exported?(GSMLG.Component, :__using__, 1)
    end

    test "can be used in a module" do
      # Define a test module that uses GSMLG.Component
      defmodule TestModule do
        use GSMLG.Component
      end

      # Module should compile successfully when using GSMLG.Component
      assert Code.ensure_loaded?(TestModule)
    end

    test "admin app bar exposes a stable sign-out id" do
      html =
        render_component(&GSMLG.Component.Admin.local_app_bar/1,
          page_title: "Admin"
        )

      assert html =~ ~s(data-admin-sign-out="true")
    end
  end
end
