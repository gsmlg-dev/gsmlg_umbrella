# GSMLG Umbrella — Documentation

## Deployment

- [Deployment Guide](deploy.md)

## Categories

### [Commander](commander/)
Docs for the `gsmlg_commander` application — dual-mode command system with agent/server modes, PTY sessions, and WebSocket control.

- [System Architecture](commander/system_architecture.md)
- [Management Module](commander/management_module.md)
- [E2E Testing Design](commander/e2e_testing.md)
- [PTY Implementation](commander/pty_implementation.md)

### [Blog](blog/)
Docs for the blog subsystem within `gsmlg_web`.

- [Multi-Language Support](blog/multi_language.md)

### [Storage](storage/)
Docs for the `gsmlg_storage` application — S3-backed centralized file management.

- [Product Requirements Document](storage/prd.md)

### GaoNote
Current GaoNote public contracts and integration boundaries.

- [Note-Owned Attachment Contract](gao_note_attachments.md)
- [External Chunking and Embedding Contract](../note_chunking.md)

### [Migrations](migrations/)
Migration guides for infrastructure and database changes.

- [Config System Migration](migrations/config_migration.md)
- [MySQL → PostgreSQL Migration](migrations/mysql_to_postgresql.md)

### [Reference](reference/)
Reference documents and external technology overviews.

- [Phoenix 1.8 Overview](reference/phoenix_1.8.md)
