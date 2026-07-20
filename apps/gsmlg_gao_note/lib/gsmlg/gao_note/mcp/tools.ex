defmodule GSMLG.GaoNote.MCP.Tools do
  @moduledoc false

  alias Backplane.McpProtocol.Server.Response
  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.MCP.Authorization
  alias GSMLG.GaoNote.Presenter

  @readonly_tools ~w(
    gao_note.search
    gao_note.get
    gao_note.get_attachment_with_content
    gao_note.list_label_settings
  )

  @admin_tools @readonly_tools ++
                 ~w(
                   gao_note.create_note
                   gao_note.create_label_setting
                   gao_note.update_note
                   gao_note.delete
                   gao_note.set_labels
                   gao_note.put_attachment
                   gao_note.delete_attachment
                 )

  @attachment_input_fields %{
    id: {:required, :string},
    path: {:required, :string},
    mime: {:required, :string},
    description: {:string, {:default, ""}},
    content: :string,
    content_base64: :string
  }
  @strict_attachment_map_schema {:schema, @attachment_input_fields,
                                 {:additional_keys,
                                  {:required,
                                   {:custom,
                                    {__MODULE__,
                                     :reject_additional_attachment_field}}}}}
  @strict_attachment_input_fields {:custom, {__MODULE__, :validate_attachment_input}}
  @strict_base64_pattern "^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$"

  @attachment_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "properties" => %{
      "id" => %{
        "type" => "string",
        "description" => "Globally unique ID for this new initial attachment."
      },
      "path" => %{
        "type" => "string",
        "description" =>
          "Canonical note-relative path. Use data.txt here when markdown references ./data.txt."
      },
      "mime" => %{
        "type" => "string",
        "description" =>
          "Expected MIME type. The server verifies file bytes and returns the verified MIME type."
      },
      "description" => %{
        "type" => "string",
        "default" => "",
        "description" => "Optional attachment description."
      },
      "content" => %{
        "type" => "string",
        "description" =>
          "Optional raw attachment content. New attachments require content or content_base64."
      },
      "content_base64" => %{
        "type" => "string",
        "contentEncoding" => "base64",
        "pattern" => @strict_base64_pattern,
        "description" =>
          "Optional strict standard padded Base64 content. Do not send with content."
      }
    },
    "required" => ~w(id path mime),
    "oneOf" => [
      %{
        "required" => ["content"],
        "not" => %{"required" => ["content_base64"]}
      },
      %{
        "required" => ["content_base64"],
        "not" => %{"required" => ["content"]}
      }
    ]
  }

  @put_attachment_input_fields %{
    note_id: {:required, :string},
    attachment_id: {:required, :string},
    path: {:required, :string},
    mime: {:required, :string},
    description: {:required, :string},
    update_content: {:required, :boolean},
    content: :string,
    content_base64: :string
  }
  @strict_put_attachment_map_schema {:schema, @put_attachment_input_fields,
                                     {:additional_keys,
                                      {:required,
                                       {:custom,
                                        {__MODULE__,
                                         :reject_additional_attachment_field}}}}}
  @strict_put_attachment_input_fields {:custom,
                                       {__MODULE__, :validate_put_attachment_input}}

  @input_fields %{
    "gao_note.search" => [
      {:query, :string,
       [description: "Search text matched against note title and markdown content."]},
      {:label, :string, [description: "Optional label key or key=value filter."]},
      {:limit, :integer, [description: "Maximum notes to return."]},
      {:offset, :integer, [description: "Number of notes to skip."]}
    ],
    "gao_note.get" => [
      {:id, :string, [required: true, description: "GaoNote id."]}
    ],
    "gao_note.get_attachment_with_content" => [
      {:note_id, :string, [required: true, description: "GaoNote id."]},
      {:attachment_id, :string,
       [required: true, description: "Globally unique attachment ID."]}
    ],
    "gao_note.list_label_settings" => [],
    "gao_note.create_note" => [
      {:title, :string, [required: true, description: "Note title."]},
      {:content, :string, [required: true, description: "Markdown note content."]},
      {:labels, {:list, :string},
       [description: "Optional labels as key=value strings. Missing label keys are created."]},
      {:attachments, {:list, @strict_attachment_input_fields},
       [
         description:
           "Optional complete attachment list. Defaults to an empty list. New attachments require content or content_base64."
       ]}
    ],
    "gao_note.create_label_setting" => [
      {:name, :string, [required: true, description: "Label key."]},
      {:color, :string, [description: "Optional label color, for example #1f6feb."]},
      {:description, :string, [description: "Optional label key description."]},
      {:value_type, :string,
       [
         description:
           "Label value type: text, number, version, date, date-time, time, year, year-month, or year-season."
       ]}
    ],
    "gao_note.update_note" => [
      {:id, :string, [required: true, description: "Globally unique GaoNote ID."]},
      {:title, :string, [description: "Updated note title."]},
      {:content, :string, [description: "Updated markdown note content."]},
      {:labels, {:list, :string},
       [description: "Replacement labels as key=value strings. Missing label keys are created."]},
    ],
    "gao_note.delete" => [
      {:id, :string, [required: true, description: "GaoNote id."]}
    ],
    "gao_note.set_labels" => [
      {:id, :string, [required: true, description: "GaoNote id."]},
      {:labels, {:list, :string},
       [required: true, description: "Replacement labels as key=value strings."]}
    ],
    "gao_note.put_attachment" => [
      {:note_id, :string, [required: true, description: "GaoNote id."]},
      {:attachment_id, :string,
       [required: true, description: "Globally unique attachment ID."]},
      {:path, :string, [required: true, description: "Canonical note-relative path."]},
      {:mime, :string, [required: true, description: "Expected MIME type."]},
      {:description, :string, [required: true, description: "Attachment description."]},
      {:update_content, :boolean,
       [
         required: true,
         description:
           "Whether to replace stored content. False forbids content fields; true requires exactly one."
       ]},
      {:content, :string,
       [description: "Raw replacement content. Use only when update_content is true."]},
      {:content_base64, :string,
       [
         description:
           "Strict standard padded Base64 replacement content. Use only when update_content is true."
       ]}
    ],
    "gao_note.delete_attachment" => [
      {:note_id, :string, [required: true, description: "GaoNote id."]},
      {:attachment_id, :string,
       [required: true, description: "Globally unique attachment ID."]}
    ]
  }

  def readonly_tools, do: @readonly_tools
  def admin_tools, do: @admin_tools

  def input_fields(name), do: Map.fetch!(@input_fields, name)

  @doc false
  def reject_additional_attachment_field(_value),
    do: {:error, "unsupported attachment field", []}

  @doc false
  def reject_additional_note_field(_value),
    do: {:error, "unsupported note field", []}

  @doc false
  def validate_attachment_input(attachment) when is_map(attachment) do
    with {:ok, _attachment} <- Peri.validate(@strict_attachment_map_schema, attachment),
         :ok <- validate_attachment_content(attachment),
         {:ok, attachment} <- Peri.validate(@attachment_input_fields, attachment) do
      {:ok, attachment}
    end
  end

  def validate_attachment_input(_attachment),
    do: {:error, "attachment must be an object", []}

  @doc false
  def validate_put_attachment_input(args) when is_map(args) do
    with {:ok, args} <- Peri.validate(@strict_put_attachment_map_schema, args),
         :ok <- validate_put_attachment_content(args) do
      {:ok, args}
    end
  end

  def validate_put_attachment_input(_args),
    do: {:error, "attachment input must be an object", []}

  def input_schema("gao_note.get_attachment_with_content") do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "note_id" => %{"type" => "string", "description" => "GaoNote id."},
        "attachment_id" => %{
          "type" => "string",
          "description" => "Globally unique attachment ID."
        }
      },
      "required" => ~w(note_id attachment_id)
    }
  end

  def input_schema("gao_note.create_note") do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "title" => %{"type" => "string", "description" => "Note title."},
        "content" => %{
          "type" => "string",
          "description" => "Markdown note content."
        },
        "labels" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" =>
            "Optional labels as key=value strings. Missing label keys are created."
        },
        "attachments" => %{
          "type" => "array",
          "items" => @attachment_input_schema,
          "default" => [],
          "description" =>
            "Optional complete attachment list. Defaults to an empty list. New attachments require content or content_base64."
        }
      },
      "required" => ~w(title content)
    }
  end

  def input_schema("gao_note.update_note") do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "id" => %{
          "type" => "string",
          "description" => "Globally unique GaoNote ID."
        },
        "title" => %{"type" => "string", "description" => "Updated note title."},
        "content" => %{
          "type" => "string",
          "description" => "Updated markdown note content."
        },
        "labels" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" =>
            "Replacement labels as key=value strings. Missing label keys are created."
        }
      },
      "required" => ~w(id)
    }
  end

  def input_schema("gao_note.put_attachment") do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "note_id" => %{"type" => "string", "description" => "GaoNote id."},
        "attachment_id" => %{
          "type" => "string",
          "description" => "Globally unique attachment ID."
        },
        "path" => %{
          "type" => "string",
          "description" => "Canonical note-relative path."
        },
        "mime" => %{"type" => "string", "description" => "Expected MIME type."},
        "description" => %{
          "type" => "string",
          "description" => "Attachment description."
        },
        "update_content" => %{
          "type" => "boolean",
          "description" =>
            "Whether to replace stored content. False forbids content fields; true requires exactly one."
        },
        "content" => %{
          "type" => "string",
          "description" => "Raw replacement content. Use only when update_content is true."
        },
        "content_base64" => %{
          "type" => "string",
          "contentEncoding" => "base64",
          "pattern" => @strict_base64_pattern,
          "description" =>
            "Strict standard padded Base64 replacement content. Use only when update_content is true."
        }
      },
      "required" => ~w(note_id attachment_id path mime description update_content),
      "oneOf" => [
        %{
          "properties" => %{"update_content" => %{"const" => false}},
          "not" => %{
            "anyOf" => [
              %{"required" => ["content"]},
              %{"required" => ["content_base64"]}
            ]
          }
        },
        %{
          "properties" => %{"update_content" => %{"const" => true}},
          "oneOf" => [
            %{
              "required" => ["content"],
              "not" => %{"required" => ["content_base64"]}
            },
            %{
              "required" => ["content_base64"],
              "not" => %{"required" => ["content"]}
            }
          ]
        }
      ]
    }
  end

  def input_schema("gao_note.delete_attachment") do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "note_id" => %{"type" => "string", "description" => "GaoNote id."},
        "attachment_id" => %{
          "type" => "string",
          "description" => "Globally unique attachment ID."
        }
      },
      "required" => ~w(note_id attachment_id)
    }
  end

  def execute(name, params, frame) do
    args = default_arguments(name, stringify_keys(params || %{}))

    response =
      try do
        with {:ok, args} <- validate_aggregate_arguments(name, args) do
          name
          |> dispatch(args, frame, mode(frame))
          |> ensure_response()
        else
          {:error, reason} -> error(reason)
        end
      rescue
        exception ->
          log_tool_failure(name, :error, exception, __STACKTRACE__)
          error("#{name} failed unexpectedly. Check GaoNote MCP server logs.")
      catch
        kind, reason ->
          log_tool_failure(name, kind, reason, __STACKTRACE__)
          error("#{name} failed unexpectedly. Check GaoNote MCP server logs.")
      end

    {:reply, response, frame}
  end

  def description("gao_note.search"), do: "Search GaoNote notes."
  def description("gao_note.get"), do: "Get a GaoNote by id."

  def description("gao_note.get_attachment_with_content"),
    do: "Get GaoNote attachment metadata and Base64-encoded content."

  def description("gao_note.list_label_settings"), do: "List GaoNote label settings."
  def description("gao_note.create_note"), do: "Create a GaoNote and its complete attachment list."

  def description("gao_note.create_label_setting"),
    do:
      "Create a GaoNote label setting by key. Label keys are also created automatically when notes use new labels."

  def description("gao_note.update_note"),
    do: "Update GaoNote title, markdown content, and/or labels."

  def description("gao_note.delete"), do: "Delete a GaoNote."

  def description("gao_note.set_labels"),
    do: "Replace GaoNote labels with an array of key=value strings."

  def description("gao_note.put_attachment"),
    do:
      "Replace an existing attachment owned by the identified GaoNote. This tool never creates or transfers an attachment."

  def description("gao_note.delete_attachment"),
    do: "Delete one GaoNote attachment."

  def annotations(name) do
    cond do
      name in @readonly_tools ->
        %{
          "readOnlyHint" => true,
          "destructiveHint" => false,
          "idempotentHint" => true,
          "openWorldHint" => false
        }

      name == "gao_note.delete" ->
        %{
          "readOnlyHint" => false,
          "destructiveHint" => true,
          "idempotentHint" => false,
          "openWorldHint" => false
        }

      name == "gao_note.put_attachment" ->
        %{
          "readOnlyHint" => false,
          "destructiveHint" => true,
          "idempotentHint" => true,
          "openWorldHint" => false
        }

      name == "gao_note.delete_attachment" ->
        %{
          "readOnlyHint" => false,
          "destructiveHint" => true,
          "idempotentHint" => true,
          "openWorldHint" => false
        }

      true ->
        %{
          "readOnlyHint" => false,
          "destructiveHint" => false,
          "idempotentHint" => false,
          "openWorldHint" => false
        }
    end
  end

  defp dispatch("gao_note.search", args, _frame, mode) do
    query = Map.get(args, "query", Map.get(args, "search", ""))
    opts = list_opts(args, mode)
    notes = GaoNote.search_notes(query, opts)

    ok("Found #{length(notes)} GaoNote notes", %{
      "notes" => Enum.map(notes, &Presenter.note_summary/1)
    })
  end

  defp dispatch("gao_note.get", args, _frame, mode) do
    case fetch_note(args, mode) do
      nil -> error("GaoNote not found")
      note -> ok("GaoNote: #{note.title}", %{"note" => Presenter.note(note)})
    end
  end

  defp dispatch("gao_note.get_attachment_with_content", args, _frame, mode) do
    note_args = %{"id" => Map.get(args, "note_id")}

    with %{} = note <- fetch_note(note_args, mode),
         {:ok, attachment, raw_bytes} <-
           GaoNote.get_attachment_with_content(note.id, Map.get(args, "attachment_id")) do
      presented_attachment =
        attachment
        |> Presenter.attachment()
        |> Map.put("content_base64", Base.encode64(raw_bytes))

      ok("Retrieved GaoNote attachment", %{"attachment" => presented_attachment})
    else
      nil -> error("GaoNote not found")
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch("gao_note.list_label_settings", _args, _frame, _mode) do
    label_settings = GaoNote.list_label_settings()

    ok("Found #{length(label_settings)} GaoNote label settings", %{
      "label_settings" => Enum.map(label_settings, &Presenter.label_setting/1)
    })
  end

  defp dispatch("gao_note.create_note", args, frame, _mode) do
    with {:ok, actor} <- Authorization.actor(frame),
         {:ok, note} <- GaoNote.create_note(args, mcp_actor(actor)) do
      audit("gao_note.create_note", actor, note.id)
      ok("Created GaoNote: #{note.title}", %{"note" => Presenter.note(note)})
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch("gao_note.create_label_setting", args, frame, _mode) do
    with {:ok, actor} <- Authorization.actor(frame),
         {:ok, label_setting} <-
           GaoNote.create_label_setting(label_setting_attrs(args), mcp_actor(actor)) do
      audit("gao_note.create_label_setting", actor, nil)

      ok("Created GaoNote label setting: #{label_setting.name}", %{
        "label_setting" => Presenter.label_setting(label_setting)
      })
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch("gao_note.update_note", args, frame, _mode) do
    with {:ok, actor} <- Authorization.actor(frame),
         %{} = note <- GaoNote.get_note(Map.get(args, "id")),
         attrs <- Map.drop(args, ["id"]),
         {:ok, note} <- GaoNote.update_note_fields(note, attrs, mcp_actor(actor)) do
      audit("gao_note.update_note", actor, note.id)
      ok("Updated GaoNote: #{note.title}", %{"note" => Presenter.note(note)})
    else
      nil -> error("GaoNote not found")
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch("gao_note.put_attachment", args, frame, _mode) do
    note_id = Map.get(args, "note_id")
    attachment_id = Map.get(args, "attachment_id")
    attrs = Map.drop(args, ["note_id", "attachment_id"])

    with {:ok, actor} <- Authorization.actor(frame),
         {:ok, attachment} <-
           GaoNote.put_attachment(note_id, attachment_id, attrs, mcp_actor(actor)) do
      audit("gao_note.put_attachment", actor, note_id)
      ok("Stored GaoNote attachment", %{"attachment" => Presenter.attachment(attachment)})
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch("gao_note.delete_attachment", args, frame, _mode) do
    note_id = Map.get(args, "note_id")
    attachment_id = Map.get(args, "attachment_id")

    with {:ok, actor} <- Authorization.actor(frame),
         {:ok, deleted} <-
           GaoNote.delete_attachment(note_id, attachment_id, mcp_actor(actor)) do
      audit("gao_note.delete_attachment", actor, note_id)
      ok("Deleted GaoNote attachment", %{"attachment" => Presenter.attachment(deleted)})
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch("gao_note.delete", args, frame, _mode) do
    with {:ok, actor} <- Authorization.actor(frame),
         %{} = note <- GaoNote.get_note(Map.get(args, "id")),
         {:ok, deleted} <- GaoNote.delete_note(note, mcp_actor(actor)) do
      audit("gao_note.delete", actor, deleted.id)
      ok("Deleted GaoNote: #{deleted.title}", %{"note" => Presenter.note(deleted)})
    else
      nil -> error("GaoNote not found")
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch("gao_note.set_labels", args, frame, _mode) do
    with {:ok, actor} <- Authorization.actor(frame),
         %{} = note <- GaoNote.get_note(Map.get(args, "id")),
         {:ok, note} <-
           GaoNote.set_labels(note, Map.get(args, "labels", []), mcp_actor(actor)) do
      audit("gao_note.set_labels", actor, note.id)
      ok("Updated GaoNote labels: #{note.title}", %{"note" => Presenter.note(note)})
    else
      nil -> error("GaoNote not found")
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(name, _args, _frame, mode), do: error("Tool unavailable in #{mode} mode: #{name}")

  defp fetch_note(args, :readonly) do
    cond do
      id = Map.get(args, "id") -> GaoNote.get_public_note(id)
      true -> nil
    end
  end

  defp fetch_note(args, :admin) do
    cond do
      id = Map.get(args, "id") -> GaoNote.get_note(id)
      true -> nil
    end
  end

  defp list_opts(args, :readonly) do
    [
      label: Map.get(args, "label"),
      limit: Map.get(args, "limit"),
      offset: Map.get(args, "offset")
    ]
  end

  defp list_opts(args, :admin) do
    [
      label: Map.get(args, "label"),
      limit: Map.get(args, "limit"),
      offset: Map.get(args, "offset")
    ]
  end

  defp default_arguments("gao_note.create_note", args),
    do: Map.put_new(args, "attachments", [])

  defp default_arguments(_name, args), do: args

  defp validate_aggregate_arguments("gao_note.create_note", args) do
    case Map.fetch(args, "attachments") do
      {:ok, attachments} ->
        with {:ok, attachments} <- validate_attachments(attachments) do
          {:ok, Map.put(args, "attachments", stringify_keys(attachments))}
        end

      :error ->
        {:ok, args}
    end
  end

  defp validate_aggregate_arguments("gao_note.update_note", args) do
    case Map.keys(args) -- ~w(id title content labels) do
      [] -> {:ok, args}
      [field | _rest] -> {:error, "unsupported note field: #{field}"}
    end
  end

  defp validate_aggregate_arguments("gao_note.put_attachment", args) do
    case Peri.validate(@strict_put_attachment_input_fields, args) do
      {:ok, args} -> {:ok, stringify_keys(args)}
      {:error, errors} -> {:error, Presenter.error_text(errors)}
    end
  end

  defp validate_aggregate_arguments(_name, args), do: {:ok, args}

  defp validate_attachments(attachments) when is_list(attachments) do
    attachments
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {attachment, index}, {:ok, validated} ->
      case Peri.validate(@strict_attachment_input_fields, attachment) do
        {:ok, attachment} ->
          {:cont, {:ok, [attachment | validated]}}

        {:error, errors} ->
          {:halt, {:error, "attachments[#{index}] #{Presenter.error_text(errors)}"}}
      end
    end)
    |> case do
      {:ok, validated} -> {:ok, Enum.reverse(validated)}
      {:error, _reason} = error -> error
    end
  end

  defp validate_attachments(_attachments),
    do: {:error, "attachments must be an array of attachment objects"}

  defp validate_attachment_content(attachment) do
    has_content? = attachment_has_key?(attachment, :content)
    has_content_base64? = attachment_has_key?(attachment, :content_base64)
    content = attachment_value(attachment, :content)
    content_base64 = attachment_value(attachment, :content_base64)

    cond do
      has_content? and is_nil(content) ->
        {:error, "content must be a string", []}

      has_content_base64? and is_nil(content_base64) ->
        {:error, "content_base64 must be a string", []}

      has_content? and has_content_base64? ->
        {:error, "must contain only one of content or content_base64", []}

      not has_content? and not has_content_base64? ->
        {:error, "must contain exactly one of content or content_base64", []}

      has_content_base64? and not strict_base64?(content_base64) ->
        {:error, "content_base64 must be strict standard padded Base64", []}

      true ->
        :ok
    end
  end

  defp validate_put_attachment_content(args) do
    has_content? = attachment_has_key?(args, :content)
    has_content_base64? = attachment_has_key?(args, :content_base64)

    case attachment_value(args, :update_content) do
      false when has_content? or has_content_base64? ->
        {:error, "update_content=false forbids content and content_base64", []}

      false ->
        :ok

      true when has_content? == has_content_base64? ->
        {:error, "update_content=true requires exactly one of content or content_base64", []}

      true ->
        validate_attachment_content(args)
    end
  end

  defp attachment_has_key?(attachment, key) do
    Map.has_key?(attachment, key) or Map.has_key?(attachment, Atom.to_string(key))
  end

  defp attachment_value(attachment, key) do
    if Map.has_key?(attachment, key) do
      Map.get(attachment, key)
    else
      Map.get(attachment, Atom.to_string(key))
    end
  end

  defp strict_base64?(value) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, decoded} -> Base.encode64(decoded) == value
      :error -> false
    end
  end

  defp strict_base64?(_value), do: false

  defp label_setting_attrs(args) do
    %{
      "name" => Map.get(args, "name", Map.get(args, "label_setting")),
      "color" => Map.get(args, "color"),
      "description" => Map.get(args, "description"),
      "value_type" => Map.get(args, "value_type")
    }
  end

  defp ok(text, structured_content) do
    Response.tool()
    |> Response.text(text)
    |> Response.structured(structured_content)
  end

  defp error(reason) do
    text =
      case reason do
        binary when is_binary(binary) -> binary
        other -> Presenter.error_text(other)
      end

    Response.tool()
    |> Response.error(text)
  end

  defp ensure_response(%Response{} = response), do: response
  defp ensure_response(other), do: error(other)

  defp mode(%{assigns: %{mode: :admin}}), do: :admin
  defp mode(%{assigns: %{"mode" => "admin"}}), do: :admin
  defp mode(_frame), do: :readonly

  defp mcp_actor(%{id: id}) when not is_nil(id), do: %{id: id, source: "mcp"}
  defp mcp_actor(%{"id" => id}) when not is_nil(id), do: %{id: id, source: "mcp"}
  defp mcp_actor(actor), do: actor

  defp stringify_keys(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(values) when is_list(values), do: Enum.map(values, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp audit(tool_name, actor, note_id) do
    GSMLG.Telemetry.info("GaoNote MCP tool call",
      metadata: %{
        tool: tool_name,
        actor_id: actor_id(actor),
        note_id: note_id
      }
    )
  end

  defp actor_id(%{id: id}), do: id
  defp actor_id(%{"id" => id}), do: id
  defp actor_id(_actor), do: nil

  defp log_tool_failure(tool_name, kind, reason, stacktrace) do
    GSMLG.Telemetry.error("GaoNote MCP tool failed",
      metadata: %{
        tool: tool_name,
        kind: kind,
        error: failure_message(reason),
        stacktrace: Exception.format(kind, reason, stacktrace)
      }
    )
  end

  defp failure_message(%{__exception__: true} = exception), do: Exception.message(exception)
  defp failure_message(reason), do: inspect(reason)
end

defmodule GSMLG.GaoNote.MCP.ToolComponent do
  @moduledoc false

  defmacro __using__(opts) do
    name = Keyword.fetch!(opts, :name)
    description = GSMLG.GaoNote.MCP.Tools.description(name)
    schema_block = schema_block(name)
    input_schema_override = input_schema_override(name)

    quote do
      @moduledoc unquote(description)

      use Backplane.McpProtocol.Server.Component, type: :tool

      unquote(schema_block)
      unquote(input_schema_override)

      @impl true
      def annotations, do: GSMLG.GaoNote.MCP.Tools.annotations(unquote(name))

      @impl true
      def execute(params, frame),
        do: GSMLG.GaoNote.MCP.Tools.execute(unquote(name), params, frame)
    end
  end

  defp input_schema_override(name)
       when name in [
              "gao_note.create_note",
              "gao_note.update_note",
              "gao_note.get_attachment_with_content",
              "gao_note.put_attachment",
              "gao_note.delete_attachment"
            ] do
    quote do
      defoverridable input_schema: 0

      @impl true
      def input_schema, do: GSMLG.GaoNote.MCP.Tools.input_schema(unquote(name))
    end
  end

  defp input_schema_override(_name), do: quote(do: nil)

  defp schema_block("gao_note.put_attachment") do
    schema =
      {:custom, {GSMLG.GaoNote.MCP.Tools, :validate_put_attachment_input}}

    quote do
      import Peri

      @doc false
      def __mcp_raw_schema__, do: unquote(Macro.escape(schema))

      defschema(:mcp_schema, unquote(Macro.escape(schema)))
    end
  end

  defp schema_block(name)
       when name in [
              "gao_note.create_note",
              "gao_note.update_note",
              "gao_note.get_attachment_with_content",
              "gao_note.delete_attachment"
            ] do
    fields =
      name
      |> GSMLG.GaoNote.MCP.Tools.input_fields()
      |> Map.new(fn {field_name, type, opts} ->
        {field_name, Backplane.McpProtocol.Server.Component.__build_field__(type, opts)}
      end)

    rejector =
      if name in ["gao_note.create_note", "gao_note.update_note"] do
        :reject_additional_note_field
      else
        :reject_additional_attachment_field
      end

    schema =
      {:schema, fields,
       {:additional_keys,
        {:required,
         {:custom, {GSMLG.GaoNote.MCP.Tools, rejector}}}}}

    quote do
      import Peri

      @doc false
      def __mcp_raw_schema__, do: unquote(Macro.escape(schema))

      defschema(:mcp_schema, unquote(Macro.escape(schema)))
    end
  end

  defp schema_block(name) do
    case GSMLG.GaoNote.MCP.Tools.input_fields(name) do
      [] ->
        quote do
          schema do
            %{}
          end
        end

      fields ->
        field_asts =
          Enum.map(fields, fn {field_name, type, opts} ->
            quote do
              field(unquote(field_name), unquote(Macro.escape(type)), unquote(Macro.escape(opts)))
            end
          end)

        quote do
          schema do
            (unquote_splicing(field_asts))
          end
        end
    end
  end
end

defmodule GSMLG.GaoNote.MCP.Tools.Search do
  use GSMLG.GaoNote.MCP.ToolComponent, name: "gao_note.search"
end

defmodule GSMLG.GaoNote.MCP.Tools.Get do
  use GSMLG.GaoNote.MCP.ToolComponent, name: "gao_note.get"
end

defmodule GSMLG.GaoNote.MCP.Tools.GetAttachmentWithContent do
  use GSMLG.GaoNote.MCP.ToolComponent, name: "gao_note.get_attachment_with_content"
end

defmodule GSMLG.GaoNote.MCP.Tools.ListLabelSettings do
  use GSMLG.GaoNote.MCP.ToolComponent, name: "gao_note.list_label_settings"
end

defmodule GSMLG.GaoNote.MCP.Tools.CreateNote do
  use GSMLG.GaoNote.MCP.ToolComponent, name: "gao_note.create_note"
end

defmodule GSMLG.GaoNote.MCP.Tools.CreateLabelSetting do
  use GSMLG.GaoNote.MCP.ToolComponent, name: "gao_note.create_label_setting"
end

defmodule GSMLG.GaoNote.MCP.Tools.UpdateNote do
  use GSMLG.GaoNote.MCP.ToolComponent, name: "gao_note.update_note"
end

defmodule GSMLG.GaoNote.MCP.Tools.Delete do
  use GSMLG.GaoNote.MCP.ToolComponent, name: "gao_note.delete"
end

defmodule GSMLG.GaoNote.MCP.Tools.SetLabels do
  use GSMLG.GaoNote.MCP.ToolComponent, name: "gao_note.set_labels"
end

defmodule GSMLG.GaoNote.MCP.Tools.PutAttachment do
  use GSMLG.GaoNote.MCP.ToolComponent, name: "gao_note.put_attachment"
end

defmodule GSMLG.GaoNote.MCP.Tools.DeleteAttachment do
  use GSMLG.GaoNote.MCP.ToolComponent, name: "gao_note.delete_attachment"
end
