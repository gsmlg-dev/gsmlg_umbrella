defmodule GSMLG.Web.Hologram.Pages.Screensaver do
  use Hologram.Page

  alias GSMLG.Web.Hologram.{Browser, Messages, Shell}

  route("/toolbox/screensaver")
  layout(Shell)

  @impl true
  def init(_params, component, server) do
    component
    |> Messages.init(server)
    |> put_state(ready: false, error: nil)
    |> put_action(:setup)
  end

  @impl true
  def action(:setup, _params, component) do
    if Browser.mount_screensaver("screen-saver-canvas", "screen-saver-video") do
      put_state(component, ready: true, error: nil)
    else
      put_state(component, ready: false, error: component.state.text.browser_unavailable)
    end
  end

  def action(:fullscreen, _params, component) do
    if Browser.start_fullscreen("screen-saver-canvas") do
      put_state(component, :error, nil)
    else
      put_state(component, :error, component.state.text.browser_unavailable)
    end
  end

  @impl true
  def template do
    ~HOLO"""
    <h1 class="header-hero-text mb-10">{@text.screensaver}</h1>
    <div class="flex flex-col items-center gap-6">
      <canvas id="screen-saver-canvas" data-hologram-screensaver-video={@ready && "screen-saver-video"} class="w-full max-w-4xl min-h-80 rounded-lg"></canvas>
      <video id="screen-saver-video" class="hidden w-full min-h-80" controls></video>
      <button id="screen-saver-trigger" type="button" class="btn btn-primary" disabled={!@ready} $click="fullscreen">{@text.start_fullscreen}</button>
      {%if !@ready && !@error}<p role="status">{@text.loading}</p>{/if}
      {%if @error}<p role="alert" class="alert alert-error">{@error}</p>{/if}
    </div>
    """
  end
end
