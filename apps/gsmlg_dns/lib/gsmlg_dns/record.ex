defmodule GSMLGDNS.Record do
  @moduledoc """
  Struct definition for serializing and parsing GSMLGDNS records.
  """

  record = Record.extract(:dns_rec, from_lib: "kernel/src/inet_dns.hrl")
  keys = record |> Enum.map(fn {n, _} -> n end)
  vals = keys |> Enum.map(&{&1, [], nil})
  pairs = Enum.zip(keys, vals)

  defstruct record
  @type t :: %__MODULE__{}

  @doc """
  Converts a `GSMLGDNS.Record` struct to a `:dns_rec` record.
  """
  def to_record(struct) do
    header = GSMLGDNS.Header.to_record(struct.header)
    queries = Enum.map(struct.qdlist, &GSMLGDNS.Query.to_record/1)
    answers = Enum.map(struct.anlist, &GSMLGDNS.Resource.to_record/1)
    additional = Enum.map(struct.arlist, &GSMLGDNS.Resource.to_record/1)

    _to_record(%{struct | header: header, qdlist: queries, anlist: answers, arlist: additional})
  end

  defp _to_record(%GSMLGDNS.Record{unquote_splicing(pairs)}) do
    {:dns_rec, unquote_splicing(vals)}
  end

  @doc """
  Converts a `:dns_rec` record into a `GSMLGDNS.Record`.
  """
  def from_record(dns_rec)

  def from_record({:dns_rec, unquote_splicing(vals)}) do
    struct = %GSMLGDNS.Record{unquote_splicing(pairs)}

    header = GSMLGDNS.Header.from_record(struct.header)
    queries = Enum.map(struct.qdlist, &GSMLGDNS.Query.from_record(&1))

    answers =
      Enum.map(struct.anlist, &GSMLGDNS.Resource.from_record(&1))
      |> Enum.reject(&is_nil/1)

    additional =
      Enum.map(struct.arlist, &GSMLGDNS.Resource.from_record(&1))
      |> Enum.reject(&is_nil/1)

    %{struct | header: header, qdlist: queries, anlist: answers, arlist: additional}
  end

  @doc """
  Decodes a binary record into a `GSMLGDNS.Record` struct.
  """
  @spec decode(binary) :: GSMLGDNS.Record.t()
  def decode(data) do
    {:ok, record} = :inet_dns.decode(data)
    from_record(record)
  end

  @doc """
  Serializes a `GSMLGDNS.Record` into its binary representation.
  """
  def encode(struct) do
    :inet_dns.encode(to_record(struct))
  end
end
