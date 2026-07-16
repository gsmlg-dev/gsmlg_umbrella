# GaoNote external chunking and embedding API

GaoNote does not implement chunking, embedding, chunk persistence, or vector-search storage in this version.

The external service owns:

- chunking strategy
- tokenizer behavior
- embedding generation
- chunk persistence
- vector index persistence
- indexing status, retries, and errors
- vector-search APIs

GaoNote owns only note persistence and passes note data to the external service when indexing is needed.

## Endpoint

```http
POST /v1/gao-note/index
Content-Type: application/json
Authorization: Bearer <token>
Idempotency-Key: gao-note:<note_id>:<updated_at>
```

## Request

```json
{
  "request_id": "018f8c7a-7b1d-7c2d-9a4d-2f4a3d0b8c11",
  "note": {
    "id": "note_uuid",
    "title": "Note title",
    "content": "# Markdown note\n\ncontent...",
    "content_format": "markdown",
    "updated_at": "2026-07-10T12:00:00Z"
  },
  "embedding": {
    "model": "BAAI/bge-m3",
    "dimensions": 1024,
    "normalize": true
  },
  "chunking": {
    "profile": "bge-m3-markdown-v1",
    "max_tokens": 1024,
    "overlap_tokens": 128,
    "tokenizer": "xlm-roberta"
  }
}
```

## Response

The external service may process synchronously or asynchronously. GaoNote only needs an acknowledgement that the note content was accepted for indexing.

```json
{
  "request_id": "018f8c7a-7b1d-7c2d-9a4d-2f4a3d0b8c11",
  "note_id": "note_uuid",
  "updated_at": "2026-07-10T12:00:00Z",
  "status": "accepted",
  "index_id": "external_index_record_id"
}
```

## Contract rules

- `updated_at` should be echoed back.
- The external service should ignore stale requests if it already has a newer `updated_at` for the same `note.id`.
- The combination of `note.id`, `updated_at`, embedding model, and chunking profile should be idempotent.
- The external service owns all chunk and embedding records.
- GaoNote must not create a local `gao_note_chunks` table in this version.

## Error response

```json
{
  "error": {
    "code": "indexing_failed",
    "message": "BGE-M3 service unavailable",
    "retryable": true,
    "details": {}
  }
}
```

## Expected HTTP status codes

- `200`: accepted or completed
- `202`: accepted for asynchronous indexing
- `400`: invalid request
- `401`: authentication failed
- `422`: content cannot be indexed
- `429`: rate limited
- `500`: retryable server failure
- `503`: retryable service unavailable

## External service storage notes

The external service should store any chunk and vector-search data it needs, such as:

- `note_id`
- chunk `position`
- chunk `content`
- chunk `content_hash`
- `token_count`
- `start_byte`
- `end_byte`
- `tokenizer`
- `embedding_model`
- `embedding_dimensions`
- embedding vector or vector-store id
- indexing status, errors, retry count, and timestamps
