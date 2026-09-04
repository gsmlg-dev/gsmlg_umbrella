# Storage Metadata JSON Display Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render non-empty storage metadata without a server error while preserving browser-side pretty JSON display.

**Architecture:** Phoenix encodes metadata with Elixir's built-in `JSON.encode!/1` and emits compact JSON as escaped text. A local custom element formats that text with browser-native JSON APIs inside the existing DuskMoon code-block element.

**Tech Stack:** Elixir 1.18 built-in JSON, Phoenix LiveView/HEEX, browser Custom Elements, DuskMoon Elements, Bun test

---

### Task 1: Capture the rendering and formatter regressions

**Files:**
- Create: `apps/gsmlg_admin_web/test/gsmlg/admin_web/live/storage_live/show_test.exs`
- Create: `apps/gsmlg_admin_web/assets/js/custom_elements/json_viewer.test.js`

- [ ] **Step 1: Write a LiveView test for non-empty metadata**

Create an authenticated admin connection, insert a `GSMLG.Storage.StorageFile`
whose metadata contains nested values, open `/storage/:id`, and assert the page
contains the two JSON display elements:

```elixir
defmodule GSMLG.AdminWeb.StorageLive.ShowTest do
  use GSMLG.AdminWeb.ConnCase, async: false

  import GSMLG.AccountsFixtures
  import Phoenix.LiveViewTest

  alias GSMLG.Repo
  alias GSMLG.Storage.StorageFile

  @secret_key_base String.duplicate("s", 64)

  setup %{conn: conn} do
    endpoint_config = Application.get_env(:gsmlg_admin_web, GSMLG.AdminWeb.Endpoint, [])

    Application.put_env(
      :gsmlg_admin_web,
      GSMLG.AdminWeb.Endpoint,
      Keyword.put(endpoint_config, :secret_key_base, @secret_key_base)
    )

    on_exit(fn ->
      Application.put_env(:gsmlg_admin_web, GSMLG.AdminWeb.Endpoint, endpoint_config)
    end)

    user = user_fixture()

    {:ok, token, _claims} =
      GSMLG.AdminWeb.Guardian.encode_and_sign(user, %{}, token_type: "access")

    conn =
      conn
      |> with_secret_key_base()
      |> Plug.Test.init_test_session(%{})
      |> Guardian.Plug.sign_in(GSMLG.AdminWeb.Guardian, user, %{}, token_type: "access")
      |> Plug.Conn.put_session(:guardian_default_token, token)

    %{conn: conn}
  end

  test "renders non-empty metadata with the JSON custom element", %{conn: conn} do
    file =
      Repo.insert!(%StorageFile{
        tenant: "test",
        type: "document",
        filename: "metadata.json",
        s3_key: "test/document/metadata.json",
        content_type: "application/json",
        size: 2,
        metadata: %{"count" => 2, "nested" => %{"enabled" => true}}
      })

    {:ok, view, _html} = live(conn, ~p"/storage/#{file.id}")

    assert has_element?(view, "el-dm-code-block[language='json'][copyable]")
    assert has_element?(view, "el-gsmlg-json", JSON.encode!(file.metadata))
  end
end
```

- [ ] **Step 2: Run the LiveView test and verify the production exception**

Run:

```bash
mix test apps/gsmlg_admin_web/test/gsmlg/admin_web/live/storage_live/show_test.exs
```

Expected: FAIL with `BadFunctionError` from `JSON.encode!/2` receiving
`[pretty: true]`.

- [ ] **Step 3: Write formatter unit tests**

Test two-space indentation and invalid-input preservation:

```javascript
import { describe, expect, test } from "bun:test";

import { formatJson } from "./json_viewer.js";

describe("JSON viewer custom element", () => {
  test("pretty-prints compact JSON with two-space indentation", () => {
    expect(formatJson('{"nested":{"enabled":true},"count":2}')).toBe(
      '{\n  "nested": {\n    "enabled": true\n  },\n  "count": 2\n}',
    );
  });

  test("preserves invalid JSON text", () => {
    expect(formatJson("not-json")).toBe("not-json");
  });
});
```

- [ ] **Step 4: Run the formatter test and verify the missing module failure**

Run:

```bash
bun test apps/gsmlg_admin_web/assets/js/custom_elements/json_viewer.test.js
```

Expected: FAIL because `json_viewer.js` does not exist yet.

### Task 2: Implement browser-side pretty JSON rendering

**Files:**
- Create: `apps/gsmlg_admin_web/assets/js/custom_elements/json_viewer.js`
- Modify: `apps/gsmlg_admin_web/assets/js/hooks.js`
- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/storage_live/show.html.heex`

- [ ] **Step 1: Implement the formatter and custom element**

Export `formatJson`, parsing with `JSON.parse` and formatting with
`JSON.stringify(value, null, 2)`. Define `ElGsmlgJson` with lifecycle-managed
mutation observation and register `el-gsmlg-json` when `customElements` exists.

```javascript
export function formatJson(source) {
  try {
    return JSON.stringify(JSON.parse(source), null, 2);
  } catch {
    return source;
  }
}

const HTMLElementBase = globalThis.HTMLElement ?? class {};

export class ElGsmlgJson extends HTMLElementBase {
  connectedCallback() {
    this.format();
    this.observer = new MutationObserver(() => this.format());
    this.observer.observe(this, { childList: true, characterData: true, subtree: true });
  }

  disconnectedCallback() {
    this.observer?.disconnect();
  }

  format() {
    const formatted = formatJson(this.textContent ?? "");
    if (formatted !== this.textContent) this.textContent = formatted;
  }
}

if (globalThis.customElements && !customElements.get("el-gsmlg-json")) {
  customElements.define("el-gsmlg-json", ElGsmlgJson);
}
```

- [ ] **Step 2: Register the module in the admin asset entrypoint**

Add a side-effect import for `./custom_elements/json_viewer` to `hooks.js`.

```javascript
import "./custom_elements/json_viewer";
```

- [ ] **Step 3: Replace the invalid server-side pretty encoder call**

Use only `JSON.encode!(@file.metadata)` in HEEX and nest its output as
`<pre><code><el-gsmlg-json>...</el-gsmlg-json></code></pre>` within a copyable,
borderless `<el-dm-code-block language="json">`.

```heex
<.dm_card variant="bordered" body_class="p-0">
  <el-dm-code-block language="json" copyable borderless>
    <pre><code><el-gsmlg-json>{JSON.encode!(@file.metadata)}</el-gsmlg-json></code></pre>
  </el-dm-code-block>
</.dm_card>
```

- [ ] **Step 4: Run focused tests and verify they pass**

Run:

```bash
mix test apps/gsmlg_admin_web/test/gsmlg/admin_web/live/storage_live/show_test.exs
bun test apps/gsmlg_admin_web/assets/js/custom_elements/json_viewer.test.js
```

Expected: both commands PASS.

### Task 3: Validate formatting and asset integration

**Files:**
- Modify if required by formatter only: files listed in Tasks 1 and 2

- [ ] **Step 1: Format touched Elixir and HEEX files**

Run:

```bash
mix format apps/gsmlg_admin_web/test/gsmlg/admin_web/live/storage_live/show_test.exs apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/storage_live/show.html.heex
```

Expected: command exits successfully.

- [ ] **Step 2: Re-run focused tests**

Run:

```bash
mix test apps/gsmlg_admin_web/test/gsmlg/admin_web/live/storage_live/show_test.exs
bun test apps/gsmlg_admin_web/assets/js/custom_elements/json_viewer.test.js
```

Expected: all focused tests PASS.

- [ ] **Step 3: Build the admin assets**

Run:

```bash
mix bun gsmlg_admin_web --minify
```

Expected: command exits successfully and resolves the new custom-element import.

- [ ] **Step 4: Review the final diff**

Run:

```bash
git diff --check
git status --short
git diff --stat
git diff
```

Expected: no whitespace errors and only the approved storage JSON display files
plus these design/plan documents are changed.
