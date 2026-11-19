defmodule GSMLG.Storage.S3ReadTest do
  use ExUnit.Case, async: false

  alias GSMLG.Storage.{Catalog, S3Client}

  defmodule Transport do
    @behaviour ExStorageServiceSdk.Transport

    alias ExStorageServiceSdk.S3.Response

    @impl true
    def request(_url, request, _opts) do
      headers = Map.new(request.headers, fn {name, value} -> {String.downcase(name), value} end)
      body = Map.fetch!(headers, "x-test-body")

      {status, body} =
        case headers["range"] do
          nil ->
            {200, body}

          "bytes=" <> range ->
            [first, last] = range |> String.split("-") |> Enum.map(&String.to_integer/1)
            {206, binary_part(body, first, last - first + 1)}
        end

      {:ok,
       %Response{
         status: status,
         body: body,
         controller: self(),
         headers: [
           {"content-length",
            Map.get(headers, "x-test-content-length", Integer.to_string(byte_size(body)))}
         ]
       }}
    end

    @impl true
    def consume(response, acc, reducer, _opts) do
      try do
        response.body
        |> split_chunks()
        |> Enum.reduce_while({:ok, acc}, fn chunk, {:ok, acc} ->
          case reducer.(chunk, acc) do
            {:ok, acc} -> {:cont, {:ok, acc}}
            {:error, _} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, acc} -> {:ok, acc, %{}}
          error -> error
        end
      after
        close(response)
      end
    end

    @impl true
    def close(response) do
      send(response.controller, :response_closed)
      :ok
    end

    defp split_chunks(<<>>), do: []
    defp split_chunks(<<first, rest::binary>>), do: [<<first>>, rest]
  end

  setup do
    original_limit = Application.fetch_env(:gsmlg_storage, :max_file_size)

    on_exit(fn ->
      case original_limit do
        {:ok, limit} -> Application.put_env(:gsmlg_storage, :max_file_size, limit)
        :error -> Application.delete_env(:gsmlg_storage, :max_file_size)
      end
    end)

    :ok
  end

  test "lowering the upload limit preserves reads of existing objects" do
    body = <<0, 255>> <> "stored bytes"
    backend = backend(body)

    Application.put_env(:gsmlg_storage, :max_file_size, byte_size(body))
    assert {:ok, ^body} = S3Client.get_object(backend, "existing.bin")
    assert_receive :response_closed

    Application.put_env(:gsmlg_storage, :max_file_size, 1)
    assert {:ok, ^body} = S3Client.get_object(backend, "existing.bin")
    assert_receive :response_closed
  end

  test "catalog manifests remain readable when metadata exceeds the upload limit" do
    Application.put_env(:gsmlg_storage, :max_file_size, 1)
    id = "0682be82-0cea-4b6d-a90d-96d5da6238a1"

    body =
      JSON.encode!(%{
        id: id,
        version: 1,
        tenant: "test",
        type: "attachment",
        filename: "tiny.txt",
        s3_key: "tiny.txt",
        content_type: "text/plain",
        size: 1,
        inserted_at: "2026-11-13T00:00:00Z",
        updated_at: "2026-11-13T00:00:00Z"
      })

    assert {:ok, %{id: ^id, size: 1, s3_key: "tiny.txt"}} =
             Catalog.fetch(id, backend: backend(body))

    assert_receive :response_closed
  end

  test "reads objects above the SDK default buffering limit" do
    body = :binary.copy(<<42>>, 8_388_609)
    assert {:ok, ^body} = S3Client.get_object(backend(body), "large.bin")
    assert_receive :response_closed
  end

  test "preserves empty objects" do
    assert {:ok, ""} = S3Client.get_object(backend(""), "empty.bin")
    assert_receive :response_closed
  end

  test "byte ranges remain readable after lowering the upload limit" do
    Application.put_env(:gsmlg_storage, :max_file_size, 1)
    assert {:ok, "234"} = S3Client.get_object_range(backend("012345"), "range.bin", 2, 4)
    assert_receive :response_closed
  end

  test "invalid response metadata returns an error and closes the response" do
    backend = backend("body", [{"x-test-content-length", "invalid"}])

    assert {:error, %ExStorageServiceSdk.Error{category: :protocol, code: :invalid_number}} =
             S3Client.get_object(backend, "invalid.bin")

    assert_receive :response_closed
  end

  defp backend(body, headers \\ []) do
    {:ok, client} =
      ExStorageServiceSdk.new(
        endpoint: "http://storage.test",
        unsigned: true,
        transport: Transport,
        options: %{request_headers: [{"x-test-body", body} | headers]}
      )

    %{bucket: "attachments", client: client, id: "test-backend"}
  end
end
