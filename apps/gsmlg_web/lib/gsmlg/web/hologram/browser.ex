defmodule GSMLG.Web.Hologram.Browser do
  @moduledoc false
  use Hologram.JS

  js_import(:mountMap, from: "../../../../assets/js/hologram/browser.mjs")
  js_import(:updateMap, from: "../../../../assets/js/hologram/browser.mjs")
  js_import(:autocropSvg, from: "../../../../assets/js/hologram/browser.mjs")
  js_import(:mountScreensaver, from: "../../../../assets/js/hologram/browser.mjs")
  js_import(:startFullscreen, from: "../../../../assets/js/hologram/browser.mjs")

  def mount_map(id), do: JS.call(:mountMap, [id]) |> Task.await()

  def update_map(id, points, center_longitude) do
    JS.call(:updateMap, [id, points, center_longitude])
  end

  def autocrop_svg(source), do: JS.call(:autocropSvg, [source]) |> Task.await()

  def mount_screensaver(canvas_id, video_id) do
    JS.call(:mountScreensaver, [canvas_id, video_id]) |> Task.await()
  end

  def start_fullscreen(canvas_id), do: JS.call(:startFullscreen, [canvas_id]) |> Task.await()

  def stored_theme do
    case JS.call(:localStorage, :getItem, ["theme"]) do
      theme when theme in ["moonlight", "sunshine"] ->
        theme

      _ ->
        preference = JS.call(:globalThis, :matchMedia, ["(prefers-color-scheme: dark)"])
        if JS.get(preference, :matches), do: "moonlight", else: "sunshine"
    end
  end

  def toggle_theme do
    document = JS.get(:globalThis, :document)
    root = JS.get(document, :documentElement)
    current = JS.call(root, :getAttribute, ["data-theme"])
    theme = if current == "moonlight", do: "sunshine", else: "moonlight"
    JS.call(root, :setAttribute, ["data-theme", theme])
    JS.call(:localStorage, :setItem, ["theme", theme])
    theme
  end
end
