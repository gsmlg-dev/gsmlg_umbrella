defmodule GSMLG.Web.GaoNoteAttachmentContentControllerTest do
  use GSMLG.Web.ConnCase, async: false

  defmodule S3Stub do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    put "/*path" do
      {:ok, body, conn} = read_body(conn, "")
      notify({:s3_put, conn.request_path, body})

      if Application.get_env(:gsmlg_storage, :gao_note_http_public_fail_put, false) do
        send_resp(conn, 500, "upstream put detail")
      else
        send_resp(conn, 200, "")
      end
    end

    get "/*path" do
      ranges = Plug.Conn.get_req_header(conn, "range")
      notify({:s3_get, conn.request_path, ranges})

      object = Application.get_env(:gsmlg_storage, :gao_note_http_public_object, "")
      fail_ranges =
        Application.get_env(:gsmlg_storage, :gao_note_http_public_fail_ranges, [])

      case {ranges, List.first(ranges) in fail_ranges} do
        {_ranges, true} ->
          send_resp(conn, 500, "upstream get detail")

        {["bytes=" <> range], false} ->
          [first, last] =
            range
            |> String.split("-", parts: 2)
            |> Enum.map(&String.to_integer/1)

          body = binary_part(object, first, last - first + 1)

          conn
          |> put_resp_header("content-range", "bytes #{first}-#{last}/#{byte_size(object)}")
          |> send_resp(206, body)

        {_no_range, false} ->
          send_resp(conn, 200, object)
      end
    end

    delete "/*path" do
      notify({:s3_delete, conn.request_path})
      send_resp(conn, 204, "")
    end

    match _, do: send_resp(conn, 200, "")

    defp read_body(conn, acc) do
      case Plug.Conn.read_body(conn) do
        {:ok, body, conn} -> {:ok, acc <> body, conn}
        {:more, body, conn} -> read_body(conn, acc <> body)
      end
    end

    defp notify(message) do
      if pid = Application.get_env(:gsmlg_storage, :gao_note_http_public_pid) do
        send(pid, message)
      end
    end
  end

  defmodule ClosingAdapter do
    def send_chunked(test_pid, status, headers) do
      send(test_pid, {:send_chunked, status, headers})
      {:ok, nil, test_pid}
    end

    def chunk(test_pid, body) do
      send(test_pid, {:chunk_attempt, body})
      {:error, :closed}
    end
  end

  alias GSMLG.Accounts.User
  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.{Attachment, Label, LabelSetting, Log, Note, Presenter}
  alias GSMLG.Repo
  alias GSMLG.Storage.StorageFile

  @chunk_size 65_536
  @storage_keys [
    :allowed_types,
    :gao_note_http_public_fail_put,
    :gao_note_http_public_fail_ranges,
    :gao_note_http_public_object,
    :gao_note_http_public_pid,
    :s3_access_key_id,
    :s3_bucket,
    :s3_endpoint,
    :s3_secret_access_key
  ]

  setup %{conn: conn} do
    Repo.delete_all(Log)
    Repo.delete_all(Attachment)
    Repo.delete_all(Label)
    Repo.delete_all(LabelSetting)
    Repo.delete_all(Note)
    Repo.delete_all(StorageFile)

    original = Map.new(@storage_keys, &{&1, Application.fetch_env(:gsmlg_storage, &1)})
    port = available_port()
    {:ok, s3_stub} = Bandit.start_link(plug: S3Stub, port: port, startup_log: false)

    Application.put_env(:gsmlg_storage, :allowed_types, %{"gao_note_attachment" => :any})
    Application.put_env(:gsmlg_storage, :gao_note_http_public_fail_put, false)
    Application.put_env(:gsmlg_storage, :gao_note_http_public_fail_ranges, [])
    Application.put_env(:gsmlg_storage, :gao_note_http_public_object, "")
    Application.put_env(:gsmlg_storage, :gao_note_http_public_pid, self())
    Application.put_env(:gsmlg_storage, :s3_access_key_id, "test-access-key")
    Application.put_env(:gsmlg_storage, :s3_bucket, "gsmlg-storage")
    Application.put_env(:gsmlg_storage, :s3_endpoint, "http://127.0.0.1:#{port}")
    Application.put_env(:gsmlg_storage, :s3_secret_access_key, "test-secret-key")

    on_exit(fn ->
      Enum.each(original, fn
        {key, {:ok, value}} -> Application.put_env(:gsmlg_storage, key, value)
        {key, :error} -> Application.delete_env(:gsmlg_storage, key)
      end)

      if Process.alive?(s3_stub), do: GenServer.stop(s3_stub)
    end)

    {:ok,
     conn: put_req_header(conn, "accept", "application/json"),
     user: user_fixture("public-http-user")}
  end

  describe "authenticated aggregate writes" do
    test "create accepts nested attachments and uses the Guardian actor", %{
      conn: conn,
      user: user
    } do
      attachment_id = unique_id("http-create")
      raw_attachment = "private attachment bytes"

      conn =
        conn
        |> authenticated_conn(user)
        |> post("/api/gao_notes", %{
          "title" => "HTTP aggregate create",
          "content" => "See [attachment](./docs/input.txt)",
          "labels" => ["surface=public"],
          "attachments" => [
            %{
              "id" => attachment_id,
              "path" => "docs/input.txt",
              "mime" => "text/plain",
              "description" => "Input",
              "content" => raw_attachment
            }
          ]
        })

      assert %{"data" => created} = json_response(conn, 201)
      assert created["title"] == "HTTP aggregate create"
      assert [%{"key" => "surface", "value" => "public"}] = created["labels"]

      assert [
               %{
                 "id" => ^attachment_id,
                 "path" => "./docs/input.txt",
                 "mime" => "text/plain",
                 "description" => "Input",
                 "content_url" => content_url
               }
             ] = created["attachments"]

      assert content_url ==
               "/api/gao_notes/#{created["id"]}/attachments/docs/input.txt"

      refute Map.has_key?(created, "creator")
      refute Map.has_key?(hd(created["attachments"]), "storage_file_id")
      refute Map.has_key?(hd(created["attachments"]), "content")
      refute Jason.encode!(created) =~ raw_attachment

      assert %Note{attachments: [%Attachment{storage_file: storage_file}]} =
               GaoNote.get_note(created["id"])

      assert storage_file.uploaded_by == user.id

      assert %Log{actor_id: actor_id} =
               Repo.get_by!(Log, action: "create", note_id: created["id"])

      assert actor_id == user.id
      assert_receive {:s3_put, _path, ^raw_attachment}
    end

    test "create rejects removed and unknown top-level fields before mutation", %{
      conn: conn,
      user: user
    } do
      title = unique_id("Rejected top-level create")

      conn =
        conn
        |> authenticated_conn(user)
        |> post("/api/gao_notes", %{
          "id" => "request-controlled-id",
          "title" => title,
          "content" => "Must not be created",
          "attachments" => [
            %{
              "id" => unique_id("top-level-create"),
              "path" => "create.txt",
              "mime" => "text/plain",
              "content" => "must not upload"
            }
          ],
          "actor" => %{"id" => "request-controlled-actor"},
          "assets" => [],
          "chunks" => [],
          "creator" => "request-controlled-actor",
          "description" => "removed",
          "references" => [],
          "tags" => ["removed"]
        })

      assert %{
               "errors" => %{
                 "code" => "unknown_fields",
                 "fields" => [
                   "actor",
                   "assets",
                   "chunks",
                   "creator",
                   "description",
                   "id",
                   "references",
                   "tags"
                 ]
               }
             } = json_response(conn, 400)

      refute Repo.get_by(Note, title: title)
      assert Repo.aggregate(StorageFile, :count, :id) == 0
      assert Repo.aggregate(Log, :count, :id) == 0
      refute_received {:s3_put, _path, _body}
    end

    test "update requires and replaces the complete nested attachment list", %{
      conn: conn,
      user: user
    } do
      first_id = unique_id("first")
      second_id = unique_id("second")

      assert {:ok, note} =
               GaoNote.create_note(
                 %{
                   title: "Before replacement",
                   content: "Two attachments",
                   attachments: [
                     attachment_input(first_id, "files/first.txt", "first"),
                     attachment_input(second_id, "files/second.txt", "second")
                   ]
                 },
                 user
               )

      flush_storage_messages()

      conn =
        conn
        |> authenticated_conn(user)
        |> put("/api/gao_notes/#{note.id}", %{
          "title" => "After replacement",
          "content" => "One attachment",
          "labels" => ["state=updated"],
          "attachments" => [
            %{
              "id" => first_id,
              "path" => "files/renamed.txt",
              "mime" => "text/plain",
              "description" => "Retained"
            }
          ]
        })

      assert %{"data" => updated} = json_response(conn, 200)
      assert updated["title"] == "After replacement"
      assert [%{"id" => ^first_id, "path" => "./files/renamed.txt"}] =
               updated["attachments"]

      refute Jason.encode!(updated) =~ "storage_file_id"

      assert %Note{attachments: [%Attachment{id: ^first_id}]} = GaoNote.get_note(note.id)
      refute_received {:s3_get, _path, _ranges}
    end

    test "update rejects unknown top-level fields without mutation or storage writes", %{
      conn: conn,
      user: user
    } do
      note = note_fixture(user, %{title: "Unchanged top-level update"})
      log_count = Repo.aggregate(Log, :count, :id)

      conn =
        conn
        |> authenticated_conn(user)
        |> put("/api/gao_notes/#{note.id}", %{
          "id" => "forged-body-id",
          "title" => "Must not update",
          "content" => "Must not update",
          "attachments" => [
            %{
              "id" => unique_id("top-level-update"),
              "path" => "update.txt",
              "mime" => "text/plain",
              "content" => "must not upload"
            }
          ],
          "assets" => [],
          "chunks" => [],
          "description" => "removed",
          "references" => [],
          "tags" => ["removed"]
        })

      assert %{
               "errors" => %{
                 "code" => "unknown_fields",
                 "fields" => [
                   "assets",
                   "chunks",
                   "description",
                   "id",
                   "references",
                   "tags"
                 ]
               }
             } = json_response(conn, 400)

      assert %Note{
               title: "Unchanged top-level update",
               content: "Content",
               attachments: []
             } = GaoNote.get_note(note.id)

      assert Repo.aggregate(StorageFile, :count, :id) == 0
      assert Repo.aggregate(Log, :count, :id) == log_count
      refute_received {:s3_put, _path, _body}
    end

    test "PATCH performs the same complete attachment-list replacement", %{
      conn: conn,
      user: user
    } do
      retained_id = unique_id("patch-retained")
      removed_id = unique_id("patch-removed")

      assert {:ok, note} =
               GaoNote.create_note(
                 %{
                   title: "Before PATCH",
                   content: "Two attachments",
                   attachments: [
                     attachment_input(retained_id, "files/retained.txt", "retained"),
                     attachment_input(removed_id, "files/removed.txt", "removed")
                   ]
                 },
                 user
               )

      flush_storage_messages()

      conn =
        conn
        |> authenticated_conn(user)
        |> patch("/api/gao_notes/#{note.id}", %{
          "title" => "After PATCH",
          "content" => "One attachment",
          "attachments" => [
            %{
              "id" => retained_id,
              "path" => "files/patched.txt",
              "mime" => "text/plain",
              "description" => "Retained by PATCH"
            }
          ]
        })

      assert %{"data" => patched} = json_response(conn, 200)
      assert patched["title"] == "After PATCH"

      assert [
               %{
                 "id" => ^retained_id,
                 "path" => "./files/patched.txt",
                 "description" => "Retained by PATCH"
               }
             ] = patched["attachments"]

      assert %Note{attachments: [%Attachment{id: ^retained_id}]} =
               GaoNote.get_note(note.id)
    end

    test "multipart create rejects external upload before note or storage creation", %{
      conn: conn,
      user: user
    } do
      title = unique_id("Rejected multipart create")
      upload = multipart_upload("untrusted create bytes")

      conn =
        conn
        |> authenticated_conn(user)
        |> post("/api/gao_notes", %{
          "title" => title,
          "content" => "Must not be created",
          "attachments" => [
            %{
              "id" => unique_id("multipart-create"),
              "path" => "upload.txt",
              "mime" => "text/plain",
              "upload" => upload
            }
          ]
        })

      assert [content_type] = get_req_header(conn, "content-type")
      assert String.starts_with?(content_type, "multipart/form-data;")

      assert %{
               "errors" => %{
                 "attachments" => [
                   %{
                     "index" => 0,
                     "code" => "unknown_fields",
                     "fields" => ["upload"]
                   }
                 ]
               }
             } = json_response(conn, 400)

      refute Repo.get_by(Note, title: title)
      assert Repo.aggregate(StorageFile, :count, :id) == 0
      refute_received {:s3_put, _path, _body}
    end

    test "multipart update rejects upload and other unknown attachment fields", %{
      conn: conn,
      user: user
    } do
      note = note_fixture(user, %{title: "Unchanged multipart update"})
      upload = multipart_upload("untrusted update bytes")

      conn =
        conn
        |> authenticated_conn(user)
        |> put("/api/gao_notes/#{note.id}", %{
          "title" => "Must not update",
          "content" => "Must not update",
          "attachments" => [
            %{
              "id" => unique_id("multipart-update"),
              "path" => "upload.txt",
              "mime" => "text/plain",
              "role" => "inline",
              "upload" => upload
            }
          ]
        })

      assert [content_type] = get_req_header(conn, "content-type")
      assert String.starts_with?(content_type, "multipart/form-data;")

      assert %{
               "errors" => %{
                 "attachments" => [
                   %{
                     "index" => 0,
                     "code" => "unknown_fields",
                     "fields" => ["role", "upload"]
                   }
                 ]
               }
             } = json_response(conn, 400)

      assert %Note{title: "Unchanged multipart update", attachments: []} =
               GaoNote.get_note(note.id)

      assert Repo.aggregate(StorageFile, :count, :id) == 0
      refute_received {:s3_put, _path, _body}
    end

    test "update without attachments is a structured 400 and does not mutate", %{
      conn: conn,
      user: user
    } do
      note = note_fixture(user, %{title: "Must remain"})

      conn =
        conn
        |> authenticated_conn(user)
        |> put("/api/gao_notes/#{note.id}", %{"title" => "Must not update"})

      assert %{"errors" => %{"attachments" => ["is required"]}} =
               json_response(conn, 400)

      assert GaoNote.get_note(note.id).title == "Must remain"
    end

    test "write errors use 401, 404, 409, and 422 without leaking internals", %{
      conn: conn,
      user: user
    } do
      unauthenticated = post(conn, "/api/gao_notes", %{"title" => "No", "content" => "No"})
      assert json_response(unauthenticated, 401)["message"] =~ "no_resource"

      missing =
        conn
        |> recycle()
        |> authenticated_conn(user)
        |> put("/api/gao_notes/#{Ecto.UUID.generate()}", %{"attachments" => []})

      assert %{"errors" => %{"detail" => "Not Found"}} = json_response(missing, 404)

      invalid =
        conn
        |> recycle()
        |> authenticated_conn(user)
        |> post("/api/gao_notes", %{"title" => "", "content" => ""})

      assert %{"errors" => errors} = json_response(invalid, 422)
      assert errors["title"]
      assert errors["content"]

      required_content =
        conn
        |> recycle()
        |> authenticated_conn(user)
        |> post("/api/gao_notes", %{
          "title" => "Missing attachment content",
          "content" => "Note content",
          "attachments" => [
            %{
              "id" => unique_id("required-content"),
              "path" => "required.txt",
              "mime" => "text/plain"
            }
          ]
        })

      assert %{
               "errors" => %{
                 "attachments" => [
                   %{
                     "code" => "content_required",
                     "detail" => "Attachment validation failed"
                   }
                 ]
               }
             } = json_response(required_content, 422)

      owned_id = unique_id("owned")

      assert {:ok, _owner_note} =
               GaoNote.create_note(
                 %{
                   title: "Attachment owner",
                   content: "Owner",
                   attachments: [attachment_input(owned_id, "owned.txt", "owned")]
                 },
                 user
               )

      conflict =
        conn
        |> recycle()
        |> authenticated_conn(user)
        |> post("/api/gao_notes", %{
          "title" => "Conflicting note",
          "content" => "Conflict",
          "attachments" => [
            %{"id" => owned_id, "path" => "other.txt", "mime" => "text/plain"}
          ]
        })

      assert %{
               "errors" => %{
                 "code" => "owned_by_another_note",
                 "detail" => "Attachment conflict"
               }
             } = json_response(conflict, 409)

      path_conflict =
        conn
        |> recycle()
        |> authenticated_conn(user)
        |> post("/api/gao_notes", %{
          "title" => "Duplicate path",
          "content" => "Conflict",
          "attachments" => [
            %{
              "id" => unique_id("duplicate-path-a"),
              "path" => "same.txt",
              "mime" => "text/plain",
              "content" => "first"
            },
            %{
              "id" => unique_id("duplicate-path-b"),
              "path" => "same.txt",
              "mime" => "text/plain",
              "content" => "second"
            }
          ]
        })

      assert %{
               "errors" => %{
                 "code" => "duplicate_path",
                 "detail" => "Attachment conflict"
               }
             } = json_response(path_conflict, 409)
    end

    test "only malformed Base64 is 400 while semantic content is 422", %{
      conn: conn,
      user: user
    } do
      malformed =
        conn
        |> authenticated_conn(user)
        |> post("/api/gao_notes", %{
          "title" => "Malformed attachment",
          "content" => "Malformed",
          "attachments" => [
            %{
              "id" => unique_id("malformed"),
              "path" => "malformed.txt",
              "mime" => "text/plain",
              "content_base64" => "not-padded-base64"
            }
          ]
        })

      assert %{"errors" => %{"attachments" => [%{"fields" => fields}]}} =
               json_response(malformed, 400)

      assert fields["content_base64"]

      mismatched =
        conn
        |> recycle()
        |> authenticated_conn(user)
        |> post("/api/gao_notes", %{
          "title" => "Mismatched attachment content",
          "content" => "Note content",
          "attachments" => [
            %{
              "id" => unique_id("mismatched"),
              "path" => "mismatched.txt",
              "mime" => "text/plain",
              "content" => "plain text",
              "content_base64" => Base.encode64("different text")
            }
          ]
        })

      assert %{"errors" => %{"attachments" => [%{"fields" => mismatch_fields}]}} =
               json_response(mismatched, 422)

      assert mismatch_fields["content_base64"] == [
               "must decode to the same bytes as content"
             ]

      Application.put_env(:gsmlg_storage, :gao_note_http_public_fail_put, true)

      failed =
        conn
        |> recycle()
        |> authenticated_conn(user)
        |> post("/api/gao_notes", %{
          "title" => "Storage failure",
          "content" => "Storage",
          "attachments" => [
            attachment_input(unique_id("storage-failure"), "failed.txt", "payload")
          ]
        })

      assert %{"errors" => %{"detail" => "Internal Server Error"}} =
               json_response(failed, 500)

      refute failed.resp_body =~ "upstream put detail"
    end
  end

  describe "authenticated raw content" do
    test "requires authentication", %{conn: conn, user: user} do
      note = note_fixture(user)
      attachment = attachment_fixture(note, "./private.txt", "private")
      url = Presenter.attachment(attachment)["content_url"]

      conn = get(conn, url)
      assert json_response(conn, 401)["message"] =~ "no_resource"
      refute_received {:s3_get, _path, _ranges}
    end

    test "streams the Presenter URL with one decode and safe verified headers", %{
      conn: conn,
      user: user
    } do
      object = "encoded path content"
      note = note_fixture(user)

      attachment =
        attachment_fixture(note, "./docs/資料 #1?%.txt", object,
          mime: "application/octet-stream",
          content_type: "text/plain"
        )

      url = Presenter.attachment(attachment)["content_url"]

      assert url ==
               "/api/gao_notes/#{note.id}/attachments/docs/%E8%B3%87%E6%96%99%20%231%3F%25.txt"

      conn =
        conn
        |> authenticated_conn(user)
        |> get(url)

      assert response(conn, 200) == object
      assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
      assert get_resp_header(conn, "accept-ranges") == ["bytes"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

      assert get_resp_header(conn, "content-disposition") == [
               "attachment; filename=\"__ #1?%.txt\"; " <>
                 "filename*=UTF-8''%E8%B3%87%E6%96%99%20%231%3F%25.txt"
             ]

      assert_receive {:s3_get, _path, ["bytes=0-19"]}

      encoded_slash_url =
        String.replace(url, "/attachments/docs/", "/attachments/docs%2F")

      encoded_slash_conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> authenticated_conn(user)
        |> get(encoded_slash_url)

      assert response(encoded_slash_conn, 200) == object
    end

    test "forces active MIME types to download and inlines only safe raster or text content", %{
      conn: conn,
      user: user
    } do
      note = note_fixture(user)

      for {mime, filename, disposition} <- [
            {"text/html", "active.html", "attachment"},
            {"image/svg+xml", "active.svg", "attachment"},
            {"image/png", "safe.png", "inline"},
            {"text/plain", "safe.txt", "inline"}
          ] do
        object = "content for #{mime}"
        attachment = attachment_fixture(note, "./#{filename}", object, mime: mime)

        response_conn =
          conn
          |> recycle()
          |> authenticated_conn(user)
          |> get(Presenter.attachment(attachment)["content_url"])

        assert response(response_conn, 200) == object
        assert get_resp_header(response_conn, "content-type") == [mime]
        assert get_resp_header(response_conn, "x-content-type-options") == ["nosniff"]

        assert [header] = get_resp_header(response_conn, "content-disposition")
        assert String.starts_with?(header, ~s(#{disposition}; filename="#{filename}";))
      end
    end

    test "does not double-decode a literal percent escape", %{conn: conn, user: user} do
      object = "literal percent"
      note = note_fixture(user)
      attachment = attachment_fixture(note, "./docs/literal%2Fname.txt", object)
      url = Presenter.attachment(attachment)["content_url"]

      assert url =~ "literal%252Fname.txt"

      conn =
        conn
        |> authenticated_conn(user)
        |> get(url)

      assert response(conn, 200) == object
    end

    test "scopes by active note and path without accepting storage IDs", %{
      conn: conn,
      user: user
    } do
      owner_note = note_fixture(user, %{title: "Owner"})
      other_note = note_fixture(user, %{title: "Other"})
      attachment = attachment_fixture(owner_note, "./scoped.txt", "scoped")
      path = URI.encode("scoped.txt")

      cross_note =
        conn
        |> authenticated_conn(user)
        |> get("/api/gao_notes/#{other_note.id}/attachments/#{path}")

      assert %{"errors" => %{"detail" => "Not Found"}} = json_response(cross_note, 404)
      refute_received {:s3_get, _path, _ranges}

      storage_id =
        conn
        |> recycle()
        |> authenticated_conn(user)
        |> get("/api/gao_notes/#{owner_note.id}/attachments/#{attachment.storage_file_id}")

      assert %{"errors" => %{"detail" => "Not Found"}} = json_response(storage_id, 404)

      assert {:ok, _deleted} = GaoNote.delete_note(owner_note, user)

      deleted =
        conn
        |> recycle()
        |> authenticated_conn(user)
        |> get(Presenter.attachment(attachment)["content_url"])

      assert %{"errors" => %{"detail" => "Not Found"}} = json_response(deleted, 404)
      refute_received {:s3_get, _path, _ranges}
    end

    test "returns 404 for controller-reachable invalid and unknown canonical paths", %{
      user: user
    } do
      note = note_fixture(user)

      for suffix <- [
            "",
            "%2E%2E/secret.txt",
            "safe/%2E%2E/secret.txt",
            "%2Fetc/passwd",
            "unknown.txt",
            "%00.txt"
          ] do
        conn =
          build_conn()
          |> put_req_header("accept", "application/json")
          |> authenticated_conn(user)
          |> get("/api/gao_notes/#{note.id}/attachments/#{suffix}")

        assert conn.status == 404
      end

      refute_received {:s3_get, _path, _ranges}
    end

    test "returns 400 when Phoenix or Plug rejects malformed URI encoding", %{user: user} do
      note = note_fixture(user)

      for suffix <- ["%ZZ", "%FF.txt"] do
        conn =
          build_conn()
          |> put_req_header("accept", "application/json")
          |> authenticated_conn(user)
          |> get("/api/gao_notes/#{note.id}/attachments/#{suffix}")

        assert conn.status == 400
      end

      refute_received {:s3_get, _path, _ranges}
    end

    test "streams closed, open-ended, and suffix ranges", %{conn: conn, user: user} do
      note = note_fixture(user)
      attachment = attachment_fixture(note, "./ranges.txt", "0123456789")
      url = Presenter.attachment(attachment)["content_url"]

      for {range, body, content_range} <- [
            {"bytes=2-5", "2345", "bytes 2-5/10"},
            {"bytes=6-", "6789", "bytes 6-9/10"},
            {"bytes=-3", "789", "bytes 7-9/10"}
          ] do
        ranged =
          conn
          |> recycle()
          |> authenticated_conn(user)
          |> put_req_header("range", range)
          |> get(url)

        assert response(ranged, 206) == body
        assert get_resp_header(ranged, "content-range") == [content_range]
        assert get_resp_header(ranged, "accept-ranges") == ["bytes"]
        assert_receive {:s3_get, _path, [_bounded_range]}
      end
    end

    test "returns 416 for malformed, multiple, and unsatisfiable ranges", %{
      conn: conn,
      user: user
    } do
      note = note_fixture(user)
      attachment = attachment_fixture(note, "./invalid-ranges.txt", "0123456789")
      url = Presenter.attachment(attachment)["content_url"]

      for range <- ["bytes=bad", "bytes=0-1,4-5", "bytes=10-", "items=0-1"] do
        ranged =
          conn
          |> recycle()
          |> authenticated_conn(user)
          |> put_req_header("range", range)
          |> get(url)

        assert response(ranged, 416) == ""
        assert get_resp_header(ranged, "content-range") == ["bytes */10"]
      end

      refute_received {:s3_get, _path, _ranges}
    end

    test "serves a zero-byte full response and rejects every zero-byte range", %{
      conn: conn,
      user: user
    } do
      note = note_fixture(user)
      attachment = attachment_fixture(note, "./empty.txt", "")
      url = Presenter.attachment(attachment)["content_url"]

      full =
        conn
        |> authenticated_conn(user)
        |> get(url)

      assert response(full, 200) == ""
      assert get_resp_header(full, "content-type") == ["text/plain"]
      assert get_resp_header(full, "accept-ranges") == ["bytes"]

      ranged =
        conn
        |> recycle()
        |> authenticated_conn(user)
        |> put_req_header("range", "bytes=0-0")
        |> get(url)

      assert response(ranged, 416) == ""
      assert get_resp_header(ranged, "content-range") == ["bytes */0"]
      refute_received {:s3_get, _path, _ranges}
    end

    test "uses only bounded 64 KiB storage reads for a full response", %{
      conn: conn,
      user: user
    } do
      object = :binary.copy("x", @chunk_size * 2 + 17)
      note = note_fixture(user)
      attachment = attachment_fixture(note, "./large.bin", object)

      conn =
        conn
        |> authenticated_conn(user)
        |> get(Presenter.attachment(attachment)["content_url"])

      assert response(conn, 200) == object
      assert_receive {:s3_get, _path, ["bytes=0-65535"]}
      assert_receive {:s3_get, _path, ["bytes=65536-131071"]}
      assert_receive {:s3_get, _path, ["bytes=131072-131088"]}
      refute_received {:s3_get, _path, []}
    end

    test "returns a generic 503 when the first bounded storage read fails", %{
      conn: conn,
      user: user
    } do
      object = "unavailable"
      note = note_fixture(user)
      attachment = attachment_fixture(note, "./unavailable.txt", object)
      Application.put_env(:gsmlg_storage, :gao_note_http_public_fail_ranges, ["bytes=0-10"])

      conn =
        conn
        |> authenticated_conn(user)
        |> get(Presenter.attachment(attachment)["content_url"])

      assert %{"errors" => %{"detail" => "Service Unavailable"}} =
               json_response(conn, 503)

      refute conn.resp_body =~ "upstream get detail"
      assert_receive {:s3_get, _path, ["bytes=0-10"]}
    end

    test "aborts a partial response and emits sanitized telemetry on a later read failure", %{
      conn: conn,
      user: user
    } do
      object = :binary.copy("x", @chunk_size + 10)
      note = note_fixture(user)
      attachment = attachment_fixture(note, "./later-failure.bin", object)
      Application.put_env(:gsmlg_storage, :gao_note_http_public_fail_ranges, ["bytes=65536-65545"])
      telemetry_id = capture_log_telemetry()

      assert {:shutdown, :gao_note_attachment_storage_read_failed} =
               catch_exit(
                 conn
                 |> authenticated_conn(user)
                 |> put_req_header("range", "bytes=0-65545")
                 |> get(Presenter.attachment(attachment)["content_url"])
               )

      assert_receive {:s3_get, _path, ["bytes=0-65535"]}
      assert_receive {:s3_get, _path, ["bytes=65536-65545"]}

      assert_receive {:telemetry, [:gsmlg, :log], %{level: :error}, metadata}
      assert metadata.message == "GaoNote attachment content stream failed"
      assert metadata.note_id == note.id
      assert metadata.path == "./later-failure.bin"
      assert metadata.reason == :storage_error
      refute inspect(metadata) =~ "upstream get detail"

      :ok = :telemetry.detach(telemetry_id)
    end

    test "stops without crashing when the client closes on the first chunk", %{
      user: user
    } do
      object = "client close"
      note = note_fixture(user)
      attachment = attachment_fixture(note, "./client-close.txt", object)
      url = Presenter.attachment(attachment)["content_url"]
      _telemetry_id = capture_log_telemetry()

      conn =
        build_conn(:get, url)
        |> Map.put(:adapter, {ClosingAdapter, self()})

      result =
        GSMLG.Web.GaoNoteAttachmentContentController.show(conn, %{
          "note_id" => note.id,
          "path" => ["client-close.txt"]
        })

      assert result.state == :chunked
      assert_receive {:send_chunked, 200, _headers}
      assert_receive {:chunk_attempt, ^object}
      refute_receive {:telemetry, [:gsmlg, :log], %{level: :error}, _metadata}
    end
  end

  defp authenticated_conn(conn, user) do
    {:ok, token, _claims} =
      GSMLG.Web.Guardian.encode_and_sign(user, %{}, token_type: "access")

    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp user_fixture(id) do
    Repo.get(User, id) ||
      Repo.insert!(%User{
        id: id,
        username: id,
        email: "#{id}@example.test",
        password: "test"
      })
  end

  defp note_fixture(user, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{title: unique_id("Public raw note"), content: "Content"},
        attrs
      )

    assert {:ok, note} = GaoNote.create_note(attrs, user)
    note
  end

  defp attachment_input(id, path, content) do
    %{id: id, path: path, mime: "text/plain", content: content}
  end

  defp attachment_fixture(note, path, object, opts \\ []) do
    Application.put_env(:gsmlg_storage, :gao_note_http_public_object, object)

    file =
      %StorageFile{}
      |> StorageFile.changeset(%{
        tenant: "gao_note",
        type: "gao_note_attachment",
        filename: Path.basename(path),
        s3_key: "gao_note/#{Ecto.UUID.generate()}",
        content_type: Keyword.get(opts, :content_type, "text/plain"),
        size: byte_size(object),
        checksum: Ecto.UUID.generate(),
        metadata: %{},
        variants: %{},
        status: "active",
        uploaded_by: "fixture"
      })
      |> Repo.insert!()

    attachment =
      %Attachment{}
      |> Attachment.changeset(%{
        id: Keyword.get(opts, :id, unique_id("attachment")),
        note_id: note.id,
        storage_file_id: file.id,
        path: path,
        mime: Keyword.get(opts, :mime, "text/plain"),
        description: ""
      })
      |> Repo.insert!()

    Repo.preload(attachment, :storage_file)
  end

  defp multipart_upload(contents) do
    path =
      Path.join(
        System.tmp_dir!(),
        unique_id("gao-note-http-boundary")
      )

    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)

    %Plug.Upload{
      path: path,
      filename: "untrusted.txt",
      content_type: "text/plain"
    }
  end

  defp flush_storage_messages do
    receive do
      {:s3_put, _path, _body} -> flush_storage_messages()
      {:s3_get, _path, _ranges} -> flush_storage_messages()
      {:s3_delete, _path} -> flush_storage_messages()
    after
      0 -> :ok
    end
  end

  defp capture_log_telemetry do
    handler_id = {__MODULE__, self(), make_ref()}
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:gsmlg, :log],
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    handler_id
  end

  defp available_port do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp unique_id(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end
end
