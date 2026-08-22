defmodule GSMLG.Web.OpenApi.Schemas do
  @moduledoc false

  def components do
    %{
      "schemas" => schemas(),
      "securitySchemes" => %{
        "bearerAuth" => %{
          "type" => "http",
          "scheme" => "bearer",
          "bearerFormat" => "JWT",
          "description" => "Guardian access token"
        }
      }
    }
  end

  defp schemas do
    %{
      "ApiError" =>
        object(
          %{"errors" => free_object()},
          ["errors"]
        ),
      "AuthError" =>
        object(
          %{"message" => string()},
          ["message"]
        ),
      "Blog" =>
        object(
          %{
            "id" => %{"type" => "integer"},
            "title" => string(),
            "date" => string("date"),
            "author" => string(),
            "content" => string(),
            "slug" => string()
          },
          ["id", "title", "date", "author", "content", "slug"]
        ),
      "BlogList" =>
        object(
          %{"data" => array(ref("Blog"))},
          ["data"]
        ),
      "Label" =>
        object(
          %{
            "key" => string(),
            "value" => string(),
            "value_type" => string(),
            "description" => string(),
            "status" => Map.put(string(), "enum", ["valid", "invalid"]),
            "errors" => array(string())
          },
          ["key", "value", "value_type", "description", "status", "errors"]
        ),
      "LabelSetting" =>
        object(
          %{
            "id" => string("uuid"),
            "name" => string(),
            "key" => string(),
            "color" => nullable(string()),
            "description" => string(),
            "value_type" => string(),
            "metadata" => free_object()
          },
          ["id", "name", "key", "color", "description", "value_type", "metadata"]
        ),
      "Attachment" =>
        object(
          %{
            "id" => string(),
            "path" => string(),
            "mime" => string(),
            "description" => string(),
            "content_url" => string()
          },
          ["id", "path", "mime", "description", "content_url"]
        ),
      "Note" =>
        object(
          %{
            "id" => string("uuid"),
            "title" => string(),
            "content" => string(),
            "labels" => array(ref("Label")),
            "attachments" => array(ref("Attachment")),
            "created_at" => nullable(string("date-time")),
            "updated_at" => nullable(string("date-time"))
          },
          [
            "id",
            "title",
            "content",
            "labels",
            "attachments",
            "created_at",
            "updated_at"
          ]
        ),
      "NoteEnvelope" =>
        object(
          %{"data" => ref("Note")},
          ["data"]
        ),
      "NoteList" =>
        object(
          %{"data" => array(ref("Note"))},
          ["data"]
        ),
      "LabelSettingList" =>
        object(
          %{"data" => array(ref("LabelSetting"))},
          ["data"]
        ),
      "AttachmentInput" =>
        object(
          %{
            "id" => string(),
            "path" => string(),
            "mime" => string(),
            "description" => string(),
            "content" => string(),
            "content_base64" => string("byte")
          },
          ["id", "path", "mime"],
          additional_properties: false
        ),
      "NoteCreateInput" =>
        object(
          %{
            "title" => string(),
            "content" => string(),
            "labels" => label_inputs(),
            "attachments" => array(ref("AttachmentInput"))
          },
          ["title", "content"],
          additional_properties: false
        ),
      "NoteUpdateInput" =>
        object(
          %{
            "title" => string(),
            "content" => string(),
            "labels" => label_inputs(),
            "attachments" => array(ref("AttachmentInput"))
          },
          ["attachments"],
          additional_properties: false
        ),
      "GeoData" =>
        object(%{
          "city" => nullable(string()),
          "country" => nullable(string()),
          "country_code" => nullable(string()),
          "continent" => nullable(string()),
          "continent_code" => nullable(string()),
          "latitude" => nullable(%{"type" => "number", "format" => "double"}),
          "longitude" => nullable(%{"type" => "number", "format" => "double"}),
          "timezone" => nullable(string()),
          "postal_code" => nullable(string()),
          "subdivision" => nullable(string())
        }),
      "GeoEnvelope" =>
        object(
          %{"data" => ref("GeoData")},
          ["data"]
        ),
      "WhoisEnvelope" =>
        object(
          %{
            "data" =>
              array(
                array(string())
                |> Map.merge(%{"minItems" => 2, "maxItems" => 2})
              )
          },
          ["data"]
        ),
      "RdapEnvelope" =>
        object(
          %{"data" => free_object()},
          ["data"]
        ),
      "MacVendorEnvelope" =>
        object(
          %{
            "data" =>
              object(
                %{"short" => string(), "full" => string()},
                ["short", "full"]
              )
          },
          ["data"]
        ),
      "SimpleError" =>
        object(
          %{"error" => string()},
          ["error"]
        ),
      "VapidKeyEnvelope" =>
        object(
          %{"public_key" => nullable(string())},
          ["public_key"]
        ),
      "WebPushSubscriptionInput" =>
        object(
          %{
            "subscription" =>
              object(
                %{
                  "endpoint" => string(),
                  "keys" => free_object(),
                  "expiration_time" => nullable(%{"type" => "integer"})
                },
                ["endpoint", "keys"]
              )
          },
          ["subscription"]
        ),
      "NotificationInput" =>
        object(
          %{"title" => string(), "body" => string()},
          ["title", "body"]
        ),
      "StatusEnvelope" =>
        object(
          %{"status" => string()},
          ["status"]
        ),
      "SubscriptionError" =>
        object(
          %{"errors" => string()},
          ["errors"]
        )
    }
  end

  defp ref(name), do: %{"$ref" => "#/components/schemas/#{name}"}

  defp object(properties, required \\ [], opts \\ []) do
    %{
      "type" => "object",
      "properties" => properties
    }
    |> maybe_put("required", required, required != [])
    |> maybe_put(
      "additionalProperties",
      Keyword.get(opts, :additional_properties),
      Keyword.has_key?(opts, :additional_properties)
    )
  end

  defp free_object, do: %{"type" => "object", "additionalProperties" => true}
  defp array(items), do: %{"type" => "array", "items" => items}
  defp string, do: %{"type" => "string"}
  defp string(format), do: %{"type" => "string", "format" => format}
  defp nullable(schema), do: Map.put(schema, "nullable", true)

  defp label_inputs do
    array(%{"oneOf" => [string(), free_object()]})
  end

  defp maybe_put(map, key, value, true), do: Map.put(map, key, value)
  defp maybe_put(map, _key, _value, false), do: map
end
