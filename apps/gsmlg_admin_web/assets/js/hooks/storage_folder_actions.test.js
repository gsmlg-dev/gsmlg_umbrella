import { describe, expect, test } from "bun:test";

import StorageFolderActions from "./storage_folder_actions.js";

describe("storage folder dialog focus return", () => {
  test("returns focus to the leaf menu button after a native dialog closes", () => {
    const { root, trigger, dialog } = setup();
    root.dispatchClose(dialog);
    expect(trigger.focusCount).toBe(1);
  });

  test("uses the bucket root when the leaf trigger has been removed", () => {
    const { root, rootLink, dialog, elements } = setup();
    elements.delete("folder-actions-popover-trigger");
    root.dispatchClose(dialog);
    expect(rootLink.focusCount).toBe(1);
  });

  test("ignores other dialogs and events from non-dialog elements", () => {
    const { root, rootLink, trigger } = setup();
    root.dispatchClose({ matches: () => false });
    root.dispatchClose({
      matches: () => false,
      dataset: { folderActionTrigger: "folder-actions-popover-trigger" },
    });
    expect(rootLink.focusCount).toBe(0);
    expect(trigger.focusCount).toBe(0);
  });

  test("does not focus a matching trigger outside this tree", () => {
    const { root, trigger, rootLink, dialog } = setup();
    trigger.inTree = false;
    root.dispatchClose(dialog);
    expect(trigger.focusCount).toBe(0);
    expect(rootLink.focusCount).toBe(1);
  });

  test("delegates to newly inserted dialogs and removes its capture listener on destroy", () => {
    const { root, hook, trigger } = setup();
    root.dispatchClose({
      matches: () => true,
      dataset: { folderActionTrigger: "folder-actions-popover-trigger" },
    });
    expect(trigger.focusCount).toBe(1);
    hook.destroyed();
    root.dispatchClose({
      matches: () => true,
      dataset: { folderActionTrigger: "folder-actions-popover-trigger" },
    });
    expect(trigger.focusCount).toBe(1);
    expect(root.listeners.size).toBe(0);
  });
});

function setup() {
  const trigger = focusable();
  const rootLink = focusable();
  const elements = new Map([["folder-actions-popover-trigger", trigger]]);
  const root = {
    listeners: new Set(),
    ownerDocument: { getElementById: (id) => elements.get(id) },
    contains: (element) => element.inTree,
    querySelector: (selector) => selector === "#storage-root-folder" ? rootLink : null,
    addEventListener(type, listener, capture) {
      expect(type).toBe("close");
      expect(capture).toBe(true);
      this.listeners.add(listener);
    },
    removeEventListener(type, listener, capture) {
      expect(type).toBe("close");
      expect(capture).toBe(true);
      this.listeners.delete(listener);
    },
    dispatchClose(target) {
      for (const listener of this.listeners) listener({ target });
    },
  };
  const dialog = {
    matches: () => true,
    dataset: { folderActionTrigger: "folder-actions-popover-trigger" },
  };
  const hook = { ...StorageFolderActions, el: root };
  hook.mounted();
  return { root, trigger, rootLink, dialog, elements, hook };
}

function focusable() {
  return { inTree: true, focusCount: 0, focus() { this.focusCount += 1; } };
}
