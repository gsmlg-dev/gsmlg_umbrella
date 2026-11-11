import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, test } from "node:test";

import AccessibleDialog, {
  closeDialogAndFocus,
} from "./accessible_dialog.js";

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

    assert.strictEqual(host.hasAttribute("role"), false);
    assert.strictEqual(host.hasAttribute("aria-modal"), false);
    assert.strictEqual(host.hasAttribute("aria-labelledby"), false);
    assert.strictEqual(host.hasAttribute("aria-label"), false);
    assert.strictEqual(shadowDialog.getAttribute("role"), "dialog");
    assert.strictEqual(shadowDialog.getAttribute("aria-modal"), "true");
    assert.strictEqual(shadowDialog.getAttribute("aria-label"), "Edit selected labels");
    assert.strictEqual(mutationObservers[0].target, host);
    assert.deepStrictEqual(mutationObservers[0].options, {
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

    assert.strictEqual(cancelTarget.focusCount, 1);
    assert.strictEqual(documentFake.activeElement.getAttribute("data-dialog-initial-focus"), "");
    assert.strictEqual(documentFake.listenerCount("keydown"), 1);
    assert.strictEqual(trigger.focusCount, 0);

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

    assert.strictEqual(event.defaultPrevented, true);
    assert.strictEqual(cancelTarget.focusCount, 2);

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

    assert.strictEqual(event.defaultPrevented, true);
    assert.strictEqual(lastTarget.focusCount, 1);

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

    assert.strictEqual(documentFake.listenerCount("keydown"), 0);
    assert.strictEqual(trigger.focusCount, 1);
    assert.strictEqual(documentFake.activeElement, trigger);
    assert.strictEqual(hostObserver.disconnected, true);
    assert.strictEqual(shadowObserver.disconnected, true);
    assert.notStrictEqual(observerFor(host), hostObserver);

    shadowObserver.trigger({ type: "childList" });
    assert.strictEqual(animationFrames.size, 0);
    assert.strictEqual(trigger.focusCount, 1);

    hook.destroyed();
  });

  test("updated refreshes the shadow accessible name without changing open state", () => {
    const { host, hook, shadowDialog, title } = mountedDialog();

    host.setAttribute("open", "");
    mutationObservers[0].trigger();
    title.textContent = "Delete three notes";
    hook.updated();

    assert.strictEqual(shadowDialog.getAttribute("aria-label"), "Delete three notes");
    assert.strictEqual(host.hasAttribute("open"), true);

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
    assert.notStrictEqual(shadowObserver, undefined);
    shadowObserver?.trigger({ type: "childList" });
    flushAnimationFrames();

    assert.strictEqual(replacementDialog.getAttribute("role"), "dialog");
    assert.strictEqual(replacementDialog.getAttribute("aria-modal"), "true");
    assert.strictEqual(replacementDialog.getAttribute("aria-label"), "Edit selected labels");
    assert.strictEqual(oldCancelTarget.focusCount, 0);
    assert.strictEqual(replacementCancel.focusCount, 1);

    documentFake.activeElement = lastHost;
    const tab = keyEvent({ key: "Tab" });
    documentFake.dispatch("keydown", tab);
    assert.strictEqual(tab.defaultPrevented, true);
    assert.strictEqual(replacementClose.focusCount, 1);

    documentFake.activeElement = host;
    hostShadow.activeElement = replacementClose;
    const shiftTab = keyEvent({ key: "Tab", shiftKey: true });
    documentFake.dispatch("keydown", shiftTab);
    assert.strictEqual(shiftTab.defaultPrevented, true);
    assert.strictEqual(replacementLast.focusCount, 1);

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
    assert.strictEqual(oldCancelTarget.focusCount, 1);

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
    assert.notStrictEqual(shadowObserver, undefined);
    shadowObserver?.trigger({ type: "childList" });
    flushAnimationFrames();

    assert.strictEqual(replacementDialog.getAttribute("aria-label"), "Edit selected labels");
    assert.strictEqual(oldCancelTarget.focusCount, 1);
    assert.strictEqual(replacementCancel.focusCount, 0);

    hook.destroyed();
  });

  test("updated recovers focus when a LiveView patch replaces the focused Cancel action", () => {
    const {
      cancelHost: oldCancelHost,
      cancelTarget: oldCancelTarget,
      host,
      hook,
      replaceLightDom,
    } = mountedDialog();

    host.setAttribute("open", "");
    observerFor(host).trigger();
    flushAnimationFrames();
    assert.strictEqual(oldCancelTarget.focusCount, 1);

    const replacementCancelHost = element(documentFake, {
      attributes: { "data-dialog-initial-focus": "" },
    });
    const replacementCancelTarget = element(documentFake, {
      documentActiveHost: replacementCancelHost,
    });
    replacementCancelHost.shadowRoot = shadowRoot({
      focusTarget: replacementCancelTarget,
    });
    replaceLightDom({
      cancelHost: replacementCancelHost,
      focusables: [replacementCancelHost, element(documentFake)],
    });
    oldCancelHost.isConnected = false;
    oldCancelTarget.isConnected = false;
    documentFake.activeElement = documentFake.body;

    hook.updated();

    assert.strictEqual(replacementCancelTarget.focusCount, 0);
    flushAnimationFrames();
    assert.strictEqual(replacementCancelTarget.focusCount, 1);
    assert.strictEqual(documentFake.activeElement, replacementCancelHost);
    assert.strictEqual(host.contains(documentFake.activeElement), true);

    hook.destroyed();
  });

  test("updated preserves focus when the active shadow host remains inside the current dialog", () => {
    const {
      cancelTarget: oldCancelTarget,
      host,
      hook,
      replaceLightDom,
    } = mountedDialog();

    host.setAttribute("open", "");
    observerFor(host).trigger();
    flushAnimationFrames();

    const replacementCancelHost = element(documentFake, {
      attributes: { "data-dialog-initial-focus": "" },
    });
    const replacementCancelTarget = element(documentFake, {
      documentActiveHost: replacementCancelHost,
    });
    replacementCancelHost.shadowRoot = shadowRoot({
      focusTarget: replacementCancelTarget,
    });
    const currentHost = element(documentFake);
    const currentTarget = element(documentFake, {
      documentActiveHost: currentHost,
    });
    currentHost.shadowRoot = shadowRoot({ focusTarget: currentTarget });
    currentHost.shadowRoot.activeElement = currentTarget;
    replaceLightDom({
      cancelHost: replacementCancelHost,
      focusables: [replacementCancelHost, currentHost],
    });
    documentFake.activeElement = currentHost;

    hook.updated();
    flushAnimationFrames();

    assert.strictEqual(oldCancelTarget.focusCount, 1);
    assert.strictEqual(replacementCancelTarget.focusCount, 0);
    assert.strictEqual(documentFake.activeElement, currentHost);

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

    assert.strictEqual(mutationObservers.every(({ disconnected }) => disconnected), true);
    assert.strictEqual(documentFake.listenerCount("keydown"), 0);
    assert.strictEqual(documentFake.body.style.overflow, "");
    assert.strictEqual(trigger.focusCount, 1);
    assert.strictEqual(cancelTarget.focusCount, 0);
    assert.strictEqual(host.closeCalls, 0);
  });
});

describe("close dialog event helper", () => {
  test("closes the requested dialog without changing legacy focus behavior", () => {
    const dialog = {
      closeCalls: 0,
      close() {
        this.closeCalls += 1;
      },
    };
    documentFake.getElementById = (id) =>
      id === "dialog-id" ? dialog : null;

    closeDialogAndFocus({ id: "dialog-id" });

    assert.strictEqual(dialog.closeCalls, 1);
    assert.strictEqual(animationFrames.size, 0);
  });

  test("focuses the requested fallback after the LiveView patch removes the trigger", () => {
    const dialog = {
      closeCalls: 0,
      close() {
        this.closeCalls += 1;
      },
    };
    const fallback = element(documentFake);
    const removedTrigger = element(documentFake);
    removedTrigger.isConnected = false;
    documentFake.activeElement = removedTrigger;
    documentFake.getElementById = (id) =>
      id === "dialog-id" ? dialog : null;
    documentFake.querySelector = (selector) =>
      selector === "#gao-note-search-input" ? fallback : null;

    closeDialogAndFocus({
      id: "dialog-id",
      focus: "#gao-note-search-input",
    });

    assert.strictEqual(dialog.closeCalls, 1);
    assert.strictEqual(fallback.focusCount, 0);

    flushAnimationFrames();

    assert.strictEqual(fallback.focusCount, 1);
    assert.strictEqual(documentFake.activeElement, fallback);
  });

  test("focuses the deep button target for a DuskMoon fallback host", () => {
    const dialog = {
      close() {},
    };
    const fallbackHost = element(documentFake);
    const fallbackButton = element(documentFake, {
      documentActiveHost: fallbackHost,
    });
    fallbackHost.shadowRoot = shadowRoot({ focusTarget: fallbackButton });
    fallbackHost.focus = () => {
      fallbackHost.focusCount += 1;
    };
    documentFake.getElementById = () => dialog;
    documentFake.querySelector = () => fallbackHost;

    closeDialogAndFocus({ id: "dialog-id", focus: "#gao-note-recycle-refresh" });
    flushAnimationFrames();

    assert.strictEqual(fallbackButton.focusCount, 1);
    assert.strictEqual(fallbackHost.focusCount, 0);
    assert.strictEqual(documentFake.activeElement, fallbackHost);
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

  const lightDom = {
    cancelHost,
    focusables: [cancelHost, middle, lastHost],
    title,
  };
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
    if (selector === '[slot="header"]') return lightDom.title;
    if (selector === "[data-dialog-initial-focus]") return lightDom.cancelHost;
    return null;
  };
  host.querySelectorAll = () => lightDom.focusables;
  host.contains = (candidate) =>
    lightDom.focusables.includes(candidate) ||
    lightDom.focusables.some(
      (focusable) => focusable.shadowRoot?.activeElement === candidate,
    );

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
    replaceLightDom(replacement) {
      Object.assign(lightDom, replacement);
    },
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
