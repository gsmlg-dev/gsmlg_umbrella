defmodule GSMLG.AdminWeb.BlogLive.Index do
  use GSMLG.AdminWeb, :user_live_view

  alias GSMLG.Content
  alias GSMLG.Content.Blog
  alias GSMLG.Content.TranslationProviderSetting

  @impl true
  def mount(_params, _session, socket) do
    Process.send_after(__MODULE__, :refresh_list, 15_000)

    socket =
      socket

    {:ok, assign(socket, active_menu: "blog_list")}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Listing Blogs")
    |> stream(:blogs, [])
    |> start_async(:get_blogs, fn -> Content.list_blogs() end)
  end

  defp apply_action(socket, :settings, _params) do
    setting = Content.get_translation_provider_setting()
    changeset = Content.change_translation_provider_setting(setting)

    socket
    |> assign(:page_title, "Translation Provider Settings")
    |> assign(:setting, setting)
    |> assign(:settings_form, to_form(changeset))
  end

  defp apply_action(socket, :new, _params) do
    changeset = Content.change_blog(%Blog{date: Date.utc_today()})

    socket
    |> assign(:page_title, page_title(socket.assigns.live_action))
    |> assign(:changeset, changeset)
    |> assign(:form, to_form(changeset))
    |> assign(:blog, %Blog{})
  end

  defp apply_action(socket, :edit, %{"id" => id} = _params) do
    blog = Content.get_blog!(id)
    changeset = Content.change_blog(blog)

    socket
    |> assign(:page_title, page_title(socket.assigns.live_action))
    |> assign(:changeset, changeset)
    |> assign(:form, to_form(changeset))
    |> assign(:blog, blog)
  end

  defp apply_action(socket, :show, %{"id" => id} = _params) do
    socket
    |> assign(:page_title, page_title(socket.assigns.live_action))
    |> assign(:blog, Content.get_blog!(id))
  end

  @impl Phoenix.LiveView
  def handle_event("delete", %{"id" => id}, socket) do
    blog = Content.get_blog!(id)
    {:ok, _} = Content.delete_blog(blog)

    {:noreply, socket |> apply_blogs()}
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"blog" => blog_params}, socket) do
    changeset =
      socket.assigns.blog
      |> Content.change_blog(blog_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, changeset: changeset, form: to_form(changeset))}
  end

  def handle_event("form:init", _params, socket) do
    {:reply, socket.assigns.blog, socket}
  end

  def handle_event("form:submit", %{"blog" => blog_params}, socket) do
    save_blog(socket, socket.assigns.live_action, blog_params)
  end

  def handle_event("save", %{"blog" => blog_params}, socket) do
    save_blog(socket, socket.assigns.live_action, blog_params)
  end

  def handle_event("save_settings", %{"translation_provider_setting" => params}, socket) do
    case Content.upsert_translation_provider_setting(params) do
      {:ok, _setting} ->
        {:noreply,
         socket
         |> put_flash(:info, "Translation provider settings saved")
         |> push_navigate(to: ~p"/blogs")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :settings_form, to_form(changeset))}
    end
  end

  def handle_event("validate_settings", %{"translation_provider_setting" => params}, socket) do
    changeset =
      socket.assigns.setting
      |> Content.change_translation_provider_setting(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :settings_form, to_form(changeset))}
  end

  defp save_blog(socket, :edit, blog_params) do
    case Content.update_blog(socket.assigns.blog, blog_params) do
      {:ok, blog} ->
        {:noreply,
         socket
         |> put_flash(:info, "Blog updated successfully")
         |> push_navigate(to: ~p"/blogs/#{blog.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  defp save_blog(socket, :new, blog_params) do
    case Content.create_blog(blog_params) do
      {:ok, blog} ->
        {:noreply,
         socket
         |> put_flash(:info, "Blog created successfully")
         |> push_navigate(to: ~p"/blogs/#{blog.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end

  @impl true
  def handle_info(:refresh_list, socket) do
    Process.send_after(__MODULE__, :refresh_list, 15_000)
    {:noreply, socket |> apply_blogs()}
  end

  @impl Phoenix.LiveView
  def handle_async(:get_blogs, {:ok, fetched_blogs}, socket) do
    {:noreply, stream(socket, :blogs, fetched_blogs)}
  end

  defp apply_blogs(socket) do
    socket
    |> assign(:blogs, Content.list_blogs())
  end

  defp page_title(:new), do: "New Blog"
  defp page_title(:edit), do: "Edit Blog"
  defp page_title(:show), do: "Show Blog"
  defp page_title(:settings), do: "Translation Provider Settings"
end
