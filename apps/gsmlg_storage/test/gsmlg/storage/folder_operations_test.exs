defmodule GSMLG.Storage.FolderOperationsTest do
  use ExUnit.Case, async: false

  alias GSMLG.Storage
  alias GSMLG.Storage.{Catalog, S3Client, StorageFile, TestCatalogClient}

  defmodule ObjectStore do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, %{pid: pid, objects: objects, faults: faults}) do
      key = conn.request_path |> URI.decode() |> String.replace_prefix("/folders-test/", "")
      send(pid, {:object_request, conn.method, key, conn.req_headers})

      case :ets.lookup(faults, {conn.method, key}) do
        [{_, status}] -> send_resp(conn, status, "")
        [] -> handle(conn, key, objects, faults)
      end
    end

    defp handle(%{method: "GET"} = conn, _key, objects, _faults) do
      contents =
        objects
        |> :ets.tab2list()
        |> Enum.sort()
        |> Enum.map_join(fn {key, bytes} ->
          "<Contents><Key>#{URI.encode(key, &URI.char_unreserved?/1)}</Key>" <>
            "<Size>#{byte_size(bytes)}</Size><ETag>&quot;#{etag(bytes)}&quot;</ETag>" <>
            "<LastModified>2026-10-17T00:00:00Z</LastModified></Contents>"
        end)

      body =
        "<ListBucketResult><EncodingType>url</EncodingType>" <>
          "<IsTruncated>false</IsTruncated>#{contents}</ListBucketResult>"

      conn |> put_resp_content_type("application/xml") |> send_resp(200, body)
    end

    defp handle(%{method: "PUT"} = conn, key, objects, faults) do
      [source] = get_req_header(conn, "x-amz-copy-source")
      source = source |> URI.decode() |> String.replace_prefix("folders-test/", "")

      case :ets.lookup(objects, source) do
        [{_, bytes}] ->
          if get_req_header(conn, "x-amz-copy-source-if-match") == ["\"#{etag(bytes)}\""] and
               get_req_header(conn, "if-none-match") == ["*"] and not :ets.member(objects, key) do
            :ets.insert(objects, {key, bytes})

            if :ets.member(faults, :switch_backend_after_copy),
              do: Application.put_env(:gsmlg_storage, :s3_bucket, "replacement")

            conn
            |> put_resp_content_type("application/xml")
            |> send_resp(200, "<CopyObjectResult><ETag>#{etag(bytes)}</ETag></CopyObjectResult>")
          else
            send_resp(conn, 412, "")
          end

        [] ->
          send_resp(conn, 404, "")
      end
    end

    defp handle(%{method: "DELETE"} = conn, key, objects, _faults) do
      case :ets.lookup(objects, key) do
        [{_, bytes}] ->
          if get_req_header(conn, "if-match") == ["\"#{etag(bytes)}\""] do
            :ets.delete(objects, key)
            send_resp(conn, 204, "")
          else
            send_resp(conn, 412, "")
          end

        [] ->
          send_resp(conn, 204, "")
      end
    end

    defp etag(bytes), do: :crypto.hash(:md5, bytes) |> Base.encode16(case: :lower)
  end

  defmodule FaultCatalogClient do
    defdelegate get_object(backend, key), to: TestCatalogClient
    defdelegate list_objects(backend), to: TestCatalogClient
    defdelegate delete_object(backend, key), to: TestCatalogClient

    def put_object(backend, key, bytes, type) do
      case Process.delete(:folder_manifest_fault) do
        :before_commit ->
          {:error, :injected_manifest_failure}

        :after_commit ->
          :ok = TestCatalogClient.put_object(backend, key, bytes, type)
          {:error, :injected_manifest_failure}

        nil ->
          TestCatalogClient.put_object(backend, key, bytes, type)
      end
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(GSMLG.Repo)
    TestCatalogClient.setup!()
    keys = [:s3_bucket, :s3_endpoint]
    previous = Map.new(keys, &{&1, Application.fetch_env(:gsmlg_storage, &1)})
    objects = :ets.new(:folder_operation_objects, [:set, :public])
    faults = :ets.new(:folder_operation_faults, [:set, :public])

    server =
      start_supervised!(
        {Bandit,
         plug: {ObjectStore, %{pid: self(), objects: objects, faults: faults}},
         port: 0,
         startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    Application.put_env(:gsmlg_storage, :s3_bucket, "folders-test")
    Application.put_env(:gsmlg_storage, :s3_endpoint, "http://127.0.0.1:#{port}")

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:gsmlg_storage, key, value)
        {key, :error} -> Application.delete_env(:gsmlg_storage, key)
      end)
    end)

    %{backend_id: S3Client.current_backend_id(), objects: objects, faults: faults}
  end

  test "renames implicit folders and markers with exact Unicode and special keys", ctx do
    prefix = "外部 +%/?#/"
    keys = [prefix, prefix <> "nested/", prefix <> "nested/原文 +%?#.txt"]
    Enum.each(keys, &:ets.insert(ctx.objects, {&1, &1}))
    :ets.insert(ctx.objects, {"外部 +%/?#sibling/file", "retain"})
    :ets.insert(ctx.objects, {"unrelated/file", "retain"})

    assert {:ok, "外部 +%/新 +%?#/"} =
             Storage.rename_object_folder(prefix, "新 +%?#", ctx.backend_id)

    Enum.each(keys, fn key ->
      refute :ets.member(ctx.objects, key)
      renamed = String.replace_prefix(key, prefix, "外部 +%/新 +%?#/")
      assert [{^renamed, ^key}] = :ets.lookup(ctx.objects, renamed)
    end)

    assert [{_, "retain"}] = :ets.lookup(ctx.objects, "外部 +%/?#sibling/file")
    assert [{_, "retain"}] = :ets.lookup(ctx.objects, "unrelated/file")
    assert_receive {:object_request, "PUT", _, headers}
    assert {"x-amz-metadata-directive", "COPY"} in headers
    assert {"x-amz-tagging-directive", "COPY"} in headers
  end

  test "recursively deletes only the exact folder prefix including markers", ctx do
    Enum.each(
      ["folder/", "folder/nested/", "folder/nested/file"],
      &:ets.insert(ctx.objects, {&1, "bytes"})
    )

    :ets.insert(ctx.objects, {"folders/file", "sibling"})
    assert {:ok, "folder/"} = Storage.delete_object_folder("folder/", ctx.backend_id)
    assert [{"folders/file", "sibling"}] = :ets.tab2list(ctx.objects)
  end

  test "rejects roots, invalid prefixes, reserved folders and invalid new segments without writes",
       ctx do
    for prefix <- ["", "/", "folder", <<255, ?/>>] do
      assert {:error, _} = Storage.rename_object_folder(prefix, "new", ctx.backend_id)
      assert {:error, _} = Storage.delete_object_folder(prefix, ctx.backend_id)
    end

    for prefix <- [".gsmlg-storage/", ".gsmlg-storage/objects/"] do
      assert {:error, :reserved_storage_key} =
               Storage.delete_object_folder(prefix, ctx.backend_id)

      assert {:error, :reserved_storage_key} =
               Storage.rename_object_folder(prefix, "new", ctx.backend_id)
    end

    for name <- ["", " ", ".", "..", "a/b", "bad\nname", <<255>>] do
      assert {:error, :invalid_folder_name} =
               Storage.rename_object_folder("folder/", name, ctx.backend_id)
    end

    assert {:error, :reserved_storage_key} =
             Storage.rename_object_folder("folder/", ".gsmlg-storage", ctx.backend_id)

    refute_receive {:object_request, "PUT", _, _}
    refute_receive {:object_request, "DELETE", _, _}
  end

  test "rejects destination collisions including implicit directories and reservations", ctx do
    :ets.insert(ctx.objects, {"old/file", "original"})
    :ets.insert(ctx.objects, {"new/deep/file", "destination"})
    assert {:error, :folder_exists} = Storage.rename_object_folder("old/", "new", ctx.backend_id)
    :ets.delete(ctx.objects, "new/deep/file")
    file(s3_key: "new/reserved", status: "processing")
    assert {:error, :folder_exists} = Storage.rename_object_folder("old/", "new", ctx.backend_id)
    refute_receive {:object_request, "PUT", _, _}
    refute_receive {:object_request, "DELETE", _, _}
  end

  test "reports absent source and stale backend without mutation", ctx do
    assert {:error, :folder_not_found} =
             Storage.rename_object_folder("missing/", "new", ctx.backend_id)

    assert {:error, :folder_not_found} = Storage.delete_object_folder("missing/", ctx.backend_id)
    Application.put_env(:gsmlg_storage, :s3_bucket, "replacement")

    assert {:error, :backend_changed} =
             Storage.rename_object_folder("folder/", "new", ctx.backend_id)

    assert {:error, :backend_changed} = Storage.delete_object_folder("folder/", ctx.backend_id)
    refute_receive {:object_request, "PUT", _, _}
    refute_receive {:object_request, "DELETE", _, _}
  end

  test "rewrites original and all matching variants while retaining UUID and logical metadata",
       ctx do
    file =
      file(
        s3_key: "old/original",
        variants: %{
          "thumb" => %{"s3_key" => "old/nested/thumb", "width" => 4},
          "external" => %{"s3_key" => "outside/variant"}
        }
      )

    Enum.each(
      [file.s3_key, "old/nested/thumb", "outside/variant"],
      &:ets.insert(ctx.objects, {&1, "bytes"})
    )

    assert {:ok, "new/"} = Storage.rename_object_folder("old/", "new", ctx.backend_id)
    assert {:ok, moved} = Catalog.fetch(file.id)
    assert moved.id == file.id
    assert moved.s3_key == "new/original"

    assert moved.variants == %{
             "thumb" => %{"s3_key" => "new/nested/thumb", "width" => 4},
             "external" => %{"s3_key" => "outside/variant"}
           }

    for field <- [:tenant, :type, :filename, :content_type, :checksum, :metadata, :status] do
      assert Map.fetch!(moved, field) == Map.fetch!(file, field)
    end

    assert [{_, "bytes"}] = :ets.lookup(ctx.objects, "outside/variant")
  end

  test "deleting an original purges its outside variants and S3 manifest", ctx do
    file = file(s3_key: "old/original", variants: %{"thumb" => %{"s3_key" => "outside/thumb"}})
    Enum.each([file.s3_key, "outside/thumb", "old/raw"], &:ets.insert(ctx.objects, {&1, "bytes"}))
    assert {:ok, "old/"} = Storage.delete_object_folder("old/", ctx.backend_id)
    assert [] = :ets.tab2list(ctx.objects)
    assert {:error, :not_found} = Catalog.fetch(file.id)
  end

  test "variant-only folder deletion retains original and other variants", ctx do
    file =
      file(
        s3_key: "outside/original",
        variants: %{
          "thumb" => %{"s3_key" => "old/thumb"},
          "other" => %{"s3_key" => "outside/other"}
        }
      )

    Enum.each(
      [file.s3_key, "old/thumb", "outside/other"],
      &:ets.insert(ctx.objects, {&1, "bytes"})
    )

    assert {:ok, "old/"} = Storage.delete_object_folder("old/", ctx.backend_id)
    assert {:ok, %{s3_key: "outside/original", variants: variants}} = Catalog.fetch(file.id)
    assert variants == %{"other" => %{"s3_key" => "outside/other"}}
    assert [{_, "bytes"}] = :ets.lookup(ctx.objects, "outside/original")
  end

  test "all references are checked before any raw or managed mutation", ctx do
    unreferenced = file(s3_key: "old/unreferenced")
    protected = file(s3_key: "old/protected")

    Enum.each(
      [unreferenced.s3_key, protected.s3_key, "old/raw"],
      &:ets.insert(ctx.objects, {&1, "bytes"})
    )

    note = GSMLG.Repo.insert!(%GSMLG.GaoNote.Note{title: "Protected", content: "text"})

    attachment =
      GSMLG.Repo.insert!(%GSMLG.GaoNote.Attachment{
        id: "folder-protected",
        api_id: "folder-protected",
        note_id: note.id,
        storage_file_id: protected.id,
        path: "./original.txt",
        mime: "text/plain"
      })

    assert {:error, :file_referenced} = Storage.delete_object_folder("old/", ctx.backend_id)

    assert {:error, :file_referenced} =
             Storage.rename_object_folder("old/", "new", ctx.backend_id)

    assert {:ok, %{status: "active"}} = Catalog.fetch(unreferenced.id)
    assert GSMLG.Repo.get!(GSMLG.GaoNote.Attachment, attachment.id).path == "./original.txt"
    refute_receive {:object_request, "PUT", _, _}
    refute_receive {:object_request, "DELETE", _, _}
  end

  test "a live sync reader pin protects files without an attachment reference", ctx do
    file = file(s3_key: "old/original")
    :ets.insert(ctx.objects, {file.s3_key, "bytes"})
    owner = Ecto.UUID.generate()

    GSMLG.Repo.insert!(%GSMLG.GaoNote.Sync.Record{
      id: owner,
      kind: "lease",
      data: %{"expires_at" => System.system_time(:millisecond) + 3_600_000}
    })

    GSMLG.Repo.insert!(%GSMLG.GaoNote.Sync.Pin{
      owner_id: owner,
      storage_file_id: file.id
    })

    assert {:error, :file_referenced} = Storage.delete_object_folder("old/", ctx.backend_id)

    assert {:error, :file_referenced} =
             Storage.rename_object_folder("old/", "new", ctx.backend_id)

    assert {:ok, %{status: "active", s3_key: "old/original"}} = Catalog.fetch(file.id)
    assert [{_, "bytes"}] = :ets.lookup(ctx.objects, file.s3_key)
    refute_receive {:object_request, "PUT", _, _}
    refute_receive {:object_request, "DELETE", _, _}
  end

  test "active upload reservation prevents both operations before any mutation", ctx do
    file(s3_key: "old/pending", status: "processing")
    :ets.insert(ctx.objects, {"old/raw", "bytes"})
    assert {:error, :file_processing} = Storage.delete_object_folder("old/", ctx.backend_id)

    assert {:error, :file_processing} =
             Storage.rename_object_folder("old/", "new", ctx.backend_id)

    refute_receive {:object_request, "PUT", _, _}
    refute_receive {:object_request, "DELETE", _, _}
  end

  test "copy failure preserves every original and leaves manifests untouched", ctx do
    file = file(s3_key: "old/a")
    :ets.insert(ctx.objects, [{"old/a", "first"}, {"old/z", "last"}])
    :ets.insert(ctx.faults, {{"PUT", "new/z"}, 503})

    assert {:error, {:folder_operation_failed, :copy, "old/z", _}} =
             Storage.rename_object_folder("old/", "new", ctx.backend_id)

    assert {:ok, %{s3_key: "old/a"}} = Catalog.fetch(file.id)
    assert [{_, "first"}] = :ets.lookup(ctx.objects, "old/a")
    assert [{_, "last"}] = :ets.lookup(ctx.objects, "old/z")
    refute_receive {:object_request, "DELETE", _, _}
  end

  test "uncertain manifest commit retains both copies and originals", ctx do
    file = file(s3_key: "old/file")
    :ets.insert(ctx.objects, {file.s3_key, "bytes"})
    Application.put_env(:gsmlg_storage, :catalog_s3_client, FaultCatalogClient)
    Process.put(:folder_manifest_fault, :after_commit)

    assert {:error, {:folder_operation_failed, :manifest, _, :injected_manifest_failure}} =
             Storage.rename_object_folder("old/", "new", ctx.backend_id)

    assert {:ok, %{s3_key: "new/file"}} = Catalog.fetch(file.id)
    assert [{_, "bytes"}] = :ets.lookup(ctx.objects, "old/file")
    assert [{_, "bytes"}] = :ets.lookup(ctx.objects, "new/file")
    refute_receive {:object_request, "DELETE", _, _}
  end

  test "delete failure keeps a recoverable deleted manifest and permits retry", ctx do
    file = file(s3_key: "old/file", variants: %{"thumb" => %{"s3_key" => "outside/thumb"}})
    :ets.insert(ctx.objects, [{"old/file", "bytes"}, {"outside/thumb", "thumb"}])
    :ets.insert(ctx.faults, {{"DELETE", "outside/thumb"}, 503})

    assert {:error, {:folder_operation_failed, :managed_delete, _, _}} =
             Storage.delete_object_folder("old/", ctx.backend_id)

    assert {:ok, %{status: "deleted"}} = Catalog.fetch(file.id)
    assert [{_, "thumb"}] = :ets.lookup(ctx.objects, "outside/thumb")
    :ets.delete(ctx.faults, {"DELETE", "outside/thumb"})
    assert {:ok, "old/"} = Storage.delete_object_folder("old/", ctx.backend_id)
    assert {:error, :not_found} = Catalog.fetch(file.id)
    assert [] = :ets.tab2list(ctx.objects)
  end

  test "backend switch after copy retains source and never deletes in either bucket", ctx do
    :ets.insert(ctx.objects, [{"old/a", "a"}, {"old/z", "z"}])
    :ets.insert(ctx.faults, {:switch_backend_after_copy, true})

    assert {:error, {:folder_operation_failed, :copy, "old/z", :backend_changed}} =
             Storage.rename_object_folder("old/", "new", ctx.backend_id)

    assert [{_, "a"}] = :ets.lookup(ctx.objects, "old/a")
    assert [{_, "z"}] = :ets.lookup(ctx.objects, "old/z")
    refute_receive {:object_request, "DELETE", _, _}
  end

  defp file(attrs) do
    %StorageFile{}
    |> StorageFile.changeset(
      Map.merge(
        %{
          tenant: "test",
          type: "attachment",
          filename: "original.txt",
          s3_key: "old/file",
          content_type: "text/plain",
          size: 5,
          status: "active",
          metadata: %{"keep" => "value"}
        },
        Map.new(attrs)
      )
    )
    |> TestCatalogClient.insert_file!()
  end
end
