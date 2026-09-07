defmodule GSMLG.AdminWeb.BrowserApiSpec do
  @moduledoc false

  @behaviour OpenApiSpex.OpenApi

  alias OpenApiSpex.OpenApi

  @observation_required ~w(revision url origin title loading_state page_kind visible_controls semantic_tree alerts)
  @artifact_media_types ~w(application/octet-stream application/pdf application/json text/html text/markdown text/plain image/png image/jpeg)
  @canonical_origin_pattern [
                              "^https://",
                              "(?!localhost(?::|$))",
                              "(?![^/:]*\\.(?:localhost|local|internal)(?::|$))",
                              "(?!10\\.)",
                              "(?!127\\.)",
                              "(?!169\\.254\\.)",
                              "(?!172\\.(?:1[6-9]|2[0-9]|3[01])\\.)",
                              "(?!192\\.(?:(?:0\\.(?:0|2))|168)\\.)",
                              "(?!0\\.)",
                              "(?!100\\.(?:6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.)",
                              "(?!198\\.(?:(?:18|19)\\.|51\\.100\\.))",
                              "(?!203\\.0\\.113\\.)",
                              "(?!2(?:2[4-9]|3[0-9]|4[0-9]|5[0-5])\\.)",
                              "(?!\\[(?:::1\\]|f[cd][0-9a-f]{2}:|fe[89a-f][0-9a-f]:|ff[0-9a-f]{2}:|2001:(?:db8|2):|0?100::))",
                              "(?:[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?|\\[[0-9a-f:]+\\])",
                              "(?::(?!443$)(?:[1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5]))?$"
                            ]
                            |> Enum.join()

  @impl OpenApiSpex.OpenApi
  def spec do
    OpenApi.from_map(%{
      "openapi" => "3.0.3",
      "info" => %{
        "title" => "GSMLG Admin Browser API",
        "version" => to_string(Application.spec(:gsmlg_admin_web, :vsn) || "0.1.0")
      },
      "servers" => [%{"url" => "/"}],
      "paths" => paths(),
      "components" => %{
        "securitySchemes" => %{
          "browserBearerAuth" => %{
            "type" => "http",
            "scheme" => "bearer",
            "bearerFormat" => "JWT",
            "description" => "Admin Guardian access token"
          }
        },
        "schemas" => schemas()
      }
    })
  end

  defp paths do
    %{
      "/api/browser/nodes" => %{
        "get" => operation("listBrowserNodes", 200, "NodeList")
      },
      "/api/browser/nodes/{node_id}" => %{
        "get" => operation("getBrowserNode", 200, "Node", params: [path_id("node_id")])
      },
      "/api/browser/nodes/{node_id}/profiles" => %{
        "get" =>
          operation("listBrowserProfiles", 200, "ProfileList", params: [path_id("node_id")])
      },
      "/api/browser/nodes/{node_id}/profiles/sync" => %{
        "post" =>
          operation("syncBrowserProfiles", 200, "ProfileList", params: [path_id("node_id")])
      },
      "/api/browser/profiles/{id}" => %{
        "patch" =>
          operation("configureBrowserProfile", 200, "Profile",
            params: [path_id("id")],
            body: "ProfileConfigurationInput"
          )
      },
      "/api/browser/profiles/{id}/launch" => %{
        "post" => operation("launchBrowserProfile", 200, "Profile", params: [path_id("id")])
      },
      "/api/browser/profiles/{id}/stop" => %{
        "post" => operation("stopBrowserProfile", 200, "Profile", params: [path_id("id")])
      },
      "/api/browser/sessions" => %{
        "post" => operation("createBrowserSession", 201, "Session", body: "SessionCreateInput")
      },
      "/api/browser/sessions/{id}" => %{
        "get" => operation("getBrowserSession", 200, "Session", params: [path_id("id")]),
        "delete" => operation("closeBrowserSession", 204, nil, params: [path_id("id")])
      },
      "/api/browser/sessions/{id}/observe" => %{
        "post" => operation("observeBrowserSession", 200, "Observation", params: [path_id("id")])
      },
      "/api/browser/sessions/{id}/actions" => %{
        "post" =>
          operation("executeBrowserAction", 200, "ActionResult",
            params: [path_id("id")],
            body: "ActionInput"
          )
      },
      "/api/browser/sessions/{id}/manual-acquire" => %{
        "post" => operation("acquireBrowserManualLease", 200, "Session", params: [path_id("id")])
      },
      "/api/browser/sessions/{id}/manual-release" => %{
        "post" => operation("releaseBrowserManualLease", 200, "Session", params: [path_id("id")])
      },
      "/api/browser/jobs" => %{
        "post" => operation("createBrowserJob", 202, "Job", body: "JobCreateInput"),
        "get" => operation("listBrowserJobs", 200, "JobList", params: pagination("uuid"))
      },
      "/api/browser/jobs/{id}" => %{
        "get" => operation("getBrowserJob", 200, "Job", params: [path_id("id")])
      },
      "/api/browser/jobs/{id}/events" => %{
        "get" =>
          operation("listBrowserJobEvents", 200, "JobEventList",
            params: [path_id("id") | pagination("integer")]
          )
      },
      "/api/browser/jobs/{id}/cancel" => %{
        "post" => operation("cancelBrowserJob", 202, "Job", params: [path_id("id")])
      },
      "/api/browser/jobs/{id}/retry" => %{
        "post" =>
          operation("retryBrowserJob", 202, "Job",
            params: [path_id("id")],
            body: "JobRetryInput"
          )
      },
      "/api/browser/jobs/{id}/resume" => %{
        "post" => operation("resumeBrowserJob", 202, "Job", params: [path_id("id")])
      },
      "/api/browser/jobs/{id}/reconcile" => %{
        "post" => operation("reconcileBrowserJob", 202, "Job", params: [path_id("id")])
      },
      "/api/browser/jobs/{id}/artifacts" => %{
        "get" =>
          operation("listBrowserJobArtifacts", 200, "ArtifactList",
            params: [path_id("id") | pagination("uuid")]
          )
      },
      "/api/browser/artifacts/{id}" => %{
        "get" => operation("getBrowserArtifact", 200, "Artifact", params: [path_id("id")])
      },
      "/api/browser/artifacts/{id}/content" => %{
        "get" => content_operation()
      }
    }
  end

  defp operation(operation_id, success_status, schema, opts \\ []) do
    %{
      "operationId" => operation_id,
      "security" => [%{"browserBearerAuth" => []}],
      "parameters" => Keyword.get(opts, :params, []),
      "responses" => responses(success_status, schema)
    }
    |> maybe_body(Keyword.get(opts, :body))
  end

  defp content_operation do
    operation("downloadBrowserArtifact", 200, nil,
      params: [
        path_id("id"),
        %{
          "name" => "Range",
          "in" => "header",
          "required" => false,
          "schema" => %{"type" => "string", "maxLength" => 100}
        }
      ]
    )
    |> Map.put("responses", %{
      "200" => binary_response("Verified artifact", :full),
      "206" => binary_response("Verified artifact byte range", :partial),
      "401" => error_response("Authentication required"),
      "404" => error_response("Artifact not found"),
      "416" => range_error_response(),
      "503" => error_response("Artifact temporarily unavailable")
    })
  end

  defp responses(status, schema) do
    %{
      Integer.to_string(status) => success_response(schema),
      "401" => error_response("Authentication required"),
      "404" => error_response("Resource not found"),
      "409" => error_response("State conflict"),
      "422" => error_response("Invalid request"),
      "503" => error_response("Dependency unavailable"),
      "504" => error_response("Remote deadline exceeded")
    }
  end

  defp success_response(nil), do: %{"description" => "No content"}

  defp success_response(schema) do
    %{
      "description" => "Successful Browser operation",
      "content" => %{"application/json" => %{"schema" => ref(schema)}}
    }
  end

  defp error_response(description) do
    %{
      "description" => description,
      "content" => %{"application/json" => %{"schema" => ref("BrowserError")}}
    }
  end

  defp binary_response(description, range) do
    %{
      "description" => description,
      "headers" => artifact_response_headers(range),
      "content" =>
        Map.new(@artifact_media_types, fn media_type ->
          {media_type,
           %{
             "schema" => %{"type" => "string", "format" => "binary"}
           }}
        end)
    }
  end

  defp range_error_response do
    "Invalid byte range"
    |> error_response()
    |> Map.put("headers", artifact_response_headers(:unsatisfied))
  end

  defp artifact_response_headers(range) do
    headers = %{
      "Accept-Ranges" => %{
        "required" => true,
        "schema" => %{"type" => "string", "enum" => ["bytes"]}
      },
      "Content-Disposition" => %{
        "required" => true,
        "schema" => %{"type" => "string", "minLength" => 1}
      }
    }

    case range do
      :partial ->
        Map.put(headers, "Content-Range", %{
          "required" => true,
          "schema" => %{"type" => "string", "pattern" => "^bytes [0-9]+-[0-9]+/[0-9]+$"}
        })

      :unsatisfied ->
        Map.put(headers, "Content-Range", %{
          "required" => true,
          "schema" => %{"type" => "string", "pattern" => "^bytes \\*/[0-9]+$"}
        })

      :full ->
        headers
    end
  end

  defp maybe_body(operation, nil), do: operation

  defp maybe_body(operation, schema) do
    Map.put(operation, "requestBody", %{
      "required" => true,
      "content" => %{"application/json" => %{"schema" => ref(schema)}}
    })
  end

  defp path_id(name) do
    %{
      "name" => name,
      "in" => "path",
      "required" => true,
      "schema" => %{"type" => "string", "format" => "uuid"}
    }
  end

  defp pagination(type) do
    [
      %{
        "name" => "limit",
        "in" => "query",
        "required" => false,
        "schema" => %{"type" => "integer", "minimum" => 1, "maximum" => 100, "default" => 50}
      },
      %{
        "name" => "after",
        "in" => "query",
        "required" => false,
        "schema" => cursor_schema(type)
      }
    ]
  end

  defp cursor_schema("uuid"), do: %{"type" => "string", "format" => "uuid"}
  defp cursor_schema("integer"), do: %{"type" => "integer", "minimum" => 1}

  defp origin_list_schema(min_items \\ 1) do
    %{
      "type" => "array",
      "minItems" => min_items,
      "maxItems" => 16,
      "uniqueItems" => true,
      "items" => %{
        "type" => "string",
        "format" => "uri",
        "maxLength" => 2_048,
        "pattern" => @canonical_origin_pattern,
        "description" =>
          "Canonical public HTTPS origin only: no credentials, path, query, fragment, localhost, or private literal address."
      }
    }
  end

  defp schemas do
    %{
      "BrowserError" =>
        object(~w(class code message retryable human_action details), %{
          "class" => string(),
          "code" => string(),
          "message" => string(),
          "retryable" => %{"type" => "boolean"},
          "human_action" => Map.put(string(), "nullable", true),
          "details" => object([], %{})
        }),
      "Capability" =>
        object(~w(id version backend operations limits workflows), %{
          "id" => string(),
          "version" => %{"type" => "integer", "minimum" => 1},
          "backend" => string(),
          "operations" => array(string()),
          "limits" => %{"type" => "object", "additionalProperties" => %{"type" => "integer"}},
          "workflows" => array(string())
        }),
      "Node" =>
        object(
          ~w(id commander_id enabled default_backend status capabilities limits last_seen_at online manager_status agent_version browser_version error_code),
          %{
            "id" => uuid(),
            "commander_id" => string(),
            "enabled" => %{"type" => "boolean"},
            "default_backend" => string(),
            "status" => enum(~w(online degraded offline disabled)),
            "capabilities" => array(ref("Capability")),
            "limits" => %{"type" => "object", "additionalProperties" => %{"type" => "integer"}},
            "last_seen_at" => nullable_datetime(),
            "online" => %{"type" => "boolean"},
            "manager_status" => Map.put(enum(~w(available degraded)), "nullable", true),
            "agent_version" => nullable_string(),
            "browser_version" => nullable_string(),
            "error_code" => nullable_string()
          }
        ),
      "Profile" =>
        object(
          ~w(id node_id external_id name backend enabled is_default runtime_status automation_status locale timezone screen allowed_origins last_seen_at error_code),
          %{
            "id" => uuid(),
            "node_id" => uuid(),
            "external_id" => string(),
            "name" => string(),
            "backend" => string(),
            "enabled" => %{"type" => "boolean"},
            "is_default" => %{"type" => "boolean"},
            "runtime_status" => enum(~w(unknown running stopped unavailable)),
            "automation_status" => enum(~w(available leased manual disabled)),
            "locale" => nullable_string(),
            "timezone" => nullable_string(),
            "screen" => ref("Screen"),
            "allowed_origins" => origin_list_schema(0),
            "last_seen_at" => nullable_datetime(),
            "error_code" => nullable_string()
          }
        ),
      "Session" =>
        object(
          ~w(id node_id profile_id mode status revision last_seen_at expires_at inserted_at updated_at error_code),
          %{
            "id" => uuid(),
            "node_id" => uuid(),
            "profile_id" => uuid(),
            "mode" => enum(~w(automation manual)),
            "status" =>
              enum(~w(opening ready acting waiting waiting_human closing closed orphaned failed)),
            "revision" => %{"type" => "integer", "minimum" => 0},
            "last_seen_at" => nullable_datetime(),
            "expires_at" => nullable_datetime(),
            "inserted_at" => nullable_datetime(),
            "updated_at" => nullable_datetime(),
            "error_code" => nullable_string()
          }
        ),
      "SemanticNode" => semantic_node(),
      "Screen" =>
        object([], %{
          "width" => %{"type" => "integer", "minimum" => 1},
          "height" => %{"type" => "integer", "minimum" => 1},
          "device_scale_factor" => %{"type" => "number", "exclusiveMinimum" => 0},
          "color_depth" => %{"type" => "integer", "minimum" => 1}
        }),
      "Observation" =>
        object(@observation_required, %{
          "revision" => %{"type" => "integer", "minimum" => 0},
          "url" => string(2_048),
          "origin" => string(2_048),
          "title" => string(1_024),
          "loading_state" => enum(~w(loading interactive complete)),
          "page_kind" => string(),
          "visible_controls" => array(ref("SemanticNode")),
          "semantic_tree" => array(ref("SemanticNode")),
          "alerts" => array(string(512)),
          "focused_element" => ref("SemanticNode"),
          "observed_at" => nullable_datetime()
        }),
      "ActionOutput" =>
        object([], %{
          "status" => string(),
          "value" => string(65_536),
          "values" => array(string(65_536)),
          "text" => string(65_536),
          "artifact_id" => uuid(),
          "kind" => string(),
          "mime" => string(),
          "filename" => string(),
          "size" => %{"type" => "integer", "minimum" => 0},
          "sha256" => %{"type" => "string", "pattern" => "^[0-9a-f]{64}$"},
          "selected" => %{"type" => "boolean"},
          "artifact" => ref("ActionArtifactReference")
        }),
      "ActionArtifactReference" =>
        object(~w(artifact_id kind mime filename size sha256 status), %{
          "artifact_id" => uuid(),
          "kind" => enum(~w(screenshot.png download)),
          "mime" => string(255),
          "filename" => string(255),
          "size" => %{"type" => "integer", "minimum" => 0},
          "sha256" => %{"type" => "string", "pattern" => "^[0-9a-f]{64}$"},
          "status" => enum(~w(pending uploading verified rejected))
        }),
      "ActionResult" =>
        object(~w(action_id revision observation output), %{
          "action_id" => string(200),
          "revision" => %{"type" => "integer", "minimum" => 0},
          "observation" => ref("Observation"),
          "output" => ref("ActionOutput")
        }),
      "ResultManifest" => result_manifest_schema(),
      "Job" => job_schema(),
      "JobEventMetadata" => event_metadata_schema(),
      "JobEvent" =>
        object(~w(id job_id sequence event phase occurred_at inserted_at metadata), %{
          "id" => uuid(),
          "job_id" => uuid(),
          "sequence" => %{"type" => "integer", "minimum" => 1},
          "event" => string(),
          "phase" => nullable_string(),
          "occurred_at" => nullable_datetime(),
          "inserted_at" => nullable_datetime(),
          "metadata" => ref("JobEventMetadata")
        }),
      "ArtifactMetadata" => artifact_metadata_schema(),
      "Artifact" => artifact_schema(),
      "Page" =>
        object(~w(limit next_after), %{
          "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100},
          "next_after" => %{
            "anyOf" => [nullable_string(), %{"type" => "integer", "nullable" => true}]
          }
        }),
      "NodeList" => data_list("Node", false),
      "ProfileList" => data_list("Profile", false),
      "JobList" => data_list("Job", true),
      "JobEventList" => data_list("JobEvent", true),
      "ArtifactList" => data_list("Artifact", true),
      "ProfileConfigurationInput" => %{"oneOf" => profile_configuration_schemas()},
      "SessionCreateInput" =>
        object(~w(node profile mode authorized_origins ttl), %{
          "node" => uuid(),
          "profile" => uuid(),
          "mode" => enum(~w(automation manual)),
          "authorized_origins" => origin_list_schema(),
          "ttl" => %{"type" => "integer", "minimum" => 1, "maximum" => 86_400_000},
          "permissions" => ref("SessionPermissions")
        }),
      "SessionPermissions" =>
        object([], %{
          "screenshot" => %{"type" => "boolean"},
          "download" => %{"type" => "boolean"}
        }),
      "DeepResearchInput" =>
        object(~w(prompt output_locale research_scope required_sections auto_approve_plan), %{
          "prompt" => string(65_536),
          "output_locale" => locale_schema(),
          "research_scope" => string(1_024),
          "required_sections" => %{
            "type" => "array",
            "minItems" => 1,
            "maxItems" => 32,
            "uniqueItems" => true,
            "items" => string(128)
          },
          "auto_approve_plan" => %{"type" => "boolean"}
        }),
      "YouTubeAnalysisInput" =>
        object(
          ~w(youtube_url analysis_profile output_locale custom_instructions use_deep_research),
          %{
            "youtube_url" => youtube_url_schema(),
            "analysis_profile" =>
              enum(~w(summary technical_review timeline fact_check action_items)),
            "output_locale" => locale_schema(),
            "custom_instructions" => string(8_192, 0),
            "use_deep_research" => %{"type" => "boolean"}
          }
        ),
      "JobCreateInput" => %{"oneOf" => job_create_input_schemas()},
      "JobRetryInput" => object(["idempotency_key"], %{"idempotency_key" => string(512)}),
      "Locator" => locator_schema(),
      "Postcondition" => postcondition_schema(),
      "ActionInput" => %{"oneOf" => action_input_schemas()}
    }
  end

  defp semantic_node do
    object([], %{
      "node_id" => string(),
      "backend_node_id" => string(),
      "role" => string(),
      "name" => string(1_024),
      "value" => string(1_024),
      "label" => string(1_024),
      "placeholder" => string(1_024),
      "depth" => %{"type" => "integer", "minimum" => 0},
      "state" =>
        object([], %{
          "checked" => %{"oneOf" => [%{"type" => "boolean"}, string(64)]},
          "disabled" => %{"type" => "boolean"},
          "expanded" => %{"type" => "boolean"},
          "focused" => %{"type" => "boolean"},
          "pressed" => %{"oneOf" => [%{"type" => "boolean"}, string(64)]},
          "readonly" => %{"type" => "boolean"},
          "required" => %{"type" => "boolean"},
          "selected" => %{"type" => "boolean"}
        }),
      "bounds" =>
        object([], %{
          "x" => %{"type" => "number"},
          "y" => %{"type" => "number"},
          "width" => %{"type" => "number", "minimum" => 0},
          "height" => %{"type" => "number", "minimum" => 0}
        }),
      "attributes" =>
        object([], %{
          "data-testid" => string(512),
          "data-test" => string(512),
          "id" => string(512),
          "name" => string(512),
          "aria-label" => string(512),
          "type" => string(128),
          "autocomplete" => string(128),
          "href" => string(2_048)
        })
    })
  end

  defp job_schema do
    fields =
      ~w(id node_id profile_id session_id workflow workflow_version status phase output_formats attempt previous_job_id last_remote_sequence deadline_at started_at completed_at inserted_at updated_at result result_available error_code)

    object(fields, %{
      "id" => uuid(),
      "node_id" => uuid(),
      "profile_id" => uuid(),
      "session_id" => Map.put(uuid(), "nullable", true),
      "workflow" => string(),
      "workflow_version" => %{"type" => "integer", "minimum" => 1},
      "status" => string(),
      "phase" => nullable_string(),
      "output_formats" => array(string()),
      "attempt" => %{"type" => "integer", "minimum" => 1},
      "previous_job_id" => Map.put(uuid(), "nullable", true),
      "last_remote_sequence" => %{"type" => "integer", "minimum" => 0},
      "deadline_at" => nullable_datetime(),
      "started_at" => nullable_datetime(),
      "completed_at" => nullable_datetime(),
      "inserted_at" => nullable_datetime(),
      "updated_at" => nullable_datetime(),
      "result" => nullable_object_ref("ResultManifest"),
      "result_available" => %{"type" => "boolean"},
      "error_code" => nullable_string()
    })
  end

  defp result_manifest_schema do
    counter = %{"type" => "integer", "minimum" => 0, "maximum" => 1_000_000_000}

    object(~w(last_sequence artifact_count pending_artifact_count remote_completed), %{
      "last_sequence" => counter,
      "artifact_count" => counter,
      "pending_artifact_count" => counter,
      "remote_completed" => %{"type" => "boolean"}
    })
  end

  defp event_metadata_schema do
    object([], %{
      "artifact_id" => uuid(),
      "kind" => string(),
      "transfer_mode" => string(),
      "failure_code" => string(),
      "intervention_reason" => string(),
      "attempt" => %{"type" => "integer", "minimum" => 1},
      "status" => string(),
      "sequence" => %{"type" => "integer", "minimum" => 1},
      "reason" => string(),
      "code" => string()
    })
  end

  defp artifact_metadata_schema do
    object([], %{
      "width" => %{"type" => "integer", "minimum" => 0},
      "height" => %{"type" => "integer", "minimum" => 0},
      "source_index" => %{"type" => "integer", "minimum" => 0},
      "sequence" => %{"type" => "integer", "minimum" => 0},
      "page_number" => %{"type" => "integer", "minimum" => 0}
    })
  end

  defp artifact_schema do
    fields =
      ~w(id kind mime filename size sha256 transfer_mode status verified_at rejected_at inserted_at metadata)

    object(fields, %{
      "id" => uuid(),
      "job_id" => uuid(),
      "session_id" => uuid(),
      "kind" => string(),
      "mime" => string(255),
      "filename" => string(255),
      "size" => %{"type" => "integer", "minimum" => 0},
      "sha256" => %{"type" => "string", "pattern" => "^[0-9a-f]{64}$"},
      "transfer_mode" => enum(~w(inline signed_upload remote_pending)),
      "status" => enum(~w(pending uploading verified rejected)),
      "verified_at" => nullable_datetime(),
      "rejected_at" => nullable_datetime(),
      "inserted_at" => nullable_datetime(),
      "metadata" => ref("ArtifactMetadata")
    })
    |> Map.put("oneOf", [%{"required" => ["job_id"]}, %{"required" => ["session_id"]}])
  end

  defp data_list(schema, paginated?) do
    properties = %{"data" => array(ref(schema))}
    properties = if paginated?, do: Map.put(properties, "page", ref("Page")), else: properties
    required = if paginated?, do: ~w(data page), else: ["data"]
    object(required, properties)
  end

  defp locator_schema do
    %{
      "oneOf" => [
        object(["node_id"], %{"node_id" => string(256)}),
        object(["role"], %{"role" => string(128), "accessible_name" => string(512)}),
        object(["label"], %{"label" => string(512)}),
        object(["placeholder"], %{"placeholder" => string(512)}),
        object(["text"], %{"text" => string(512)}),
        object(["css"], %{"css" => string(1_024)}),
        object(["attribute"], %{
          "attribute" =>
            object(~w(name value), %{
              "name" => enum(~w(aria-controls type)),
              "value" => string(512)
            })
        })
      ]
    }
  end

  defp job_create_input_schemas do
    [
      job_create_input_schema("gemini.deep_research", "DeepResearchInput"),
      job_create_input_schema("gemini.youtube_analysis", "YouTubeAnalysisInput")
    ]
  end

  defp profile_configuration_schemas do
    required = ~w(enabled is_default allowed_origins)

    [
      object(required, %{
        "enabled" => %{"type" => "boolean"},
        "is_default" => %{"type" => "boolean", "enum" => [false]},
        "allowed_origins" => origin_list_schema()
      }),
      object(required, %{
        "enabled" => %{"type" => "boolean", "enum" => [true]},
        "is_default" => %{"type" => "boolean", "enum" => [true]},
        "allowed_origins" => origin_list_schema()
      })
    ]
  end

  defp job_create_input_schema(workflow, input_schema) do
    object(~w(workflow workflow_version input idempotency_key output_formats), %{
      "workflow" => enum([workflow]),
      "workflow_version" => %{"type" => "integer", "enum" => [1]},
      "node" => Map.put(uuid(), "nullable", true),
      "profile" => Map.put(uuid(), "nullable", true),
      "input" => ref(input_schema),
      "idempotency_key" => string(512),
      "output_formats" => output_formats_schema()
    })
  end

  defp output_formats_schema do
    %{
      "type" => "array",
      "minItems" => 3,
      "maxItems" => 5,
      "uniqueItems" => true,
      "items" => enum(~w(report.markdown report.html report.json sources.json screenshot.png)),
      "enum" => allowed_output_format_sequences()
    }
  end

  defp allowed_output_format_sequences do
    required = ~w(report.markdown report.json sources.json)

    [
      required,
      required ++ ["report.html"],
      required ++ ["screenshot.png"],
      required ++ ["report.html", "screenshot.png"]
    ]
    |> Enum.flat_map(&permutations/1)
  end

  defp permutations([]), do: [[]]

  defp permutations(values) do
    for value <- values,
        remainder <- permutations(List.delete(values, value)),
        do: [value | remainder]
  end

  defp youtube_url_schema do
    %{
      "type" => "string",
      "format" => "uri",
      "maxLength" => 2_048,
      "pattern" =>
        "^https://(?:(?:www\\.)?youtube\\.com(?::443)?/watch\\?(?:[^#&]+&)*v=[A-Za-z0-9_-]{6,64}(?:&[^#&]+)*|youtu\\.be(?::443)?/[A-Za-z0-9_-]{6,64}(?:\\?[^#]*)?)$"
    }
  end

  defp locale_schema do
    %{
      "type" => "string",
      "minLength" => 1,
      "maxLength" => 32,
      "pattern" => "^[a-zA-Z]{2,3}(?:-[a-zA-Z0-9]{2,8})*$"
    }
  end

  defp action_input_schemas do
    empty = object([], %{})

    [
      action_input_schema(
        "navigate",
        object(["url"], %{
          "url" => %{
            "type" => "string",
            "format" => "uri",
            "maxLength" => 2_048,
            "pattern" => "^https://[^/@\\s]+(?:[/?#].*)?$"
          }
        })
      ),
      action_input_schema("click", empty, locator: true),
      action_input_schema("focus", empty, locator: true),
      action_input_schema("fill", object(["text"], %{"text" => string(65_536, 0)}), locator: true),
      action_input_schema(
        "insert_text",
        object(["text"], %{"text" => string(65_536, 0)}),
        locator: true
      ),
      action_input_schema("press_key", object(["key"], %{"key" => string(64)})),
      action_input_schema(
        "select_option",
        object(["value"], %{"value" => string(1_024)}),
        locator: true
      ),
      action_input_schema(
        "scroll",
        object(~w(delta_x delta_y), %{
          "delta_x" => %{"type" => "integer", "minimum" => -100_000, "maximum" => 100_000},
          "delta_y" => %{"type" => "integer", "minimum" => -100_000, "maximum" => 100_000}
        })
      ),
      action_input_schema("wait_for", empty, locator: true),
      action_input_schema("extract", empty, locator: true),
      action_input_schema("screenshot", empty),
      action_input_schema("download", empty, locator: true)
    ]
  end

  defp action_input_schema(type, input, opts \\ []) do
    locator? = Keyword.get(opts, :locator, false)

    required =
      ~w(action_id expected_revision type input timeout_ms) ++
        if(locator?, do: ["locator"], else: [])

    properties = %{
      "action_id" => string(200),
      "expected_revision" => %{"type" => "integer", "minimum" => 0},
      "type" => enum([type]),
      "input" => input,
      "postcondition" => nullable_object_ref("Postcondition"),
      "timeout_ms" => %{"type" => "integer", "minimum" => 1, "maximum" => 120_000}
    }

    properties =
      if locator?,
        do: Map.put(properties, "locator", ref("Locator")),
        else: Map.put(properties, "locator", %{"nullable" => true, "enum" => [nil]})

    object(required, properties)
  end

  defp postcondition_schema do
    %{
      "oneOf" => [
        object(~w(type value), %{
          "type" => enum(~w(url_is origin_is title_contains)),
          "value" => string(2_048)
        }),
        object(~w(type locator), %{
          "type" => enum(~w(node_present node_absent)),
          "locator" => ref("Locator")
        })
      ]
    }
  end

  defp nullable_object_ref(name) do
    %{
      "oneOf" => [
        ref(name),
        %{"type" => "object", "nullable" => true, "enum" => [nil]}
      ]
    }
  end

  defp object(required, properties) do
    %{
      "type" => "object",
      "required" => required,
      "properties" => properties,
      "additionalProperties" => false
    }
  end

  defp string(max \\ 4_096, min \\ 1),
    do: %{"type" => "string", "minLength" => min, "maxLength" => max}

  defp nullable_string, do: %{"type" => "string", "nullable" => true}
  defp nullable_datetime, do: %{"type" => "string", "format" => "date-time", "nullable" => true}
  defp uuid, do: %{"type" => "string", "format" => "uuid"}
  defp enum(values), do: %{"type" => "string", "enum" => values}
  defp array(items), do: %{"type" => "array", "items" => items}
  defp ref(name), do: %{"$ref" => "#/components/schemas/#{name}"}
end
