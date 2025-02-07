defmodule GSMLGAdminWeb.AppComponents do
  @moduledoc """
  Provides App UI components.
  """
  use Phoenix.Component
  use PhoenixDuskmoon.Component

  alias Phoenix.LiveView.JS
  import GSMLGAdminWeb.Gettext

  attr(:page_title, :string, default: "GSMLG Admin")

  def local_app_bar(assigns) do
    ~H"""
    <.dm_simple_appbar title={@page_title} class="h-14 bg-primary text-primary-content z-20">
      <:logo>
        <div class="dropdown">
          <div tabindex="0" role="button" class="btn btn-ghost btn-sm">
            <.dm_mdi name="menu" class="w-8 h-8" />
          </div>
          <div tabindex="0" class="dropdown-content z-1000 w-auto p-2">
            <.local_app_menus />
          </div>
        </div>
        <.dm_link navigate="/">
          <logo-gsmlg-dev class="h-12" />
        </.dm_link>
      </:logo>
      <:user_profile>
        <.dm_btn
          class="btn-error"
          confirm_class="btn-error btn-sm"
          cancel_class="btn-ghost btn-sm"
          confirm_title="Sign Out!"
          confirm="Really?"
        >
          Sign Out
          <:confirm_action>
            <form method="dialog">
              <.dm_link class="btn btn-error btn-sm" href="/sign_out" method="DELETE">
                Sign Out
              </.dm_link>
            </form>
          </:confirm_action>
        </.dm_btn>
      </:user_profile>
    </.dm_simple_appbar>
    """
  end

  def local_app_menus(assigns) do
    ~H"""
    <div class="card bg-neutral text-neutral-content shadow shadow-lg shadow-neutral-content">
      <div class="card-body">
        <div class="card-title text-primary">GSMLG Umbrella Modules</div>
        <div class="flex flex-col gap-4">
          <section
            :for={
              {title, list} <- [
                {"Content Overview",
                 [
                   {"User List", "/users"},
                   {"User Token List", "/user_tokens"},
                   {"Blog List", "/blogs"},
                   {"Github", "/github"}
                 ]},
                {"Cluster Overview",
                 [
                   {"Node Management", "/node_management"}
                 ]},
                {"Command Platform",
                 [
                   {"Commander Management", "/command_platform"},
                   {"Mnesia Management", "/mnesia"}
                 ]},
                {"AWS",
                 [
                   {"Route53",
                    [
                      {"Hosted Zones", "/aws/route53/hosted_zones"}
                    ]}
                 ]},
                {"Dashboard",
                 [
                   {"Live Dashboard", "/live_dashboard"}
                 ]}
              ]
            }
            class="flex flex-col gap-2"
          >
            <header class="flex items-center">
              <h2 class="text-xl text-secondary">{title}</h2>
            </header>
            <div class="grid grid-flow-col auto-cols-max gap-2">
              <.dm_link
                :for={{name, url} <- list}
                :if={is_binary(url)}
                class="btn btn-primary btn-sm"
                navigate={url}
              >
                <span>{name}</span>
              </.dm_link>
              <div
                :for={{sub_title, sub_list} <- list}
                :if={is_list(sub_list)}
                class="flex flex-col items-start gap-2 ml-8"
              >
                <h3 class="text-lg text-left text-info opacity-70">{sub_title}</h3>
                <div class="grid grid-flow-col auto-cols-max gap-4">
                  <.dm_link
                    :for={{sub_name, sub_url} <- sub_list}
                    class="btn btn-primary btn-sm"
                    navigate={sub_url}
                  >
                    <span>{sub_name}</span>
                  </.dm_link>
                </div>
              </div>
            </div>
          </section>
        </div>
      </div>
    </div>
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
