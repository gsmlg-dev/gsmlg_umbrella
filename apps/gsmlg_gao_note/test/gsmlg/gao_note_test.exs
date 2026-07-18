defmodule GSMLG.GaoNoteTest do
  use GSMLG.GaoNote.DataCase, async: false
  use Oban.Testing, repo: GSMLG.Repo

  defmodule S3Stub do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    put "/*path" do
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      if String.starts_with?(body, "block-for-") do
        notify({:s3_put_blocked, self(), conn.request_path})

        receive do
          :release_s3_put -> :ok
        after
          5_000 -> exit(:s3_put_release_timeout)
        end
      else
        notify({:s3_put, conn.request_path, body})
      end

      send_resp(conn, 200, "")
    end

    get "/*path" do
      notify({:s3_get, conn.request_path, Plug.Conn.get_req_header(conn, "range")})
      body = Application.get_env(:gsmlg_storage, :gao_note_test_object, "")
      send_resp(conn, 206, body)
    end

    delete "/*path" do
      notify({:s3_delete, conn.request_path})
      send_resp(conn, 204, "")
    end

    match _, do: send_resp(conn, 200, "")

    defp notify(message) do
      if pid = Application.get_env(:gsmlg_storage, :gao_note_test_pid) do
        send(pid, message)
      end
    end
  end

  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.{Attachment, Label, LabelSetting, Log, MCPSetting, Note}
  alias GSMLG.GaoNote.Workers.StorageFilePurgeWorker
  alias GSMLG.Accounts.User
  alias GSMLG.Storage
  alias GSMLG.Storage.StorageFile

  setup do
    Repo.delete_all(MCPSetting)
    Repo.delete_all(Log)
    Repo.delete_all(Attachment)
    Repo.delete_all(Label)
    Repo.delete_all(LabelSetting)
    Repo.delete_all(Note)
    Repo.delete_all(StorageFile)
    :ok
  end

  describe "notes" do
    test "create_note/2 stores only the note fields requested by the domain" do
      assert {:ok, %Note{} = note} =
               GaoNote.create_note(
                 %{
                   title: "Hello, World!",
                   content: "# Content",
                   body: "ignored",
                   body_format: "markdown",
                   created_by_id: "ignored",
                   updated_by_id: "ignored",
                   metadata: %{"ignored" => true},
                   slug: "ignored",
                   summary: "ignored",
                   status: "published",
                   visibility: "public"
                 },
                 actor()
               )

      assert note.title == "Hello, World!"
      assert note.content == "# Content"
      assert note.attachments == []
      assert %DateTime{} = note.created_at
      assert %DateTime{} = note.updated_at

      for field <- [:assets, :chunks, :creator, :description, :references, :tags] do
        refute Map.has_key?(note, field)
      end

      refute Map.has_key?(note, :body)
      refute Map.has_key?(note, :body_format)
      refute Map.has_key?(note, :created_by_id)
      refute Map.has_key?(note, :updated_by_id)
      refute Map.has_key?(note, :metadata)
      refute Map.has_key?(note, :slug)
      refute Map.has_key?(note, :summary)
      refute Map.has_key?(note, :status)
      refute Map.has_key?(note, :visibility)

      rendered = GSMLG.GaoNote.Presenter.note(note)
      assert rendered["title"] == "Hello, World!"
      assert rendered["content"] == "# Content"
      assert rendered["created_at"]
      assert rendered["updated_at"]

      refute Map.has_key?(rendered, "body")
      refute Map.has_key?(rendered, "body_format")
      refute Map.has_key?(rendered, "created_by_id")
      refute Map.has_key?(rendered, "updated_by_id")
      refute Map.has_key?(rendered, "metadata")
      refute Map.has_key?(rendered, "slug")
      refute Map.has_key?(rendered, "summary")
      refute Map.has_key?(rendered, "status")
      refute Map.has_key?(rendered, "visibility")
    end

    test "requires title and content" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               GaoNote.create_note(
                 %{title: "", content: ""},
                 nil
               )

      refute changeset.valid?

      errors = errors_on(changeset)

      assert %{title: [_ | _], content: [_ | _]} = errors
    end

    test "create, read, update, and delete note lifecycle" do
      note = note_fixture()
      note_id = note.id

      assert %Note{id: ^note_id} = GaoNote.get_note(note_id)
      assert %Note{id: ^note_id} = GaoNote.get_note!(note_id)
      assert %Note{id: ^note_id} = GaoNote.get_public_note(note_id)

      assert {:ok, %Note{} = updated} =
               GaoNote.update_note(
                 note,
                 %{
                   title: "Renamed",
                   content: "Updated content",
                   body: "ignored",
                   body_format: "ignored",
                   created_by_id: "ignored",
                   updated_by_id: "ignored",
                   metadata: %{"ignored" => true},
                   slug: "ignored",
                   summary: "ignored",
                   status: "archived",
                   visibility: "private",
                   attachments: []
                 },
                 actor("actor-2")
               )

      assert updated.title == "Renamed"
      assert updated.content == "Updated content"

      refute Map.has_key?(updated, :body)
      refute Map.has_key?(updated, :body_format)
      refute Map.has_key?(updated, :created_by_id)
      refute Map.has_key?(updated, :updated_by_id)
      refute Map.has_key?(updated, :metadata)
      refute Map.has_key?(updated, :slug)
      refute Map.has_key?(updated, :summary)
      refute Map.has_key?(updated, :status)
      refute Map.has_key?(updated, :visibility)

      assert %Note{title: "Renamed", content: "Updated content"} = GaoNote.get_note(note_id)

      assert {:ok, %Note{}} = GaoNote.delete_note(updated, actor())
      assert GaoNote.get_note(note_id) == nil
      assert GaoNote.get_public_note(note_id) == nil
    end

    test "stale deleted structs cannot restore or purge a note after another restore" do
      note = note_fixture(%{title: "Atomic recycle note"})
      assert {:ok, %Note{} = deleted} = GaoNote.delete_note(note, actor("deleter"))
      stale_deleted = GaoNote.get_deleted_note(deleted.id)

      assert {:ok, %Note{id: note_id, deleted_at: nil}} =
               GaoNote.restore_note(stale_deleted, actor("restorer"))

      assert {:error, :not_found} =
               GaoNote.permanently_delete_note(stale_deleted, actor("stale-purger"))

      assert {:error, :not_found} = GaoNote.restore_note(stale_deleted, actor("stale-restorer"))
      assert %Note{id: ^note_id, deleted_at: nil} = GaoNote.get_note(note_id)

      logs = GaoNote.list_logs(entity_type: "note", note_id: note_id)
      assert Enum.any?(logs, &match?(%Log{action: "restore", actor_id: "restorer"}, &1))
      refute Enum.any?(logs, &match?(%Log{action: "purge"}, &1))
    end

    test "list/search options return notes by search text" do
      _other = note_fixture(%{title: "Needle Other"})
      public = note_fixture(%{title: "Needle Public"})
      unlisted = note_fixture(%{title: "Needle Unlisted"})

      public_ids =
        GaoNote.list_notes()
        |> Enum.map(& &1.id)

      assert public.id in public_ids
      assert unlisted.id in public_ids
      assert length(public_ids) == 3

      assert [%Note{id: id}] = GaoNote.search_notes("Public")
      assert id == public.id
    end
  end

  describe "logs" do
    test "records create, update, and delete note actions" do
      assert {:ok, note} =
               GaoNote.create_note(
                 %{title: "Logged Note", content: "Logged content"},
                 actor("logger-1")
               )

      assert {:ok, updated} =
               GaoNote.update_note(
                 note,
                 %{
                   title: "Logged Note Updated",
                   content: "Updated content",
                   attachments: []
                 },
                 actor("logger-2")
               )

      assert {:ok, _deleted} = GaoNote.delete_note(updated, actor("logger-3"))

      assert [delete_log, update_log, create_log] =
               GaoNote.list_logs(entity_type: "note", note_id: note.id)

      assert %Log{
               action: "delete",
               actor_id: "logger-3",
               source: "admin",
               details: %{"title" => "Logged Note Updated"}
             } = delete_log

      assert %Log{
               action: "update",
               actor_id: "logger-2",
               details: %{"fields" => fields, "title" => "Logged Note Updated"}
             } = update_log

      assert Enum.sort(fields) == ["attachments", "content", "title"]

      assert %Log{
               action: "create",
               actor_id: "logger-1",
               details: %{"title" => "Logged Note"}
             } = create_log
    end
  end

  describe "mcp settings" do
    test "sets and verifies the GaoNote MCP API key" do
      api_key = GaoNote.generate_mcp_api_key()

      assert String.starts_with?(api_key, "gnmcp_")
      assert {:ok, %MCPSetting{} = setting} = GaoNote.set_mcp_api_key(api_key, actor("mcp-key"))
      assert setting.api_key_hint =~ "gnmcp_"
      refute setting.api_key_hash == api_key

      assert {:ok, %{id: "mcp-key", source: "mcp_api_key"}} =
               GaoNote.verify_mcp_api_key(api_key)

      assert :error = GaoNote.verify_mcp_api_key("wrong")
    end
  end

  describe "label_settings" do
    test "create, read, update, and delete label_setting lifecycle" do
      assert {:ok, %LabelSetting{name: "Research"} = label_setting} =
               GaoNote.create_label_setting(%{name: "  Research  ", color: "#1f6feb"})

      label_setting_id = label_setting.id
      refute Map.has_key?(label_setting, :slug)

      assert %LabelSetting{id: ^label_setting_id, name: "Research"} =
               GaoNote.get_label_setting(label_setting_id)

      assert %LabelSetting{id: ^label_setting_id, name: "Research"} =
               GaoNote.get_label_setting!(label_setting_id)

      assert [%LabelSetting{id: label_setting_id}] = GaoNote.list_label_settings()
      assert label_setting_id == label_setting.id

      assert {:ok,
              %LabelSetting{
                id: ^label_setting_id,
                color: "#0f172a",
                metadata: %{"scope" => "unit"}
              }} =
               GaoNote.update_label_setting(label_setting, %{
                 color: "#0f172a",
                 metadata: %{"scope" => "unit"}
               })

      assert %LabelSetting{id: ^label_setting_id, color: "#0f172a"} =
               GaoNote.get_label_setting(label_setting_id)

      assert {:ok, %LabelSetting{}} =
               GaoNote.delete_label_setting(GaoNote.get_label_setting!(label_setting_id))

      assert GaoNote.get_label_setting(label_setting_id) == nil
      assert GaoNote.list_label_settings() == []
    end

    test "list_notes/1 returns only notes matching a label key and value" do
      matching = note_fixture(%{title: "Matching label note"})
      other_value = note_fixture(%{title: "Other label value"})
      other_key = note_fixture(%{title: "Other label key"})

      assert {:ok, _matching} = GaoNote.set_labels(matching, ["topic=ecto"], actor())
      assert {:ok, _other_value} = GaoNote.set_labels(other_value, ["topic=phoenix"], actor())
      assert {:ok, _other_key} = GaoNote.set_labels(other_key, ["status=ecto"], actor())

      assert [%Note{id: matching_id}] = GaoNote.list_notes(label: "topic=ecto")
      assert matching_id == matching.id
    end

    test "set_labels/3 normalizes, dedupes, and filters by label" do
      with_storage_test_config(fn ->
        note =
          note_fixture(%{
            attachments: [text_attachment("labels-file", "labels.txt", "labels")]
          })

        assert {:ok, %Note{} = labeled_note} =
                 GaoNote.set_labels(note, ["  Elixir  ", "elixir", "MCP Tools"], actor())

        label_names = labeled_note.labels |> Enum.map(& &1.label_setting.name) |> Enum.sort()
        assert label_names == ["Elixir", "MCP Tools"]

        assert [%Note{id: id, attachments: [%Attachment{id: "labels-file"}]}] =
                 GaoNote.list_notes(label: "elixir")

        assert id == note.id

        assert [%LabelSetting{name: "Elixir"}, %LabelSetting{name: "MCP Tools"}] =
                 GaoNote.list_label_settings()
      end)
    end
  end

  describe "note-owned attachment reconciliation" do
    test "removes standalone attachment APIs and keeps note-scoped read APIs" do
      Code.ensure_loaded!(GSMLG.GaoNote)

      for {name, arity} <- [
            get_attachment_by_path: 2,
            get_deleted_attachment_by_path: 2,
            read_attachment_text: 2
          ] do
        assert function_exported?(GaoNote, name, arity)
      end

      for {name, arity} <- [
            list_attachments: 1,
            list_all_attachments: 1,
            get_attachment: 1,
            attach_existing_file: 4,
            upload_attachment: 4,
            update_attachment: 3,
            detach_attachment: 2,
            change_attachment: 2
          ] do
        refute function_exported?(GaoNote, name, arity)
      end
    end

    test "rejects tuple uploads and mixed Plug.Upload content sources" do
      with_storage_test_config(fn ->
        assert {:error,
                {:attachment,
                 %{code: :unsupported_content_source, id: "tuple-upload"}}} =
                 GaoNote.create_note(
                   %{
                     title: "Tuple upload",
                     content: "Body",
                     attachments: [
                       %{
                         id: "tuple-upload",
                         path: "tuple.txt",
                         mime: "text/plain",
                         upload: {"tuple.txt", "bytes"}
                       }
                     ]
                   },
                   actor()
                 )

        mixed_upload = %Plug.Upload{
          path: "/not-read-for-mixed-source",
          filename: "mixed.txt",
          content_type: "text/plain"
        }

        assert {:error,
                {:attachment,
                 %{code: :multiple_content_sources, id: "mixed-upload"}}} =
                 GaoNote.create_note(
                   %{
                     title: "Mixed upload",
                     content: "Body",
                     attachments: [
                       %{
                         id: "mixed-upload",
                         path: "mixed.txt",
                         mime: "text/plain",
                         content: "content",
                         upload: mixed_upload
                       }
                     ]
                   },
                   actor()
                 )

        refute_received {:s3_put, _path, _body}
        assert Repo.aggregate(StorageFile, :count) == 0
      end)
    end

    @tag :tmp_dir
    test "creates a trusted Plug.Upload and ignores its spoofed browser MIME", %{
      tmp_dir: tmp_dir
    } do
      with_storage_test_config(fn ->
        upload =
          plug_upload(
            tmp_dir,
            "trusted.txt",
            "trusted upload bytes",
            "application/x-spoofed"
          )

        assert {:ok,
                %Note{
                  attachments: [
                    %Attachment{
                      id: "trusted-upload",
                      path: "./trusted.txt",
                      mime: "text/plain",
                      storage_file:
                        %StorageFile{
                          type: "gao_note_attachment",
                          filename: "trusted.txt",
                          content_type: "text/plain",
                          variants: %{}
                        }
                    }
                  ]
                }} =
                 GaoNote.create_note(
                   %{
                     title: "Trusted upload",
                     content: "Body",
                     attachments: [
                       %{
                         id: "trusted-upload",
                         path: "trusted.txt",
                         mime: "text/plain",
                         upload: upload
                       }
                     ]
                   },
                   actor()
                 )

        assert {:ok, "trusted upload bytes"} = File.read(upload.path)
      end)
    end

    @tag :tmp_dir
    test "replaces one attachment from Plug.Upload without touching retained storage", %{
      tmp_dir: tmp_dir
    } do
      with_storage_test_config(fn ->
        note =
          note_fixture(%{
            attachments: [
              text_attachment("plug-replace", "replace.txt", "old bytes"),
              text_attachment("plug-retain", "retain.txt", "retained bytes")
            ]
          })

        replaced = attachment_by_id(note, "plug-replace")
        retained = attachment_by_id(note, "plug-retain")
        upload = plug_upload(tmp_dir, "replace.txt", "new upload bytes", "text/html")
        flush_storage_messages()

        Oban.Testing.with_testing_mode(:manual, fn ->
          assert {:ok, %Note{} = updated} =
                   GaoNote.update_note(
                     note,
                     %{
                       attachments: [
                         %{
                           id: "plug-replace",
                           path: "replace.txt",
                           mime: "text/plain",
                           upload: upload
                         },
                         retained_attachment(retained)
                       ]
                     },
                     actor()
                   )

          replacement = attachment_by_id(updated, "plug-replace")
          retained_after = attachment_by_id(updated, "plug-retain")

          refute replacement.storage_file_id == replaced.storage_file_id
          assert retained_after.storage_file_id == retained.storage_file_id

          assert_enqueued(
            worker: StorageFilePurgeWorker,
            args: %{storage_file_id: replaced.storage_file_id}
          )

          assert [] =
                   all_enqueued(
                     worker: StorageFilePurgeWorker,
                     args: %{storage_file_id: retained.storage_file_id}
                   )
        end)

        assert %StorageFile{status: "active"} = Storage.get(retained.storage_file_id)
        refute_received {:s3_delete, _path}
        assert {:ok, "new upload bytes"} = File.read(upload.path)
      end)
    end

    @tag :tmp_dir
    test "rejects Plug.Upload MIME mismatch and compensates staging", %{tmp_dir: tmp_dir} do
      with_storage_test_config(fn ->
        upload =
          plug_upload(
            tmp_dir,
            "mismatch.txt",
            "plain upload bytes",
            "application/json"
          )

        assert {:error,
                {:attachment,
                 %{
                   code: :mime_mismatch,
                   id: "plug-mismatch",
                   submitted: "application/json",
                   detected: "text/plain"
                 }}} =
                 GaoNote.create_note(
                   %{
                     title: "Upload mismatch",
                     content: "Body",
                     attachments: [
                       %{
                         id: "plug-mismatch",
                         path: "mismatch.txt",
                         mime: "application/json",
                         upload: upload
                       }
                     ]
                   },
                   actor()
                 )

        assert Repo.aggregate(StorageFile, :count) == 0
        assert_receive {:s3_delete, _path}
        assert {:ok, "plain upload bytes"} = File.read(upload.path)
      end)
    end

    @tag :tmp_dir
    test "accepts a zero-byte Plug.Upload as empty text", %{tmp_dir: tmp_dir} do
      with_storage_test_config(fn ->
        upload = plug_upload(tmp_dir, "empty.txt", "", "application/octet-stream")

        assert {:ok,
                %Note{
                  id: note_id,
                  attachments: [
                    %Attachment{
                      id: "empty-upload",
                      storage_file: %StorageFile{size: 0, content_type: "text/plain"}
                    }
                  ]
                }} =
                 GaoNote.create_note(
                   %{
                     title: "Empty upload",
                     content: "Body",
                     attachments: [
                       %{
                         id: "empty-upload",
                         path: "empty.txt",
                         mime: "text/plain",
                         upload: upload
                       }
                     ]
                   },
                   actor()
                 )

        flush_storage_messages()
        assert {:ok, ""} = GaoNote.read_attachment_text(note_id, "empty-upload")
        refute_received {:s3_get, _path, _range}
        assert {:ok, ""} = File.read(upload.path)
      end)
    end

    @tag :tmp_dir
    test "transaction failure compensates a staged Plug.Upload", %{tmp_dir: tmp_dir} do
      with_storage_test_config(fn ->
        upload = plug_upload(tmp_dir, "rollback.txt", "rollback upload", "text/plain")

        assert {:error, %Ecto.Changeset{} = changeset} =
                 GaoNote.create_note(
                   %{
                     title: "",
                     content: "Body",
                     attachments: [
                       %{
                         id: "plug-rollback",
                         path: "rollback.txt",
                         mime: "text/plain",
                         upload: upload
                       }
                     ]
                   },
                   actor()
                 )

        refute changeset.valid?
        assert Repo.aggregate(StorageFile, :count) == 0
        assert Repo.get(Attachment, "plug-rollback") == nil
        assert_receive {:s3_delete, _path}
        assert {:ok, "rollback upload"} = File.read(upload.path)
      end)
    end

    @tag :tmp_dir
    test "Plug.Upload validation failure does not modify the caller temp file", %{
      tmp_dir: tmp_dir
    } do
      with_storage_test_config(fn ->
        upload = plug_upload(tmp_dir, "invalid.txt", "caller-owned", "text/plain")

        assert {:error,
                {:attachment_input,
                 %{
                   code: :invalid,
                   index: 0,
                   changeset: %Ecto.Changeset{}
                 }}} =
                 GaoNote.create_note(
                   %{
                     title: "Invalid upload",
                     content: "Body",
                     attachments: [
                       %{
                         id: "invalid-upload",
                         path: "../invalid.txt",
                         mime: "text/plain",
                         upload: upload
                       }
                     ]
                   },
                   actor()
                 )

        refute_received {:s3_put, _path, _body}
        assert Repo.aggregate(StorageFile, :count) == 0
        assert {:ok, "caller-owned"} = File.read(upload.path)
      end)
    end

    @tag :tmp_dir
    test "outer transaction rejects Plug.Upload before staging or note mutation", %{
      tmp_dir: tmp_dir
    } do
      with_storage_test_config(fn ->
        upload = plug_upload(tmp_dir, "outer.txt", "outer upload", "text/plain")
        outer_actor = actor("outer-upload-actor")
        title = unique_title("Outer Plug.Upload")

        assert {:ok, :outer_committed} =
                 Repo.transaction(fn ->
                   assert Repo.in_transaction?()

                   assert {:error,
                           {:attachments,
                            %{code: :external_transaction_not_supported}}} =
                            GaoNote.create_note(
                              %{
                                title: title,
                                content: "Body",
                                attachments: [
                                  %{
                                    id: "outer-upload",
                                    path: "outer.txt",
                                    mime: "text/plain",
                                    upload: upload
                                  }
                                ]
                              },
                              outer_actor
                            )

                   assert Repo.get_by(Note, title: title) == nil
                   assert Repo.aggregate(StorageFile, :count) == 0
                   :outer_committed
                 end)

        refute_received {:s3_put, _path, _body}
        assert Repo.get_by(Note, title: title) == nil
        assert Repo.get(Attachment, "outer-upload") == nil
        assert {:ok, "outer upload"} = File.read(upload.path)
      end)
    end

    test "outer transaction rejects Base64 replacement before staging or mutation" do
      with_storage_test_config(fn ->
        note =
          note_fixture(%{
            title: "Original Base64 note",
            attachments: [text_attachment("outer-base64", "base64.txt", "old bytes")]
          })

        original = attachment_by_id(note, "outer-base64")
        outer_actor = actor("outer-base64-actor")
        flush_storage_messages()

        assert {:ok, :outer_committed} =
                 Repo.transaction(fn ->
                   assert Repo.in_transaction?()

                   assert {:error,
                           {:attachments,
                            %{code: :external_transaction_not_supported}}} =
                            GaoNote.update_note(
                              note,
                              %{
                                title: "Must not persist",
                                attachments: [
                                  %{
                                    id: "outer-base64",
                                    path: "base64.txt",
                                    mime: "text/plain",
                                    content_base64: Base.encode64("new bytes")
                                  }
                                ]
                              },
                              outer_actor
                            )

                   assert %Note{title: "Original Base64 note"} = GaoNote.get_note(note.id)
                   :outer_committed
                 end)

        refute_received {:s3_put, _path, _body}
        assert Repo.aggregate(StorageFile, :count) == 1
        assert %Note{title: "Original Base64 note"} = GaoNote.get_note(note.id)

        assert %Attachment{storage_file_id: storage_file_id} =
                 attachment_by_id(GaoNote.get_note(note.id), "outer-base64")

        assert storage_file_id == original.storage_file_id
        assert %StorageFile{status: "active"} = Storage.get(original.storage_file_id)
      end)
    end

    test "creates text and Base64 attachments with verified metadata" do
      with_storage_test_config(fn ->
        png = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>

        assert {:ok, %Note{attachments: attachments} = note} =
                 GaoNote.create_note(
                   %{
                     title: "Attachment note",
                     content: "Body",
                     attachments: [
                       text_attachment("readme", "docs/readme.txt", "hello"),
                       %{
                         id: "pixel",
                         path: "images/pixel.png",
                         mime: "image/png",
                         content_base64: Base.encode64(png)
                       }
                     ]
                   },
                   actor("attachment-creator")
                 )

        assert [
                 %Attachment{
                   id: "pixel",
                   path: "./images/pixel.png",
                   mime: "image/png",
                   storage_file: %StorageFile{
                     type: "gao_note_attachment",
                     content_type: "image/png",
                     variants: %{}
                   }
                 },
                 %Attachment{
                   id: "readme",
                   path: "./docs/readme.txt",
                   mime: "text/plain",
                   storage_file: %StorageFile{
                     type: "gao_note_attachment",
                     content_type: "text/plain",
                     variants: %{}
                   }
                 }
               ] = Enum.sort_by(attachments, & &1.id)

        assert Enum.all?(attachments, &(&1.storage_file.tenant == note.id))
        assert %Note{attachments: [_, _], labels: []} = GaoNote.get_note(note.id)
        assert %Note{attachments: [_, _]} = Enum.find(GaoNote.list_notes(), &(&1.id == note.id))
        assert %Attachment{id: "readme"} = attachment_by_id(GaoNote.get_note(note.id), "readme")
      end)
    end

    test "rejects MIME mismatch and purges the staged file" do
      with_storage_test_config(fn ->
        assert {:error,
                {:attachment,
                 %{
                   code: :mime_mismatch,
                   id: "mime-mismatch",
                   submitted: "application/json",
                   detected: "text/plain"
                 }}} =
                 GaoNote.create_note(
                   %{
                     title: "MIME mismatch",
                     content: "Body",
                     attachments: [
                       %{
                         id: "mime-mismatch",
                         path: "data.txt",
                         mime: "application/json",
                         content: "plain text"
                       }
                     ]
                   },
                   actor()
                 )

        assert Repo.aggregate(StorageFile, :count) == 0
        assert_receive {:s3_delete, _path}
      end)
    end

    test "rejects a new attachment without content" do
      with_storage_test_config(fn ->
        assert {:error,
                {:attachment, %{code: :content_required, id: "missing-content"}}} =
                 GaoNote.create_note(
                   %{
                     title: "Missing content",
                     content: "Body",
                     attachments: [
                       %{
                         id: "missing-content",
                         path: "missing.txt",
                         mime: "text/plain"
                       }
                     ]
                   },
                   actor()
                 )

        refute_received {:s3_put, _path, _body}
        assert Repo.aggregate(StorageFile, :count) == 0
      end)
    end

    test "retained and replacement MIME mismatches preserve the existing attachment" do
      with_storage_test_config(fn ->
        note =
          note_fixture(%{
            attachments: [text_attachment("mime-retain", "mime.txt", "original")]
          })

        original = attachment_by_id(note, "mime-retain")
        flush_storage_messages()

        assert {:error,
                {:attachment,
                 %{
                   code: :retained_mime_mismatch,
                   id: "mime-retain",
                   submitted: "application/json",
                   persisted: "text/plain"
                 }}} =
                 GaoNote.update_note(
                   note,
                   %{
                     attachments: [
                       %{
                         id: "mime-retain",
                         path: "mime.txt",
                         mime: "application/json"
                       }
                     ]
                   },
                   actor()
                 )

        refute_received {:s3_put, _path, _body}

        assert {:error,
                {:attachment,
                 %{
                   code: :mime_mismatch,
                   id: "mime-retain",
                   submitted: "application/json",
                   detected: "text/plain"
                 }}} =
                 GaoNote.update_note(
                   note,
                   %{
                     attachments: [
                       %{
                         id: "mime-retain",
                         path: "mime.txt",
                         mime: "application/json",
                         content: "replacement"
                       }
                     ]
                   },
                   actor()
                 )

        assert_receive {:s3_delete, _path}
        assert Repo.aggregate(StorageFile, :count) == 1

        assert %Attachment{storage_file_id: storage_file_id, mime: "text/plain"} =
                 attachment_by_id(GaoNote.get_note(note.id), "mime-retain")

        assert storage_file_id == original.storage_file_id
        assert %StorageFile{status: "active"} = Storage.get(original.storage_file_id)
      end)
    end

    test "a mid-batch staging failure purges every earlier staged file" do
      with_storage_test_config(fn ->
        assert {:error,
                {:attachment,
                 %{code: :mime_mismatch, id: "batch-second"}}} =
                 GaoNote.create_note(
                   %{
                     title: "Mid-batch failure",
                     content: "Body",
                     attachments: [
                       text_attachment("batch-first", "first.txt", "first"),
                       %{
                         id: "batch-second",
                         path: "second.txt",
                         mime: "application/json",
                         content: "second"
                       }
                     ]
                   },
                   actor()
                 )

        assert Repo.aggregate(StorageFile, :count) == 0
        assert_receive {:s3_delete, _first_path}
        assert_receive {:s3_delete, _second_path}
      end)
    end

    test "rejects duplicate IDs and canonical paths before staging" do
      with_storage_test_config(fn ->
        duplicate_id = [
          text_attachment("duplicate", "one.txt", "one"),
          text_attachment("duplicate", "two.txt", "two")
        ]

        assert {:error, {:attachments, %{code: :duplicate_id, id: "duplicate"}}} =
                 GaoNote.create_note(
                   %{title: "Duplicate ID", content: "Body", attachments: duplicate_id},
                   actor()
                 )

        duplicate_path = [
          text_attachment("first", "docs/file.txt", "one"),
          text_attachment("second", "./docs//file.txt", "two")
        ]

        assert {:error,
                {:attachments, %{code: :duplicate_path, path: "./docs/file.txt"}}} =
                 GaoNote.create_note(
                   %{title: "Duplicate path", content: "Body", attachments: duplicate_path},
                   actor()
                 )

        refute_received {:s3_put, _path, _body}
      end)
    end

    test "enforces global ID ownership and rejects cross-note moves" do
      with_storage_test_config(fn ->
        owner =
          note_fixture(%{
            title: "Owner",
            attachments: [text_attachment("global-id", "owner.txt", "owner")]
          })

        assert {:error,
                {:attachment,
                 %{
                   code: :owned_by_another_note,
                   id: "global-id",
                   owner_note_id: owner_id
                 }}} =
                 GaoNote.create_note(
                   %{
                     title: "Duplicate owner",
                     content: "Body",
                     attachments: [text_attachment("global-id", "copy.txt", "copy")]
                   },
                   actor()
                 )

        assert owner_id == owner.id

        other = note_fixture(%{title: "Other"})

        assert {:error,
                {:attachment,
                 %{code: :owned_by_another_note, id: "global-id"}}} =
                 GaoNote.update_note(
                   other,
                   %{
                     attachments: [
                       %{id: "global-id", path: "moved.txt", mime: "text/plain"}
                     ]
                   },
                   actor()
                 )

        assert %Attachment{note_id: owner_id} =
                 attachment_by_id(GaoNote.get_note(owner.id), "global-id")

        assert owner_id == owner.id
      end)
    end

    test "advisory locks serialize overlapping global ID claims and compensate the loser" do
      with_storage_test_config(fn ->
        race_actor = actor("race-actor")

        claims =
          for {title, path, bytes} <- [
                {"First claim", "first.txt", "block-for-first-claim"},
                {"Second claim", "second.txt", "block-for-second-claim"}
              ] do
            Task.async(fn ->
              GaoNote.create_note(
                %{
                  title: title,
                  content: "Body",
                  attachments: [
                    text_attachment("raced-global-id", path, bytes)
                  ]
                },
                race_actor
              )
            end)
          end

        assert_receive {:s3_put_blocked, first_request_pid, _path}
        assert_receive {:s3_put_blocked, second_request_pid, _path}

        send(first_request_pid, :release_s3_put)
        send(second_request_pid, :release_s3_put)

        results = Task.await_many(claims, 5_000)

        assert Enum.count(results, &match?({:ok, %Note{}}, &1)) == 1

        assert Enum.count(
                 results,
                 &match?(
                   {:error,
                    {:attachment,
                     %{code: :owned_by_another_note, id: "raced-global-id"}}},
                   &1
                 )
               ) == 1

        winner_result = Enum.find(results, &match?({:ok, %Note{}}, &1))

        loser_result =
          Enum.find(
            results,
            &match?(
              {:error,
               {:attachment,
                %{code: :owned_by_another_note, id: "raced-global-id"}}},
              &1
            )
          )

        assert {:ok, %Note{} = winner} = winner_result

        assert {:error,
                {:attachment,
                 %{
                   code: :owned_by_another_note,
                   id: "raced-global-id",
                   owner_note_id: winner_id
        }}} = loser_result

        assert winner_id == winner.id

        assert %Attachment{note_id: ^winner_id} =
                 attachment_by_id(GaoNote.get_note(winner_id), "raced-global-id")

        assert Repo.aggregate(StorageFile, :count) == 1
        assert_receive {:s3_delete, _loser_path}
      end)
    end

    test "a concurrent metadata update invalidates the complete attachment snapshot" do
      with_storage_test_config(fn ->
        note =
          note_fixture(%{
            attachments: [text_attachment("stale-plan", "before.txt", "original")]
          })

        original = attachment_by_id(note, "stale-plan")
        stale_actor = actor("stale-actor")

        stale_update =
          Task.async(fn ->
            GaoNote.update_note(
              note,
              %{
                attachments: [
                  text_attachment(
                    "stale-plan",
                    "stale.txt",
                    "block-for-stale-plan"
                  )
                ]
              },
              stale_actor
            )
          end)

        assert_receive {:s3_put_blocked, request_pid, _path}

        assert {:ok, %Note{} = concurrent} =
                 GaoNote.update_note(
                   note,
                   %{
                     attachments: [
                       retained_attachment(original, %{
                         path: "concurrent.txt",
                         description: "concurrent metadata"
                       })
                     ]
                   },
                   stale_actor
                 )

        send(request_pid, :release_s3_put)

        assert {:error, {:attachments, %{code: :stale}}} =
                 Task.await(stale_update, 5_000)

        assert %Attachment{
                 path: "./concurrent.txt",
                 description: "concurrent metadata",
                 storage_file_id: original_storage_file_id
               } = attachment_by_id(concurrent, "stale-plan")

        assert original_storage_file_id == original.storage_file_id

        assert %Attachment{path: "./concurrent.txt"} =
                 attachment_by_id(GaoNote.get_note(note.id), "stale-plan")

        assert Repo.aggregate(StorageFile, :count) == 1
        assert_receive {:s3_delete, _stale_path}
      end)
    end

    test "requires a full attachment list on update" do
      note = note_fixture()

      assert {:error, {:attachments, %{code: :required}}} =
               GaoNote.update_note(note, %{title: "Missing list"}, actor())

      assert {:error, {:attachments, %{code: :must_be_a_list}}} =
               GaoNote.update_note(note, %{attachments: %{}}, actor())
    end

    test "retains bytes while updating attachment metadata" do
      with_storage_test_config(fn ->
        note =
          note_fixture(%{
            attachments: [text_attachment("retained", "old.txt", "original")]
          })

        attachment = attachment_by_id(note, "retained")
        storage_file_id = attachment.storage_file_id
        flush_storage_messages()

        assert {:ok, %Note{} = updated} =
                 GaoNote.update_note(
                   note,
                   %{
                     attachments: [
                       retained_attachment(attachment, %{
                         path: "renamed.txt",
                         description: "renamed"
                       })
                     ]
                   },
                   actor()
                 )

        assert %Attachment{
                 storage_file_id: ^storage_file_id,
                 path: "./renamed.txt",
                 description: "renamed"
               } = attachment_by_id(updated, "retained")

        refute_received {:s3_put, _path, _body}
        refute_received {:s3_delete, _path}
      end)
    end

    test "atomically swaps retained attachment paths" do
      with_storage_test_config(fn ->
        note =
          note_fixture(%{
            attachments: [
              text_attachment("swap-a", "a.txt", "A"),
              text_attachment("swap-b", "b.txt", "B")
            ]
          })

        a = attachment_by_id(note, "swap-a")
        b = attachment_by_id(note, "swap-b")
        flush_storage_messages()

        assert {:ok, %Note{} = swapped} =
                 GaoNote.update_note(
                   note,
                   %{
                     attachments: [
                       retained_attachment(a, %{path: "b.txt"}),
                       retained_attachment(b, %{path: "a.txt"})
                     ]
                   },
                   actor()
                 )

        assert %Attachment{path: "./b.txt", storage_file_id: a_storage_file_id} =
                 attachment_by_id(swapped, "swap-a")

        assert %Attachment{path: "./a.txt", storage_file_id: b_storage_file_id} =
                 attachment_by_id(swapped, "swap-b")

        assert a_storage_file_id == a.storage_file_id
        assert b_storage_file_id == b.storage_file_id
        refute_received {:s3_put, _path, _body}
        refute_received {:s3_delete, _path}
      end)
    end

    test "replaces bytes and transactionally schedules old storage cleanup" do
      with_storage_test_config(fn ->
        note =
          note_fixture(%{
            attachments: [text_attachment("replace", "replace.txt", "old")]
          })

        old_attachment = attachment_by_id(note, "replace")
        old_storage_file_id = old_attachment.storage_file_id
        flush_storage_messages()

        Oban.Testing.with_testing_mode(:manual, fn ->
          assert {:ok, %Note{} = updated} =
                   GaoNote.update_note(
                     note,
                     %{
                       attachments: [
                         text_attachment("replace", "replace.txt", "new")
                       ]
                     },
                     actor()
                   )

          replacement = attachment_by_id(updated, "replace")
          refute replacement.storage_file_id == old_storage_file_id

          assert_enqueued(
            worker: StorageFilePurgeWorker,
            args: %{storage_file_id: old_storage_file_id}
          )
        end)

        assert %StorageFile{status: "active"} = Storage.get(old_storage_file_id)
        assert_receive {:s3_put, _path, "new"}
        refute_received {:s3_delete, _path}
      end)
    end

    test "removes missing attachments and schedules their storage cleanup" do
      with_storage_test_config(fn ->
        note =
          note_fixture(%{
            attachments: [
              text_attachment("keep", "keep.txt", "keep"),
              text_attachment("remove", "remove.txt", "remove")
            ]
          })

        kept = attachment_by_id(note, "keep")
        removed = attachment_by_id(note, "remove")

        Oban.Testing.with_testing_mode(:manual, fn ->
          assert {:ok, %Note{attachments: [%Attachment{id: "keep"}]}} =
                   GaoNote.update_note(
                     note,
                     %{attachments: [retained_attachment(kept)]},
                     actor()
                   )

          assert_enqueued(
            worker: StorageFilePurgeWorker,
            args: %{storage_file_id: removed.storage_file_id}
          )
        end)

        assert Repo.get(Attachment, "remove") == nil

        assert %Attachment{storage_file_id: kept_storage_file_id} =
                 attachment_by_id(GaoNote.get_note(note.id), "keep")

        assert kept_storage_file_id == kept.storage_file_id
      end)
    end

    test "an outer rollback removes the transactionally inserted cleanup job" do
      with_storage_test_config(fn ->
        note =
          note_fixture(%{
            attachments: [
              text_attachment("rollback-keep", "keep.txt", "keep"),
              text_attachment("rollback-remove", "remove.txt", "remove")
            ]
          })

        kept = attachment_by_id(note, "rollback-keep")
        removed = attachment_by_id(note, "rollback-remove")

        Oban.Testing.with_testing_mode(:manual, fn ->
          assert {:error, :deliberate_rollback} =
                   Repo.transaction(fn ->
                     assert {:ok, %Note{attachments: [%Attachment{id: "rollback-keep"}]}} =
                              GaoNote.update_note(
                                note,
                                %{attachments: [retained_attachment(kept)]},
                                actor()
                              )

                     assert_enqueued(
                       worker: StorageFilePurgeWorker,
                       args: %{storage_file_id: removed.storage_file_id}
                     )

                     Repo.rollback(:deliberate_rollback)
                   end)

          assert [] =
                   all_enqueued(
                     worker: StorageFilePurgeWorker,
                     args: %{storage_file_id: removed.storage_file_id}
                   )
        end)

        assert %Note{attachments: rolled_back_attachments} = GaoNote.get_note(note.id)

        assert %Attachment{id: "rollback-keep"} =
                 Enum.find(rolled_back_attachments, &(&1.id == "rollback-keep"))

        assert %Attachment{id: "rollback-remove"} =
                 Enum.find(rolled_back_attachments, &(&1.id == "rollback-remove"))

        assert %StorageFile{status: "active"} = Storage.get(removed.storage_file_id)
      end)
    end

    test "purges staged files after a database transaction failure" do
      with_storage_test_config(fn ->
        assert {:error, %Ecto.Changeset{} = changeset} =
                 GaoNote.create_note(
                   %{
                     title: "",
                     content: "Body",
                     attachments: [
                       text_attachment("rollback", "rollback.txt", "rollback bytes")
                     ]
                   },
                   actor()
                 )

        refute changeset.valid?
        assert Repo.aggregate(StorageFile, :count) == 0
        assert Repo.get(Attachment, "rollback") == nil
        assert_receive {:s3_delete, _path}
      end)
    end

    test "a failed replacement transaction cleans staging and preserves prior rows and files" do
      with_storage_test_config(fn ->
        note =
          note_fixture(%{
            title: "Original title",
            attachments: [text_attachment("rollback-existing", "existing.txt", "old")]
          })

        original = attachment_by_id(note, "rollback-existing")
        flush_storage_messages()

        assert {:error, %Ecto.Changeset{} = changeset} =
                 GaoNote.update_note(
                   note,
                   %{
                     title: "",
                     attachments: [
                       text_attachment(
                         "rollback-existing",
                         "existing.txt",
                         "new staged bytes"
                       )
                     ]
                   },
                   actor()
                 )

        refute changeset.valid?
        assert_receive {:s3_delete, _staged_path}
        assert Repo.aggregate(StorageFile, :count) == 1

        assert %Note{title: "Original title"} = GaoNote.get_note(note.id)

        assert %Attachment{storage_file_id: storage_file_id} =
                 attachment_by_id(GaoNote.get_note(note.id), "rollback-existing")

        assert storage_file_id == original.storage_file_id
        assert %StorageFile{status: "active"} = Storage.get(original.storage_file_id)
      end)
    end

    @tag :tmp_dir
    test "transaction exceptions preserve caller Plug.Upload after staged-file cleanup", %{
      tmp_dir: tmp_dir
    } do
      with_storage_test_config(fn ->
        upload =
          plug_upload(
            tmp_dir,
            "exception.txt",
            "exception upload",
            "application/x-spoofed"
          )

        error =
          catch_error(
            GaoNote.create_note(
              %{
                title: <<"invalid", 0, "title">>,
                content: "Body",
                attachments: [
                  %{
                    id: "exception-cleanup",
                    path: "exception.txt",
                    mime: "text/plain",
                    upload: upload
                  }
                ]
              },
              actor()
            )
          )

        assert is_exception(error)
        assert Repo.aggregate(StorageFile, :count) == 0
        assert Repo.get(Attachment, "exception-cleanup") == nil
        assert_receive {:s3_delete, _staged_path}
        assert {:ok, "exception upload"} = File.read(upload.path)
      end)
    end

    test "soft delete and restore retain attachments; permanent delete enqueues cleanup" do
      with_storage_test_config(fn ->
        note =
          note_fixture(%{
            attachments: [text_attachment("lifecycle", "docs/lifecycle.txt", "kept")]
          })

        attachment = attachment_by_id(note, "lifecycle")

        assert {:ok, %Note{id: note_id}} = GaoNote.delete_note(note, actor())
        assert GaoNote.get_note(note_id) == nil

        assert %Note{attachments: [%Attachment{id: "lifecycle"}]} =
                 deleted_note = GaoNote.get_deleted_note(note_id)

        assert %StorageFile{status: "active"} = Storage.get(attachment.storage_file_id)
        assert {:error, :not_found} = GaoNote.get_attachment_by_path(note_id, "docs/lifecycle.txt")

        assert {:ok, %Attachment{id: "lifecycle"}} =
                 GaoNote.get_deleted_attachment_by_path(note_id, "./docs/lifecycle.txt")

        assert {:ok, %Note{id: ^note_id}} = GaoNote.restore_note(deleted_note, actor())

        assert %Note{attachments: [%Attachment{id: "lifecycle"}]} =
                 restored = GaoNote.get_note(note_id)

        assert {:ok, %Attachment{id: "lifecycle"}} =
                 GaoNote.get_attachment_by_path(note_id, "docs/lifecycle.txt")

        assert {:ok, %Note{}} = GaoNote.delete_note(restored, actor())
        recycled = GaoNote.get_deleted_note(note_id)

        Oban.Testing.with_testing_mode(:manual, fn ->
          assert {:ok, %Note{id: ^note_id}} =
                   GaoNote.permanently_delete_note(recycled, actor())

          assert_enqueued(
            worker: StorageFilePurgeWorker,
            args: %{storage_file_id: attachment.storage_file_id}
          )
        end)

        assert GaoNote.get_deleted_note(note_id) == nil
        assert Repo.get(Attachment, "lifecycle") == nil
        assert %StorageFile{status: "active"} = Storage.get(attachment.storage_file_id)
      end)
    end

    test "lazily reads UTF-8 and zero-byte text with precise input and content errors" do
      with_storage_test_config(fn ->
        invalid_bytes = <<255>>
        nul_bytes = <<0>>

        note =
          note_fixture(%{
            attachments: [
              text_attachment("text-read", "text.txt", "lazy text"),
              text_attachment("empty-read", "empty.txt", ""),
              %{
                id: "invalid-read",
                path: "invalid.bin",
                mime: "application/octet-stream",
                content_base64: Base.encode64(invalid_bytes)
              },
              %{
                id: "nul-read",
                path: "nul.bin",
                mime: "application/octet-stream",
                content_base64: Base.encode64(nul_bytes)
              }
            ]
          })

        Application.put_env(:gsmlg_storage, :gao_note_test_object, "lazy text")
        assert {:ok, "lazy text"} = GaoNote.read_attachment_text(note.id, "text-read")
        assert_receive {:s3_get, _path, ["bytes=0-8"]}

        flush_storage_messages()
        assert {:ok, ""} = GaoNote.read_attachment_text(note.id, "empty-read")
        refute_received {:s3_get, _path, _range}

        Application.put_env(:gsmlg_storage, :gao_note_test_object, invalid_bytes)
        assert {:error, :invalid_text} = GaoNote.read_attachment_text(note.id, "invalid-read")

        Application.put_env(:gsmlg_storage, :gao_note_test_object, nul_bytes)
        assert {:error, :invalid_text} = GaoNote.read_attachment_text(note.id, "nul-read")

        other = note_fixture(%{title: "Other note"})
        assert {:error, :not_found} = GaoNote.read_attachment_text(note.id, "missing")
        assert {:error, :not_found} = GaoNote.read_attachment_text(other.id, "text-read")
        assert {:error, :not_found} = GaoNote.read_attachment_text("not-a-uuid", "text-read")

        for malformed_id <- [nil, "", "  ", <<255>>, <<"bad", 0, "id">>] do
          assert {:error, :invalid_attachment_id} =
                   GaoNote.read_attachment_text(note.id, malformed_id)
        end
      end)
    end
  end

  defp actor(id \\ "actor-1") do
    unless Repo.get(User, id) do
      Repo.insert!(%User{
        id: id,
        username: id,
        email: "#{id}@example.test",
        password: "test"
      })
    end

    %{id: id}
  end

  defp note_fixture(attrs \\ %{}) do
    attrs =
      Map.merge(
        %{title: unique_title("Note"), content: "Content"},
        attrs
      )

    assert {:ok, note} = GaoNote.create_note(attrs, actor())
    note
  end

  defp with_storage_test_config(fun) do
    keys = [
      :allowed_types,
      :gao_note_test_object,
      :gao_note_test_pid,
      :s3_access_key_id,
      :s3_bucket,
      :s3_endpoint,
      :s3_secret_access_key
    ]

    original = Map.new(keys, &{&1, Application.fetch_env(:gsmlg_storage, &1)})
    port = available_port()
    {:ok, s3_stub} = Bandit.start_link(plug: S3Stub, port: port, startup_log: false)

    Application.put_env(:gsmlg_storage, :allowed_types, %{"gao_note_attachment" => :any})
    Application.put_env(:gsmlg_storage, :gao_note_test_object, "")
    Application.put_env(:gsmlg_storage, :gao_note_test_pid, self())
    Application.put_env(:gsmlg_storage, :s3_access_key_id, "test-access-key")
    Application.put_env(:gsmlg_storage, :s3_bucket, "gsmlg-storage")
    Application.put_env(:gsmlg_storage, :s3_endpoint, "http://127.0.0.1:#{port}")
    Application.put_env(:gsmlg_storage, :s3_secret_access_key, "test-secret-key")

    try do
      fun.()
    after
      Enum.each(original, fn
        {key, {:ok, value}} -> Application.put_env(:gsmlg_storage, key, value)
        {key, :error} -> Application.delete_env(:gsmlg_storage, key)
      end)

      GenServer.stop(s3_stub)
    end
  end

  defp text_attachment(id, path, content) do
    %{id: id, path: path, mime: "text/plain", content: content}
  end

  defp retained_attachment(%Attachment{} = attachment, attrs \\ %{}) do
    Map.merge(
      %{
        id: attachment.id,
        path: attachment.path,
        mime: attachment.mime,
        description: attachment.description
      },
      attrs
    )
  end

  defp plug_upload(tmp_dir, filename, bytes, content_type) do
    path =
      Path.join(
        tmp_dir,
        "#{System.unique_integer([:positive, :monotonic])}-#{filename}"
      )

    File.write!(path, bytes)

    %Plug.Upload{
      path: path,
      filename: filename,
      content_type: content_type
    }
  end

  defp attachment_by_id(%Note{} = note, id) do
    Enum.find(note.attachments, &(&1.id == id))
  end

  defp flush_storage_messages do
    receive do
      {:s3_put, _path, _body} -> flush_storage_messages()
      {:s3_put_blocked, _pid, _path} -> flush_storage_messages()
      {:s3_get, _path, _range} -> flush_storage_messages()
      {:s3_delete, _path} -> flush_storage_messages()
    after
      0 -> :ok
    end
  end

  defp available_port do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp unique_title(prefix) do
    "#{prefix} #{System.unique_integer([:positive])}"
  end
end
