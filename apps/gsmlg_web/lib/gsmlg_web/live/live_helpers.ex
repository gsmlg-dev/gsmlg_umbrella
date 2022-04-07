defmodule GSMLGWeb.LiveHelpers do
  import Phoenix.LiveView
  import Phoenix.LiveView.Helpers

  alias Phoenix.LiveView.JS

  @doc """
  Renders a live component inside a modal.

  The rendered modal receives a `:return_to` option to properly update
  the URL when the modal is closed.

  ## Examples

      <.modal return_to={Routes.user_index_path(@socket, :index)}>
        <.live_component
          module={AlphaGoWeb.UserLive.FormComponent}
          id={@user.id || :new}
          title={@page_title}
          action={@live_action}
          return_to={Routes.user_index_path(@socket, :index)}
          user: @user
        />
      </.modal>
  """
  def modal(assigns) do
    assigns = assign_new(assigns, :return_to, fn -> nil end)

    ~H"""
    <div id="modal" class="phx-modal fade-in" phx-remove={hide_modal()}>
      <div
        id="modal-content"
        class="phx-modal-content fade-in-scale"
        phx-click-away={JS.dispatch("click", to: "#close")}
        phx-window-keydown={JS.dispatch("click", to: "#close")}
        phx-key="escape"
      >
        <%= if @return_to do %>
          <%= live_patch "✖",
            to: @return_to,
            id: "close",
            class: "phx-modal-close",
            phx_click: hide_modal()
          %>
        <% else %>
         <a id="close" href="#" class="phx-modal-close" phx-click={hide_modal()}>✖</a>
        <% end %>

        <%= render_slot(@inner_block) %>
      </div>
    </div>
    """
  end

  defp hide_modal(js \\ %JS{}) do
    js
    |> JS.hide(to: "#modal", transition: "fade-out")
    |> JS.hide(to: "#modal-content", transition: "fade-out-scale")
  end

  import Phoenix.HTML
  import Phoenix.HTML.Tag
  import Phoenix.HTML.Form

  def bx_label(form, field, opts \\[]) do
    opts =
      opts
      |> Keyword.put_new(:for, input_id(form, field))
      |> Keyword.put_new(:show_colon, true)

    content_tag(:"ui5-label", humanize(field), opts)
  end

  def bx_text_input(form, field, opts \\ []) do
    generic_input(:text, form, field, opts)
  end

  def bx_password_input(form, field, opts \\ []) do
    generic_input(:Password, form, field, opts)
  end

  def bx_date_select(form, field, opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:id, input_id(form, field))
      |> Keyword.put_new(:name, input_name(form, field))
      |> Keyword.put_new(:value, input_value(form, field))
      |> Keyword.update!(:value, &maybe_html_escape/1)

    error = form.errors |> Keyword.get_values(field)

    unless Enum.empty?(error) do
      opts = opts |> Keyword.put_new(:value_state, "Error")
      content_tag(:"ui5-date-picker", opts) do
        Enum.map(error, fn {err, _} ->
          content_tag(:div, err,
            slot: "valueStateMessage",
            phx_feedback_for: input_name(form, field)
          )
        end)
      end
    else
      content_tag(:"ui5-date-picker", "", opts)
    end
  end

  def bx_textarea(form, field, opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:id, input_id(form, field))
      |> Keyword.put_new(:name, input_name(form, field))
      |> Keyword.put_new(:value, html_escape(input_value(form, field) || ""))

    error = form.errors |> Keyword.get_values(field)

    unless Enum.empty?(error) do
      opts = opts |> Keyword.put_new(:value_state, "Error")
      content_tag(:"ui5-textarea", opts) do
        Enum.map(error, fn {err, _} ->
          content_tag(:div, err,
            slot: "valueStateMessage",
            phx_feedback_for: input_name(form, field)
          )
        end)
      end
    else
      content_tag(:"ui5-textarea", "", opts)
    end
  end

  def bx_link(text, opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:href, Keyword.get(opts, :to))

    content_tag(:"ui5-link", text, opts)
  end

  @spec bx_live_patch(any, keyword) ::
          {:safe, [binary | maybe_improper_list(any, binary | []) | 47 | 60 | 62, ...]}
  def bx_live_patch(text, opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:href, Keyword.get(opts, :to))
      |> Keyword.put_new(:data_phx_link, :patch)
      |> Keyword.put_new(:data_phx_link_state, :push)

    content_tag(:"ui5-link", text, opts)
  end

  def bx_live_redirect(text, opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:href, Keyword.get(opts, :to))
      |> Keyword.put_new(:data_phx_link, :redirect)
      |> Keyword.put_new(:data_phx_link_state, :push)

    content_tag(:"ui5-link", text, opts)
  end

  def bx_submit(text, opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:design, "Emphasized")
      |> Keyword.put_new(:submits, true)

    content_tag(:"ui5-button", text, opts)
  end

  defp generic_input(type, form, field, opts)
       when is_list(opts) and (is_atom(field) or is_binary(field)) do
    opts =
      opts
      |> Keyword.put_new(:type, type)
      |> Keyword.put_new(:id, input_id(form, field))
      |> Keyword.put_new(:name, input_name(form, field))
      |> Keyword.put_new(:value, input_value(form, field))
      |> Keyword.update!(:value, &maybe_html_escape/1)

    error = form.errors |> Keyword.get_values(field)

    unless Enum.empty?(error) do
      opts = opts |> Keyword.put_new(:value_state, "Error")
      content_tag(:"ui5-input", opts) do
        Enum.map(error, fn {err, _} ->
          content_tag(:div, err,
            slot: "valueStateMessage",
            phx_feedback_for: input_name(form, field)
          )
        end)
      end
    else
      content_tag(:"ui5-input", "", opts)
    end

  end

  defp maybe_html_escape(nil), do: nil
  defp maybe_html_escape(value), do: html_escape(value)
end
