defmodule GSMLG.Component.Admin do
  @moduledoc """
  Provides App UI components.
  """
  use Phoenix.Component
  use PhoenixDuskmoon.Component

  # alias Phoenix.LiveView.JS

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
        <div class="flex items-center gap-2">
          <.dm_theme_switcher />
          <.link href="/sign_out" method="delete" data-confirm="Really sign out?">
            <.dm_btn variant="error" size="sm">Sign Out</.dm_btn>
          </.link>
        </div>
      </:user_profile>
    </.dm_simple_appbar>
    """
  end

  def local_app_menus(assigns) do
    ~H"""
    <.dm_card class="w-max shadow-2xl" body_class="p-6 flex flex-col gap-6">
      <:title>
        <div class="flex items-center gap-2">
          <.dm_mdi name="view-grid-outline" class="w-4 h-4 text-primary" />
          <span class="font-mono text-xs tracking-widest uppercase text-primary">GSMLG Umbrella</span>
        </div>
      </:title>
      <section
        :for={
          {title, list} <- [
            {"Content",
             [
               {"Users", "/users"},
               {"User Tokens", "/user_tokens"},
               {"Blogs", "/blogs"},
               {"GaoNote", "/gao_notes/notes"},
               {"Web Push", "/web_push"},
               {"Github", "/github"}
             ]},
            {"Cluster",
             [
               {"Node Management", "/node_management"}
             ]},
            {"Command Platform",
             [
               {"Commander", "/command_platform"},
               {"Mnesia", "/mnesia"}
             ]},
            {"AWS",
             [
               {"DynamoDB",
                [
                  {"Table List", "/aws/dynamo_db"}
                ]},
               {"Lightsail",
                [
                  {"Instance", "/aws/lightsail"}
                ]},
               {"Route53",
                [
                  {"Hosted Zones", "/aws/route53/hosted_zones"}
                ]},
               {"S3",
                [
                  {"Bucket List", "/aws/s3/buckets"}
                ]}
             ]},
            {"Caddy",
             [
               {"Dashboard", "/caddy"},
               {"Configuration", "/caddy/config"},
               {"Server Control", "/caddy/server"},
               {"Runtime Config", "/caddy/runtime"},
               {"Metrics", "/caddy/metrics"},
               {"Logs", "/caddy/logs"}
             ]},
            {"Dashboard",
             [
               {"Live Dashboard", "/live_dashboard"}
             ]}
          ]
        }
        class="flex flex-col gap-2"
      >
        <h2 class="font-mono text-[10px] tracking-[0.3em] uppercase text-base-content/40 mb-1">
          {title}
        </h2>
        <div class="flex flex-wrap gap-1.5">
          <.link :for={{name, url} <- list} :if={is_binary(url)} navigate={url}>
            <.dm_btn variant="ghost" size="sm">{name}</.dm_btn>
          </.link>
          <div
            :for={{sub_title, sub_list} <- list}
            :if={is_list(sub_list)}
            class="flex flex-col items-start gap-1.5"
          >
            <span class="text-xs text-base-content/50">{sub_title}</span>
            <div class="flex flex-wrap gap-1.5">
              <.link :for={{sub_name, sub_url} <- sub_list} navigate={sub_url}>
                <.dm_btn variant="ghost" size="sm">{sub_name}</.dm_btn>
              </.link>
            </div>
          </div>
        </div>
      </section>
    </.dm_card>
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
