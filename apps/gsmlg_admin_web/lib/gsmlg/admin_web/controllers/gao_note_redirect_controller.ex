defmodule GSMLG.AdminWeb.GaoNoteRedirectController do
  use GSMLG.AdminWeb, :controller

  def notes(conn, _params) do
    redirect(conn, to: ~p"/gao_notes/notes")
  end

  def new_note(conn, _params) do
    redirect(conn, to: ~p"/gao_notes/notes/new")
  end

  def commander_list(conn, _params) do
    redirect(conn, to: ~p"/commander/list")
  end
end
