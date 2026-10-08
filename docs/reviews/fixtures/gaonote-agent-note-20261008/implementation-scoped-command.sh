#!/bin/sh
# Execute from the gaonote-api-parity worktree against the isolated test DB.
DATABASE_URL=postgres://gao@localhost:5433/gsmlg_test_api_parity \
PGHOST=/home/gao/Workspace/gsmlg-dev/gsmlg_umbrella/.devenv/run/postgres \
PGPORT=5433 mix test \
  apps/gsmlg_gao_note/test/ \
  apps/gsmlg_web/test/gsmlg_web/controllers/agent_note_controller_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/agent_note_content_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/agent_note_services_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/agent_note_image_info_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/agent_note_json_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/agent_note_openapi_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_invalid_labels_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/agent_note_mcp_controller_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/agent_note_mcp_auth_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_controller_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_label_controller_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_attachment_content_controller_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/gao_note_mcp_controller_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/gao_note_attachment_content_controller_test.exs \
  apps/gsmlg_config/test/gsmlg/config/gao_note_services_test.exs
