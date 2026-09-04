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
