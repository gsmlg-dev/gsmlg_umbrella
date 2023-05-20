defmodule GSMLGAdminWeb.ChatgptController do
  use GSMLGAdminWeb, :controller

  defp render_page(conn, params, args) do
    chatgpt_config = Application.get_env(:gsmlg_admin_web, :chatgpt)
    default_model = Keyword.get(chatgpt_config, :default_model, :"gpt-3.5-turbo")

    session_model =
      case get_session(conn) do
        %{"model" => model} ->
          model

        _ ->
          default_model
      end

    model =
      case Map.get(params, "model", nil) do
        nil -> session_model
        m -> m
      end

    args =
      Map.merge(
        %{
          "model" => model,
          "models" => Keyword.get(chatgpt_config, :models, [model]),
          "scenarios" => GSMLG.Openai.Scenario.default_scenarios()
        },
        args
      )

    conn = put_session(conn, "model", Map.get(params, "model", model))

    render(conn, :chat, args: args)
  end

  def chat(conn, params) do
    render_page(conn, params, %{"mode" => :chat})
  end

  def scenario(conn, params) do
    scenario =
      GSMLG.Openai.Scenario.default_scenarios()
      |> Enum.find(fn sc -> sc.id == Map.get(params, "scenario_id", nil) end)

    render_page(conn, params, %{} |> Map.put("mode", :scenario) |> Map.put("scenario", scenario))
  end
end
