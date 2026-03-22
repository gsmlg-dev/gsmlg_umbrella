defmodule GSMLG.AdminWeb.BlogLive.TranslationLive.Index do
  use GSMLG.AdminWeb, :user_live_view

  alias GSMLG.Content

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    blog = Content.get_blog!(id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(GSMLG.PubSub, "blog_translations:#{blog.id}")
    end

    {:ok, assign(socket, blog: blog, editing_translation_id: nil)}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    blog = socket.assigns.blog
    supported = GSMLG.Locale.supported()
    translations = Content.list_translations(blog.id)

    translation_map =
      Map.new(translations, fn t -> {t.locale, t} end)

    all_locales =
      Enum.reject(supported, &(&1 == blog.source_locale))

    {:noreply,
     socket
     |> assign(:page_title, "Translations — #{blog.title}")
     |> assign(:translations, translation_map)
     |> assign(:locales, all_locales)}
  end

  @impl true
  def handle_info({:translation_updated, _blog_id, locale, status}, socket) do
    translations =
      Map.update(socket.assigns.translations, locale, nil, fn t ->
        if t, do: %{t | status: status}, else: nil
      end)

    {:noreply, assign(socket, translations: translations)}
  end

  @impl true
  def handle_event("translate", %{"locale" => locale}, socket) do
    blog = socket.assigns.blog
    Content.create_pending_translations(blog, [locale])
    translation = Content.get_translation(blog.id, locale)

    if translation do
      Oban.insert(
        GSMLG.Workers.BlogTranslationWorker.new(%{
          "blog_id" => blog.id,
          "locale" => locale,
          "source_locale" => blog.source_locale
        })
      )

      translations = Map.put(socket.assigns.translations, locale, translation)
      {:noreply, assign(socket, translations: translations)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("edit_new_translation", %{"locale" => locale}, socket) do
    blog = socket.assigns.blog
    Content.create_pending_translations(blog, [locale])
    translation = Content.get_translation(blog.id, locale)

    if translation do
      translations = Map.put(socket.assigns.translations, locale, translation)

      {:noreply,
       assign(socket, translations: translations, editing_translation_id: translation.id)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("retranslate", %{"id" => id}, socket) do
    id = String.to_integer(id)
    translation = Enum.find(Map.values(socket.assigns.translations), &(&1.id == id))

    if translation do
      {:ok, updated} = Content.retranslate(translation)

      Oban.insert(
        GSMLG.Workers.BlogTranslationWorker.new(%{
          "blog_id" => socket.assigns.blog.id,
          "locale" => updated.locale,
          "source_locale" => socket.assigns.blog.source_locale
        })
      )

      translations = Map.put(socket.assigns.translations, updated.locale, updated)
      {:noreply, assign(socket, translations: translations)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("edit_translation", %{"id" => id}, socket) do
    {:noreply, assign(socket, editing_translation_id: String.to_integer(id))}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, editing_translation_id: nil)}
  end

  def handle_event("correct_source_locale", %{"locale" => new_locale}, socket) do
    {:ok, updated_blog} = Content.update_blog(socket.assigns.blog, %{source_locale: new_locale})
    translations = Content.list_translations(updated_blog.id)
    translation_map = Map.new(translations, fn t -> {t.locale, t} end)

    {:noreply,
     socket
     |> assign(blog: updated_blog, translations: translation_map)}
  end

  @impl true
  def handle_event(
        "save_translation",
        %{"title" => title, "content" => content} = _params,
        socket
      ) do
    id = socket.assigns.editing_translation_id
    translation = Enum.find(Map.values(socket.assigns.translations), &(&1.id == id))

    if translation do
      {:ok, updated} = Content.admin_edit_translation(translation, title, content)
      translations = Map.put(socket.assigns.translations, updated.locale, updated)

      {:noreply,
       socket
       |> assign(translations: translations, editing_translation_id: nil)}
    else
      {:noreply, socket}
    end
  end

  defp status_class("completed"), do: "badge-success"
  defp status_class("failed"), do: "badge-error"
  defp status_class("in_progress"), do: "badge-warning"
  defp status_class("outdated"), do: "badge-warning"
  defp status_class(_), do: "badge-ghost"
end
