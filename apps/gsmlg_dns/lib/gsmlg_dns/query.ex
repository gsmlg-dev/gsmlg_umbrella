defmodule GSMLGDNS.Query do
  @moduledoc """
  Struct definition for serializing and parsing GSMLGDNS query.
  """

  record = Record.extract(:dns_query, from_lib: "kernel/src/inet_dns.hrl")
  keys = record |> Enum.map(fn {n, _} -> n end)
  vals = keys |> Enum.map(&{&1, [], nil})
  pairs = Enum.zip(keys, vals)

  defstruct record
  @type t :: %__MODULE__{}

  @doc """
  Converts a `GSMLGDNS.Query` struct to a `:dns_query` record.
  """
  def to_record(%GSMLGDNS.Query{unquote_splicing(pairs)}) do
    {:dns_query, unquote_splicing(vals)}
  end

  @doc """
  Converts a `:dns_query` record into a `GSMLGDNS.Query`.
  """
  def from_record(file_info)

  def from_record({:dns_query, unquote_splicing(vals)}) do
    %GSMLGDNS.Query{unquote_splicing(pairs)}
  end
end
