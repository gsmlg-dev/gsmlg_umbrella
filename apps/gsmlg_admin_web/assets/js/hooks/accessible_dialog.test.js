import { afterEach, beforeEach, describe, expect, test } from "bun:test";

import AccessibleDialog from "./accessible_dialog.js";

let animationFrames;
let documentFake;
let mutationObservers;
let originalCancelAnimationFrame;
let originalDocument;
let originalMutationObserver;
let originalRequestAnimationFrame;

beforeEach(() => {
  animationFrames = new Map();
  mutationObservers = [];
  documentFake = createDocument();

  originalDocument = globalThis.document;
  originalMutationObserver = globalThis.MutationObserver;
  originalRequestAnimationFrame = globalThis.requestAnimationFrame;
  originalCancelAnimationFrame = globalThis.cancelAnimationFrame;

  globalThis.document = documentFake;
  globalThis.MutationObserver = class FakeMutationObserver {
    constructor(callback) {
      this.callback = callback;
      this.disconnected = false;
      mutationObservers.push(this);
    }

    observe(target, options) {
      this.target = target;
      this.options = options;
    }

    disconnect() {
      this.disconnected = true;
    }

    trigger(attributeName = "open") {
      this.callback([{ attributeName }]);
    }
  };

  let nextFrameId = 0;
  globalThis.requestAnimationFrame = (callback) => {
    nextFrameId += 1;
    animationFrames.set(nextFrameId, callback);
    return nextFrameId;
  };
  globalThis.cancelAnimationFrame = (id) => animationFrames.delete(id);
});

afterEach(() => {
  globalThis.document = originalDocument;
  globalThis.MutationObserver = originalMutationObserver;
  globalThis.requestAnimationFrame = originalRequestAnimationFrame;
  globalThis.cancelAnimationFrame = originalCancelAnimationFrame;
});

describe("accessible dialog hook", () => {
  test("moves the single dialog role and accessible name into the shadow dialog", () => {
    const { hook, host, shadowDialog } = mountedDialog();

    expect(host.hasAttribute("role")).toBe(false);
    expect(host.hasAttribute("aria-modal")).toBe(false);
    expect(host.hasAttribute("aria-labelledby")).toBe(false);
    expect(host.hasAttribute("aria-label")).toBe(false);
    expect(shadowDialog.getAttribute("role")).toBe("dialog");
    expect(shadowDialog.getAttribute("aria-modal")).toBe("true");
    expect(shadowDialog.getAttribute("aria-label")).toBe("Edit selected labels");
    expect(mutationObservers[0].target).toBe(host);
    expect(mutationObservers[0].options).toEqual({
      attributes: true,
      attributeFilter: ["open"],
    });

    hook.destroyed();
  });

  test("remembers the invoking element and focuses the explicit shadow-backed Cancel action", () => {
    const { cancelTarget, host, hook, trigger } = mountedDialog();

    host.setAttribute("open", "");
    mutationObservers[0].trigger();
    flushAnimationFrames();

    expect(cancelTarget.focusCount).toBe(1);
    expect(documentFake.activeElement.getAttribute("data-dialog-initial-focus")).toBe("");
    expect(documentFake.listenerCount("keydown")).toBe(1);
    expect(trigger.focusCount).toBe(0);

    hook.destroyed();
  });

  test("wraps Tab from the last custom-element focus target to the first", () => {
    const { cancelTarget, host, hook, lastHost } = mountedDialog();

    host.setAttribute("open", "");
    mutationObservers[0].trigger();
    flushAnimationFrames();
    documentFake.activeElement = lastHost;

    const event = keyEvent({ key: "Tab" });
    documentFake.dispatch("keydown", event);

    expect(event.defaultPrevented).toBe(true);
    expect(cancelTarget.focusCount).toBe(2);

    hook.destroyed();
  });

  test("wraps Shift+Tab from the first custom-element host to the last shadow target", () => {
    const { cancelHost, host, hook, lastTarget } = mountedDialog();

    host.setAttribute("open", "");
    mutationObservers[0].trigger();
    flushAnimationFrames();
    documentFake.activeElement = cancelHost;

    const event = keyEvent({ key: "Tab", shiftKey: true });
    documentFake.dispatch("keydown", event);

    expect(event.defaultPrevented).toBe(true);
    expect(lastTarget.focusCount).toBe(1);

    hook.destroyed();
  });

  test("returns focus and removes containment when the upstream dialog closes", () => {
    const { host, hook, trigger } = mountedDialog();

    host.setAttribute("open", "");
    mutationObservers[0].trigger();
    flushAnimationFrames();
    host.removeAttribute("open");
    mutationObservers[0].trigger();

    expect(documentFake.listenerCount("keydown")).toBe(0);
    expect(trigger.focusCount).toBe(1);
    expect(documentFake.activeElement).toBe(trigger);

    hook.destroyed();
  });

  test("updated refreshes the shadow accessible name without changing open state", () => {
    const { host, hook, shadowDialog, title } = mountedDialog();

    host.setAttribute("open", "");
    mutationObservers[0].trigger();
    title.textContent = "Delete three notes";
    hook.updated();

    expect(shadowDialog.getAttribute("aria-label")).toBe("Delete three notes");
    expect(host.hasAttribute("open")).toBe(true);

    hook.destroyed();
  });

  test("destroyed cancels pending focus, disconnects listeners, restores focus, and clears scroll lock", () => {
    const { cancelTarget, host, hook, trigger } = mountedDialog();
    host.close = () => {
      host.closeCalls += 1;
    };
    host.closeCalls = 0;

    host.setAttribute("open", "");
    documentFake.body.style.overflow = "hidden";
    mutationObservers[0].trigger();
    hook.destroyed();
    flushAnimationFrames();

    expect(mutationObservers[0].disconnected).toBe(true);
    expect(documentFake.listenerCount("keydown")).toBe(0);
    expect(documentFake.body.style.overflow).toBe("");
    expect(trigger.focusCount).toBe(1);
    expect(cancelTarget.focusCount).toBe(0);
    expect(host.closeCalls).toBe(0);
  });
});

function mountedDialog() {
  const trigger = element(documentFake);
  const title = element(documentFake, { textContent: " Edit selected labels " });
  const shadowDialog = element(documentFake, {
    attributes: { role: "dialog", "aria-modal": "true" },
  });
  const cancelHost = element(documentFake, {
    attributes: { "data-dialog-initial-focus": "" },
  });
  const cancelTarget = element(documentFake, { documentActiveHost: cancelHost });
  cancelHost.shadowRoot = shadowRoot({ focusTarget: cancelTarget });
  const middle = element(documentFake);
  const lastHost = element(documentFake);
  const lastTarget = element(documentFake, { documentActiveHost: lastHost });
  lastHost.shadowRoot = shadowRoot({ focusTarget: lastTarget });

  const focusables = [cancelHost, middle, lastHost];
  const host = element(documentFake, {
    attributes: {
      role: "dialog",
      "aria-modal": "true",
      "aria-labelledby": "dialog-title",
      "aria-label": "Fallback dialog name",
    },
  });
  host.shadowRoot = shadowRoot({ dialog: shadowDialog });
  host.querySelector = (selector) => {
    if (selector === '[slot="header"]') return title;
    if (selector === "[data-dialog-initial-focus]") return cancelHost;
    return null;
  };
  host.querySelectorAll = () => focusables;
  host.contains = (candidate) =>
    focusables.includes(candidate) ||
    focusables.some((focusable) => focusable.shadowRoot?.activeElement === candidate);

  documentFake.activeElement = trigger;
  const hook = { ...AccessibleDialog, el: host };
  hook.mounted();

  return {
    cancelHost,
    cancelTarget,
    host,
    hook,
    lastHost,
    lastTarget,
    middle,
    shadowDialog,
    title,
    trigger,
  };
}

function createDocument() {
  const listeners = new Map();

  return {
    activeElement: null,
    body: { style: { overflow: "" } },
    addEventListener(type, listener) {
      if (!listeners.has(type)) listeners.set(type, new Set());
      listeners.get(type).add(listener);
    },
    removeEventListener(type, listener) {
      listeners.get(type)?.delete(listener);
    },
    dispatch(type, event) {
      for (const listener of listeners.get(type) || []) listener(event);
    },
    listenerCount(type) {
      return listeners.get(type)?.size || 0;
    },
  };
}

function element(document, options = {}) {
  const attributes = new Map(Object.entries(options.attributes || {}));

  return {
    disabled: false,
    focusCount: 0,
    isConnected: true,
    textContent: options.textContent || "",
    focus() {
      this.focusCount += 1;
      document.activeElement = options.documentActiveHost || this;
      if (options.documentActiveHost?.shadowRoot) {
        options.documentActiveHost.shadowRoot.activeElement = this;
      }
    },
    getAttribute(name) {
      return attributes.has(name) ? attributes.get(name) : null;
    },
    hasAttribute(name) {
      return attributes.has(name);
    },
    removeAttribute(name) {
      attributes.delete(name);
    },
    setAttribute(name, value) {
      attributes.set(name, String(value));
    },
  };
}

function shadowRoot(options = {}) {
  return {
    activeElement: null,
    querySelector(selector) {
      if (selector === '[part="dialog"]') return options.dialog || null;
      return options.focusTarget || null;
    },
  };
}

function keyEvent({ key, shiftKey = false }) {
  return {
    defaultPrevented: false,
    key,
    shiftKey,
    preventDefault() {
      this.defaultPrevented = true;
    },
  };
}

function flushAnimationFrames() {
  const queued = [...animationFrames.values()];
  animationFrames.clear();
  for (const callback of queued) callback();
}
