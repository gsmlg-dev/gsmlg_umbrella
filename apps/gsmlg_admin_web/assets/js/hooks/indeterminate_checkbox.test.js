import { describe, expect, test } from "bun:test";

import IndeterminateCheckbox from "./indeterminate_checkbox.js";

describe("indeterminate checkbox hook", () => {
  test("sets the indeterminate property when mounted", () => {
    const hook = {
      ...IndeterminateCheckbox,
      el: { dataset: { state: "mixed" }, indeterminate: false },
    };

    hook.mounted();

    expect(hook.el.indeterminate).toBe(true);
  });

  test("clears the indeterminate property when updated", () => {
    const hook = {
      ...IndeterminateCheckbox,
      el: { dataset: { state: "mixed" }, indeterminate: true },
    };

    hook.mounted();
    hook.el.dataset.state = "all";
    hook.updated();

    expect(hook.el.indeterminate).toBe(false);
  });
});
