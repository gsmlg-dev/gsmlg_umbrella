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

    trigger(record = { attributeName: "open" }) {
      this.callback([typeof record === "string" ? { attributeName: record } : record]);
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
    const hostObserver = observerFor(host);
    const shadowObserver = observerFor(host.shadowRoot);

    host.setAttribute("open", "");
    hostObserver.trigger();
    flushAnimationFrames();
    host.removeAttribute("open");
    hostObserver.trigger();

    expect(documentFake.listenerCount("keydown")).toBe(0);
    expect(trigger.focusCount).toBe(1);
    expect(documentFake.activeElement).toBe(trigger);
    expect(hostObserver.disconnected).toBe(true);
    expect(shadowObserver.disconnected).toBe(true);
    expect(observerFor(host)).not.toBe(hostObserver);

    shadowObserver.trigger({ type: "childList" });
    expect(animationFrames.size).toBe(0);
    expect(trigger.focusCount).toBe(1);

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

  test("open synchronization uses replacement shadow semantics and focus targets", () => {
    const {
      cancelHost,
      cancelTarget: oldCancelTarget,
      host,
      hostShadow,
      hook,
      lastHost,
    } = mountedDialog();
    const replacementDialog = element(documentFake);
    const replacementClose = element(documentFake, { documentActiveHost: host });
    const replacementCancel = element(documentFake, {
      documentActiveHost: cancelHost,
    });
    const replacementLast = element(documentFake, {
      documentActiveHost: lastHost,
    });

    host.setAttribute("open", "");
    observerFor(host).trigger();
    replaceShadow({
      cancelHost,
      cancelTarget: replacementCancel,
      closeTarget: replacementClose,
      dialog: replacementDialog,
      host,
      hostShadow,
      lastHost,
      lastTarget: replacementLast,
    });

    const shadowObserver = observerFor(hostShadow);
    expect(shadowObserver).toBeDefined();
    shadowObserver?.trigger({ type: "childList" });
    flushAnimationFrames();

    expect(replacementDialog.getAttribute("role")).toBe("dialog");
    expect(replacementDialog.getAttribute("aria-modal")).toBe("true");
    expect(replacementDialog.getAttribute("aria-label")).toBe(
      "Edit selected labels",
    );
    expect(oldCancelTarget.focusCount).toBe(0);
    expect(replacementCancel.focusCount).toBe(1);

    documentFake.activeElement = lastHost;
    const tab = keyEvent({ key: "Tab" });
    documentFake.dispatch("keydown", tab);
    expect(tab.defaultPrevented).toBe(true);
    expect(replacementClose.focusCount).toBe(1);

    documentFake.activeElement = host;
    hostShadow.activeElement = replacementClose;
    const shiftTab = keyEvent({ key: "Tab", shiftKey: true });
    documentFake.dispatch("keydown", shiftTab);
    expect(shiftTab.defaultPrevented).toBe(true);
    expect(replacementLast.focusCount).toBe(1);

    hook.destroyed();
  });

  test("an open shadow replacement refreshes semantics without refocusing Cancel", () => {
    const {
      cancelHost,
      cancelTarget: oldCancelTarget,
      host,
      hostShadow,
      hook,
      lastHost,
    } = mountedDialog();

    host.setAttribute("open", "");
    observerFor(host).trigger();
    flushAnimationFrames();
    expect(oldCancelTarget.focusCount).toBe(1);

    const replacementDialog = element(documentFake);
    const replacementCancel = element(documentFake, {
      documentActiveHost: cancelHost,
    });
    const replacementLast = element(documentFake, {
      documentActiveHost: lastHost,
    });
    replaceShadow({
      cancelHost,
      cancelTarget: replacementCancel,
      closeTarget: element(documentFake, { documentActiveHost: host }),
      dialog: replacementDialog,
      host,
      hostShadow,
      lastHost,
      lastTarget: replacementLast,
    });

    const shadowObserver = observerFor(hostShadow);
    expect(shadowObserver).toBeDefined();
    shadowObserver?.trigger({ type: "childList" });
    flushAnimationFrames();

    expect(replacementDialog.getAttribute("aria-label")).toBe(
      "Edit selected labels",
    );
    expect(oldCancelTarget.focusCount).toBe(1);
    expect(replacementCancel.focusCount).toBe(0);

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

    expect(mutationObservers.every(({ disconnected }) => disconnected)).toBe(true);
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
  const hostShadow = shadowRoot({ dialog: shadowDialog });
  host.shadowRoot = hostShadow;
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
    hostShadow,
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
      document.activeElement = this.documentActiveHost || this;
      if (this.ownerShadowRoot) this.ownerShadowRoot.activeElement = this;
      if (this.documentActiveHost?.shadowRoot) {
        this.documentActiveHost.shadowRoot.activeElement = this;
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
    documentActiveHost: options.documentActiveHost || null,
  };
}

function shadowRoot(options = {}) {
  const state = { ...options };

  return {
    activeElement: null,
    querySelector(selector) {
      if (selector === '[part="dialog"]') return state.dialog || null;
      return state.focusTarget || null;
    },
    querySelectorAll() {
      return state.focusables || [];
    },
    replace(replacement) {
      Object.assign(state, replacement);
    },
  };
}

function observerFor(target) {
  return (
    [...mutationObservers]
      .reverse()
      .find((observer) => observer.target === target && !observer.disconnected) ||
    [...mutationObservers].reverse().find((observer) => observer.target === target)
  );
}

function replaceShadow({
  cancelHost,
  cancelTarget,
  closeTarget,
  dialog,
  host,
  hostShadow,
  lastHost,
  lastTarget,
}) {
  closeTarget.documentActiveHost = host;
  closeTarget.ownerShadowRoot = hostShadow;
  hostShadow.replace({ dialog, focusables: [closeTarget] });

  cancelTarget.documentActiveHost = cancelHost;
  cancelTarget.ownerShadowRoot = cancelHost.shadowRoot;
  cancelHost.shadowRoot.replace({ focusTarget: cancelTarget });

  lastTarget.documentActiveHost = lastHost;
  lastTarget.ownerShadowRoot = lastHost.shadowRoot;
  lastHost.shadowRoot.replace({ focusTarget: lastTarget });
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
