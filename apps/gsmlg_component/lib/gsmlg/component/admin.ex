defmodule GSMLG.Component.Admin do
  @moduledoc """
  Provides App UI components.
  """
  use Phoenix.Component
  use PhoenixDuskmoon.Component

  # alias Phoenix.LiveView.JS

  attr(:page_title, :string, default: "GSMLG Admin")
  slot(:navigation)

  def local_app_bar(assigns) do
    ~H"""
    <.dm_simple_appbar title={@page_title} class="h-14 bg-primary text-primary-content z-20">
      <:logo>
        <.dm_dropdown
          :if={@navigation != []}
          id="admin-app-menu"
          class="lg:hidden"
          dropdown_class="popover-start w-max max-w-[calc(100vw-1rem)] max-h-[calc(100dvh-5rem)] overflow-auto p-2 lg:hidden"
        >
          <:trigger class="btn btn-ghost btn-sm">
            <.dm_mdi name="menu" class="w-8 h-8" />
            <span class="sr-only">Open admin navigation</span>
          </:trigger>
          <:content>
            {render_slot(@navigation)}
          </:content>
        </.dm_dropdown>
        <.dm_link navigate="/" class="hidden sm:inline-flex">
          <%!-- # WORKAROUND(upstream): gsmlg-dev/gsmlg-nodejs#4 --%>
          <logo-gsmlg-dev class="h-12" width="200" height="40" />
        </.dm_link>
      </:logo>
      <:user_profile>
        <div class="flex items-center gap-2">
          <.dm_theme_switcher />
          <%!-- WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#161 --%>
          <.link
            class="admin-sign-out"
            data-admin-sign-out="true"
            href="/sign_out"
            method="delete"
            data-confirm="Really sign out?"
          >
            <.dm_btn variant="error" size="sm">Sign Out</.dm_btn>
          </.link>
        </div>
      </:user_profile>
    </.dm_simple_appbar>
    """
  end

  def __hold_class_for_daisyui__(assigns) do
    ~H"""
    <div class="navbar"></div>
    <dialog class="modal">
      <div class="modal-box">
        <div class="h-12 text-2xl text-primary">Modal</div>
        <div class="modal-action">
          <button>close</button>
        </div>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button>close</button>
      </form>
    </dialog>
    <div class="hidden w-80 sm:w-96 toast toast-top toast-end z-[1000] alert alert-info alert-error" />
    """
  end
end
