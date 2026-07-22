defmodule GSMLG.ProxyRules.PublicationConcurrencyTest do
  use ExUnit.Case, async: false

  alias GSMLG.ProxyRules.{Compiler, Snapshot, Store}

  @tag :tmp_dir
  test "readers never observe a torn six-output generation", %{tmp_dir: dir} do
    supervisor = GSMLG.ProxyRules.Supervisor
    :ok = Supervisor.terminate_child(supervisor, Store)
    {:ok, store} = Store.start_link(state_directory: dir)
    Process.unlink(store)

    on_exit(fn ->
      if pid = Process.whereis(Store), do: GenServer.stop(pid)
      assert {:ok, _pid} = Supervisor.restart_child(supervisor, Store)
    end)

    parent = self()

    readers =
      for _ <- 1..8 do
        Task.async(fn ->
          for _ <- 1..1_000 do
            case Store.current() do
              {:ok, snapshot} -> assert_complete(snapshot)
              {:error, :not_ready} -> :ok
            end
          end

          send(parent, :reader_done)
        end)
      end

    for generation <- 1..100 do
      assert {:ok, snapshot} =
               Compiler.compile(
                 %{
                   remote: Base.encode64("||g#{generation}.example^\n"),
                   local_proxy: "p#{generation}.example\n",
                   local_direct: "d#{generation}.example\n"
                 },
                 generation: generation,
                 compiled_at: DateTime.add(~U[2026-07-23 00:00:00Z], generation, :second),
                 sample_limit: 2
               )

      assert :ok = Store.publish(snapshot)
    end

    Enum.each(readers, &Task.await(&1, 10_000))
    for _ <- readers, do: assert_receive(:reader_done)
  end

  defp assert_complete(%Snapshot{
         generation: generation,
         compiled_at: compiled_at,
         rendered_outputs: outputs
       }) do
    assert Map.keys(outputs) |> Enum.sort() == [:direct, :proxy]
    assert DateTime.diff(compiled_at, ~U[2026-07-23 00:00:00Z], :second) == generation

    for list <- [:proxy, :direct], format <- [:raw, :squid, :clash] do
      output = outputs |> Map.fetch!(list) |> Map.fetch!(format)
      assert is_binary(output.body)
      assert is_binary(output.etag)
      assert output.content_length == byte_size(output.body)
      assert output.last_modified == compiled_at
      assert output.body =~ "#{generation}.example"
    end

    assert is_integer(generation)
  end
end
