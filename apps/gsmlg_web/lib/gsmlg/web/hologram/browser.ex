defmodule GSMLG.Web.Hologram.Browser do
  @moduledoc false
  use Hologram.JS

  js_import(:mountMap, from: "../../../../assets/js/hologram/browser.mjs")
  js_import(:updateMap, from: "../../../../assets/js/hologram/browser.mjs")
  js_import(:autocropSvg, from: "../../../../assets/js/hologram/browser.mjs")
  js_import(:mountScreensaver, from: "../../../../assets/js/hologram/browser.mjs")
  js_import(:startFullscreen, from: "../../../../assets/js/hologram/browser.mjs")
  js_import(:mountLayout, from: "../../../../assets/js/hologram/browser.mjs")

  def mount_layout, do: JS.call(:mountLayout, [])

  def mount_map(id), do: JS.call(:mountMap, [id]) |> Task.await()

  def update_map(id, points, center_longitude) do
    JS.call(:updateMap, [id, points, center_longitude])
  end

  def autocrop_svg(source), do: JS.call(:autocropSvg, [source]) |> Task.await()

  def mount_screensaver(canvas_id, video_id) do
    JS.call(:mountScreensaver, [canvas_id, video_id]) |> Task.await()
  end

  def start_fullscreen(canvas_id), do: JS.call(:startFullscreen, [canvas_id]) |> Task.await()
end
