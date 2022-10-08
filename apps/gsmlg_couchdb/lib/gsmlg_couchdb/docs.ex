defmodule GSMLG_CouchDB.Docs do
  alias GSMLG_CouchDB.Connection

  def create_doc(db_name, doc) do
    check_name!(db_name)
    Connection.post!("/" <> db_name, doc)
  end

  def get_doc(db_name, doc_id) do
    check_name!(db_name)
    Connection.get!("/" <> db_name <> "/" <> doc_id)
  end

  def put_doc(db_name, doc_id, doc) do
    check_name!(db_name)
    Connection.put!("/" <> db_name <> "/" <> doc_id, doc)
  end

  def delete_doc(db_name, doc_id) do
    check_name!(db_name)
    Connection.delete!("/" <> db_name <> "/" <> doc_id)
  end

  def copy_doc(db_name, doc_id, dest_id) do
    check_name!(db_name)
    Connection.copy!("/" <> db_name <> "/" <> doc_id, nil, [{"Destination", dest_id}])
  end

  def all_docs(db_name) do
    check_name!(db_name)
    Connection.get!("/#{db_name}/_all_docs")
  end

  def all_docs(db_name, params) do
    check_name!(db_name)
    Connection.post!("/#{db_name}/_all_docs", params)
  end

  def all_docs_queries(db_name, params) when is_list(params) do
    check_name!(db_name)
    Connection.post!("/#{db_name}/_all_docs/query", %{queries: params})
  end

  def design_docs(db_name) do
    check_name!(db_name)
    Connection.get!("/#{db_name}/_design_docs")
  end

  def design_docs(db_name, params) do
    check_name!(db_name)
    Connection.post!("/#{db_name}/_design_docs", params)
  end

  def bulk_get(db_name, params) do
    check_name!(db_name)
    Connection.post!("/#{db_name}/_bulk_get", %{docs: params})
  end

  def bulk_docs(db_name, params) do
    check_name!(db_name)
    Connection.post!("/#{db_name}/_bulk_docs", %{docs: params})
  end

  @doc """
  `keys` of params
  * selector (json) – JSON object describing criteria used to select documents. More information provided in the section on selector syntax. Required
  * limit (number) – Maximum number of results returned. Default is 25. Optional
  * skip (number) – Skip the first ‘n’ results, where ‘n’ is the value specified. Optional
  * sort (json) – JSON array following sort syntax. Optional
  * fields (array) – JSON array specifying which fields of each object should be returned. If it is omitted, the entire object is returned. More information provided in the section on filtering fields. Optional
  * use_index (string|array) – Instruct a query to use a specific index. Specified either as "<design_document>" or ["<design_document>", "<index_name>"]. Optional
  * conflicts (boolean) – Include conflicted documents if true. Intended use is to easily find conflicted documents, without an index or view. Default is false. Optional
  * r (number) – Read quorum needed for the result. This defaults to 1, in which case the document found in the index is returned. If set to a higher value, each document is read from at least that many replicas before it is returned in the results. This is likely to take more time than using only the document stored locally with the index. Optional, default: 1
  * bookmark (string) – A string that enables you to specify which page of results you require. Used for paging through result sets. Every query returns an opaque string under the bookmark key that can then be passed back in a query to get the next page of results. If any part of the selector query changes between requests, the results are undefined. Optional, default: null
  * update (boolean) – Whether to update the index prior to returning the result. Default is true. Optional
  * stable (boolean) – Whether or not the view results should be returned from a “stable” set of shards. Optional
  * stale (string) – Combination of update=false and stable=true options. Possible options: "ok", false (default). Optional Note that this parameter is deprecated. Use stable and update instead. See Views Generation for more details.
  * execution_stats (boolean) – Include execution statistics in the query response. Optional, default: false
  """
  def find(db_name, params) do
    check_name!(db_name)
    Connection.post!("/#{db_name}/_find", %{docs: params})
  end

  @doc """
  Mango is a declarative JSON querying language for CouchDB databases.
  Mango wraps several index types, starting with the Primary Index out-of-the-box.
  Mango indexes, with index type json, are built using MapReduce Views.
  """
  def create_index(db_name, params) do
    check_name!(db_name)
    Connection.post!("/#{db_name}/_index", params)
  end

  def get_index(db_name, params) do
    check_name!(db_name)
    Connection.get!("/#{db_name}/_index", params)
  end

  # DELETE /db/_index/_design/a5f4711fc9448864a13c81dc71e660b524d7410c/json/foo-index
  def delete_index(db_name, design_doc, index_name) do
    check_name!(db_name)
    Connection.delete!("/#{db_name}/_index/_design/#{design_doc}/json/#{index_name}")
  end

  @doc """
  explain which index is used, params is as same as find
  """
  def explain_query(db_name, params) do
    check_name!(db_name)
    Connection.post!("/#{db_name}/_explain", params)
  end

  def attachment_exists?(db_name, docid, attachment_name, params \\ %{}, headers \\ []) do
    check_name!(db_name)
    200 == Connection.head!("/#{db_name}/#{docid}/#{attachment_name}", params, headers)
  end

  def get_attachment(db_name, docid, attachment_name, params \\ %{}, headers \\ []) do
    check_name!(db_name)
    Connection.get!("/#{db_name}/#{docid}/#{attachment_name}", params, headers)
  end

  def put_attachment(
        db_name,
        docid,
        attachment_name,
        data \\ %{},
        headers \\ [{"Content-Type", "application/octet-stream"}]
      ) do
    check_name!(db_name)
    Connection.put!("/#{db_name}/#{docid}/#{attachment_name}", data, headers)
  end

  def delete_attachment(db_name, docid, attachment_name, params \\ %{}, headers \\ []) do
    check_name!(db_name)
    Connection.delete!("/#{db_name}/#{docid}/#{attachment_name}", params, headers)
  end

  defp check_name(db_name) do
    ~r/^[a-z][a-z0-9_\$\(\)\+\/\-]*$/ |> Regex.match?(db_name)
  end

  defp check_name!(db_name) do
    if check_name(db_name) do
      :ok
    else
      raise "db name invalid"
    end
  end
end
