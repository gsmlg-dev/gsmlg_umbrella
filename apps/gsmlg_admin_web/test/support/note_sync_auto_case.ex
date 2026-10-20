defmodule GSMLG.AdminWeb.NoteSyncAutoCase do
  @moduledoc "Committed fixtures for independent sync snapshot and durable worker connections."
  use ExUnit.CaseTemplate
  import Ecto.Query
  alias GSMLG.GaoNote.{Label, LabelSetting, Log, Note}
  alias GSMLG.GaoNote.Sync.{Peer, Record}
  alias GSMLG.Repo

  using do
    quote do
      import Phoenix.ChannelTest
      @endpoint GSMLG.AdminWeb.Endpoint
    end
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
    label = "task_sync_" <> String.replace(Ecto.UUID.generate(), "-", "")
    previous = Application.fetch_env(:gsmlg_gao_note, :compat_services)
    Application.put_env(:gsmlg_gao_note, :compat_services, [])

    on_exit(fn ->
      selector = label <> "=selected"
      settings = Repo.all(from(s in LabelSetting, where: s.name == ^label, select: s.id))
      ids = Repo.all(from(l in Label, where: l.label_setting_id in ^settings, select: l.note_id))
      peers = Repo.all(from(p in Peer, where: ^selector in p.selectors, select: p.id))
      Repo.delete_all(from(j in Styx.Job, where: fragment("?->>'note_id'", j.args) in ^ids))
      Repo.delete_all(from(l in Log, where: l.note_id in ^ids or l.entity_id in ^settings))
      Repo.delete_all(from(r in Record, where: r.peer_id in ^peers or r.note_id in ^ids))
      Repo.delete_all(from(n in Note, where: n.id in ^ids))
      Repo.delete_all(from(s in LabelSetting, where: s.id in ^settings))
      Repo.delete_all(from(p in Peer, where: p.id in ^peers))

      case previous do
        {:ok, value} -> Application.put_env(:gsmlg_gao_note, :compat_services, value)
        :error -> Application.delete_env(:gsmlg_gao_note, :compat_services)
      end

      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    end)

    %{label: label}
  end
end
