import assert from "node:assert/strict";
import { describe, test } from "node:test";

import IndeterminateCheckbox from "./indeterminate_checkbox.js";

describe("indeterminate checkbox hook", () => {
  test("sets the indeterminate property when mounted", () => {
    const hook = {
      ...IndeterminateCheckbox,
      el: { dataset: { state: "mixed" }, indeterminate: false },
    };

    hook.mounted();

    assert.strictEqual(hook.el.indeterminate, true);
  });

  test("clears the indeterminate property when updated", () => {
    const hook = {
      ...IndeterminateCheckbox,
      el: { dataset: { state: "mixed" }, indeterminate: true },
    };

    hook.mounted();
    hook.el.dataset.state = "all";
    hook.updated();

    assert.strictEqual(hook.el.indeterminate, false);
  });
});
