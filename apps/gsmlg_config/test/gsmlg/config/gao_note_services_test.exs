defmodule GSMLG.Config.GaoNoteServicesTest do
  use ExUnit.Case, async: false

  test "TOML service configuration validates and reaches GaoNote application environment" do
    previous = Application.fetch_env(:gsmlg_gao_note, :compat_services)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:gsmlg_gao_note, :compat_services, value)
        :error -> Application.delete_env(:gsmlg_gao_note, :compat_services)
      end
    end)

    config = %{
      index_url: "http://index/v1/gao-note/index",
      search_url: "http://index/v1/gao-note/search",
      search_token: "service-token",
      minimum_score: 0.01,
      pdf_renderer_url: "http://renderer:3000"
    }

    assert {:ok, validated} = GSMLG.Config.Schema.validate_section(:gao_note, config)
    GSMLG.Config.Setup.setup(%{gao_note: validated})
    assert Application.get_env(:gsmlg_gao_note, :compat_services)[:index_url] == config.index_url
    assert Application.get_env(:gsmlg_gao_note, :compat_services)[:minimum_score] == 0.01

    assert {:error, _} =
             GSMLG.Config.Schema.validate_section(:gao_note, %{minimum_score: "not a number"})
  end
end
