# Storage Metadata JSON Display Fix

## Context

The admin storage detail page currently calls `JSON.encode!/2` with
`pretty: true`. Elixir's built-in `JSON.encode!/2` expects an encoder function
as its second argument, so any storage record with non-empty metadata raises a
`BadFunctionError` during LiveView rendering.

## Goals

- Keep Elixir's built-in `JSON` module as the only server-side JSON encoder.
- Restore the storage detail page for files with non-empty metadata.
- Pretty-print metadata in the browser with a small custom element.
- Reuse the already registered DuskMoon code-block element for presentation and
  copying.

## Non-goals

- Reintroducing Jason.
- Adding a server-side pretty-printing implementation.
- Changing storage data or the storage API.
- Changing reverse-proxy or deployment configuration.

## Design

Phoenix serializes metadata exactly once with `JSON.encode!/1`. The HEEX
template places that compact, HTML-escaped JSON inside an
`<el-gsmlg-json>` element nested in an `<el-dm-code-block language="json">`.

The local custom element reads its text content and uses the browser's native
`JSON.parse` and `JSON.stringify(value, null, 2)` to produce two-space-indented
JSON. It writes the result back through `textContent`, never `innerHTML`. A
`MutationObserver` reapplies formatting if LiveView replaces the element's text.
Invalid input is left unchanged, although the server-generated payload should
always be valid JSON.

The DuskMoon code block remains responsible for the bordered code presentation,
language label, and copy action. It is already registered through
`@duskmoon-dev/elements/register`, so no dependency change is required.

## Verification

- A LiveView test inserts a storage file with nested, non-empty metadata and
  proves the detail route renders the JSON custom elements without raising.
- A Bun unit test proves compact JSON is indented and invalid text is preserved.
- The focused Elixir test, focused Bun test, HEEX/Elixir formatter, and admin
  asset build must pass.
