import assert from "node:assert/strict";
import { describe, test } from "node:test";

import { formatJson } from "./json_viewer.js";

describe("JSON viewer custom element", () => {
  test("pretty-prints compact JSON with two-space indentation", () => {
    assert.strictEqual(formatJson('{"nested":{"enabled":true},"count":2}'), '{\n  "nested": {\n    "enabled": true\n  },\n  "count": 2\n}');
  });

  test("preserves invalid JSON text", () => {
    assert.strictEqual(formatJson("not-json"), "not-json");
  });
});
