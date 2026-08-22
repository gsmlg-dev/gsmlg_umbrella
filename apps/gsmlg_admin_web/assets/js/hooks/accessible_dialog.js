// WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#143

const HOST_DIALOG_ATTRIBUTES = [
  "role",
  "aria-modal",
  "aria-labelledby",
  "aria-label",
];

const FOCUSABLE_SELECTOR = [
  "button:not([disabled])",
  "a[href]",
  'input:not([type="hidden"]):not([disabled])',
  "select:not([disabled])",
  "textarea:not([disabled])",
  '[tabindex]:not([tabindex="-1"])',
  "el-dm-button:not([disabled])",
].join(", ");

function focusTarget(element) {
  return element?.shadowRoot?.querySelector(FOCUSABLE_SELECTOR) || element;
}

export function closeDialogAndFocus(
  detail,
  documentRoot = document,
  schedule = requestAnimationFrame,
) {
  const dialogId = typeof detail?.id === "string" ? detail.id : "";
  if (dialogId) documentRoot.getElementById?.(dialogId)?.close?.();

  const focusSelector =
    typeof detail?.focus === "string" ? detail.focus.trim() : "";
  if (!focusSelector) return;

  schedule(() =>
    focusTarget(documentRoot.querySelector?.(focusSelector))?.focus?.(),
  );
}

const AccessibleDialog = {
  mounted() {
    this._accessibleDialogDestroyed = false;
    this._accessibleDialogOpen = false;
    this._accessibleDialogInvoker = null;
    this._accessibleDialogFocusFrame = null;
    this._accessibleDialogFocusOnSync = false;
    this._accessibleDialogKeyListenerInstalled = false;
    this._accessibleDialogFallbackLabel =
      this.el.getAttribute("aria-label")?.trim() || "";
    this._accessibleDialogKeydown = (event) => this._containDialogFocus(event);

    this._configureDialogSemantics();
    this._refreshDialogFocusables();

    this._observeDialogHost();
    this._observeDialogShadow();
    this._syncDialogOpenState();
  },

  updated() {
    if (this._accessibleDialogDestroyed) return;

    this._configureDialogSemantics();
    this._refreshDialogFocusables();
    this._observeDialogShadow();
    this._syncDialogOpenState();

    if (
      this._accessibleDialogOpen &&
      !this._dialogContains(document.activeElement)
    ) {
      this._scheduleDialogSynchronization(true);
    }
  },

  destroyed() {
    this._accessibleDialogDestroyed = true;
    this._disconnectDialogHostObserver();
    this._disconnectDialogShadowObserver();
    this._cancelDialogFocusFrame();
    this._removeDialogKeyListener();

    if (this._accessibleDialogOpen) {
      document.body.style.overflow = "";
      this._accessibleDialogOpen = false;
      this._restoreDialogFocus();
    }

    this._accessibleDialogFocusables = [];
    this._accessibleDialogInitialFocusable = null;
  },

  _configureDialogSemantics() {
    const reflectedLabel = this.el.getAttribute("aria-label")?.trim();
    if (reflectedLabel) this._accessibleDialogFallbackLabel = reflectedLabel;

    const title = this.el
      .querySelector('[slot="header"]')
      ?.textContent?.trim();
    const accessibleName = title || this._accessibleDialogFallbackLabel;

    for (const attribute of HOST_DIALOG_ATTRIBUTES) {
      this.el.removeAttribute(attribute);
    }

    const shadowDialog = this.el.shadowRoot?.querySelector('[part="dialog"]');
    if (!shadowDialog) return;

    shadowDialog.setAttribute("role", "dialog");
    shadowDialog.setAttribute("aria-modal", "true");
    shadowDialog.removeAttribute("aria-labelledby");

    if (accessibleName) {
      shadowDialog.setAttribute("aria-label", accessibleName);
    } else {
      shadowDialog.removeAttribute("aria-label");
    }
  },

  _syncDialogOpenState() {
    const open = this.el.hasAttribute("open");

    if (open && !this._accessibleDialogOpen) {
      this._openAccessibleDialog();
    } else if (!open && this._accessibleDialogOpen) {
      this._closeAccessibleDialog();
    }
  },

  _openAccessibleDialog() {
    const activeElement = document.activeElement;
    if (activeElement && !this._dialogContains(activeElement)) {
      this._accessibleDialogInvoker = activeElement;
    }

    this._accessibleDialogOpen = true;
    this._observeDialogShadow();
    this._installDialogKeyListener();
    this._scheduleDialogSynchronization(true);
  },

  _closeAccessibleDialog() {
    this._accessibleDialogOpen = false;
    this._cancelDialogFocusFrame();
    this._disconnectDialogHostObserver();
    this._disconnectDialogShadowObserver();
    this._removeDialogKeyListener();
    this._restoreDialogFocus();
    if (!this._accessibleDialogDestroyed) this._observeDialogHost();
  },

  _scheduleDialogSynchronization(focusInitial = false) {
    this._accessibleDialogFocusOnSync ||= focusInitial;
    if (this._accessibleDialogFocusFrame !== null) return;

    this._accessibleDialogFocusFrame = requestAnimationFrame(() => {
      this._accessibleDialogFocusFrame = null;
      if (this._accessibleDialogDestroyed) return;

      const shouldFocusInitial = this._accessibleDialogFocusOnSync;
      this._accessibleDialogFocusOnSync = false;
      this._configureDialogSemantics();
      this._refreshDialogFocusables();
      this._observeDialogShadow();

      if (shouldFocusInitial && this._accessibleDialogOpen) {
        this._focusDialogItem(
          this._accessibleDialogInitialFocusable ||
            this._accessibleDialogFocusables[0],
        );
      }
    });
  },

  _observeDialogShadow() {
    const shadowRoot = this.el.shadowRoot;
    if (!shadowRoot) return;
    if (
      this._accessibleDialogShadowObserver &&
      this._accessibleDialogObservedShadow === shadowRoot
    ) {
      return;
    }

    this._disconnectDialogShadowObserver();
    this._accessibleDialogObservedShadow = shadowRoot;
    const observer = new MutationObserver(() => {
      if (
        this._accessibleDialogDestroyed ||
        this._accessibleDialogShadowObserver !== observer
      ) {
        return;
      }

      this._scheduleDialogSynchronization(false);
    });
    this._accessibleDialogShadowObserver = observer;
    observer.observe(shadowRoot, {
      childList: true,
      subtree: true,
    });
  },

  _observeDialogHost() {
    if (this._accessibleDialogObserver) return;

    const observer = new MutationObserver((mutations) => {
      if (
        this._accessibleDialogDestroyed ||
        this._accessibleDialogObserver !== observer
      ) {
        return;
      }

      if (mutations.some(({ attributeName }) => attributeName === "open")) {
        this._syncDialogOpenState();
      }
    });
    this._accessibleDialogObserver = observer;
    observer.observe(this.el, {
      attributes: true,
      attributeFilter: ["open"],
    });
  },

  _disconnectDialogHostObserver() {
    this._accessibleDialogObserver?.disconnect();
    this._accessibleDialogObserver = null;
  },

  _disconnectDialogShadowObserver() {
    this._accessibleDialogShadowObserver?.disconnect();
    this._accessibleDialogShadowObserver = null;
    this._accessibleDialogObservedShadow = null;
  },

  _refreshDialogFocusables() {
    const lightDomItems = Array.from(
      this.el.querySelectorAll(FOCUSABLE_SELECTOR),
    )
      .filter((element) => this._dialogElementEnabled(element))
      .map((element) => ({
        host: element,
        root: element.shadowRoot || null,
        target: this._dialogFocusTarget(element),
      }))
      .filter(({ target }) => typeof target?.focus === "function");

    const shadowRoot = this.el.shadowRoot;
    const shadowItems = Array.from(
      shadowRoot?.querySelectorAll?.(FOCUSABLE_SELECTOR) || [],
    )
      .filter((element) => this._dialogElementEnabled(element))
      .map((element) => ({ host: null, root: shadowRoot, target: element }));

    this._accessibleDialogFocusables = [...shadowItems, ...lightDomItems];

    const initialElement = this.el.querySelector(
      "[data-dialog-initial-focus]",
    );
    this._accessibleDialogInitialFocusable =
      lightDomItems.find(({ host }) => host === initialElement) || null;
  },

  _containDialogFocus(event) {
    if (event.key !== "Tab" || event.defaultPrevented) return;

    this._refreshDialogFocusables();
    const focusables = this._accessibleDialogFocusables || [];
    if (focusables.length === 0) return;

    const activeElement = document.activeElement;
    const activeIndex = focusables.findIndex((item) =>
      this._dialogItemActive(item, activeElement),
    );
    const target = event.shiftKey
      ? activeIndex <= 0
        ? focusables.at(-1)
        : null
      : activeIndex === -1 || activeIndex === focusables.length - 1
        ? focusables[0]
        : null;

    if (!target) return;

    event.preventDefault();
    this._focusDialogItem(target);
  },

  _dialogItemActive({ host, root, target }, activeElement) {
    return (
      activeElement === host ||
      activeElement === target ||
      (activeElement === (host || this.el) && root?.activeElement === target)
    );
  },

  _dialogContains(activeElement) {
    return activeElement === this.el || this.el.contains(activeElement);
  },

  _dialogElementEnabled(element) {
    return (
      !element.disabled &&
      !element.hidden &&
      !element.hasAttribute?.("disabled") &&
      element.getAttribute?.("aria-disabled") !== "true"
    );
  },

  _dialogFocusTarget(element) {
    return focusTarget(element);
  },

  _focusDialogItem(item) {
    item?.target?.focus?.();
  },

  _installDialogKeyListener() {
    if (this._accessibleDialogKeyListenerInstalled) return;

    document.addEventListener("keydown", this._accessibleDialogKeydown);
    this._accessibleDialogKeyListenerInstalled = true;
  },

  _removeDialogKeyListener() {
    if (!this._accessibleDialogKeyListenerInstalled) return;

    document.removeEventListener("keydown", this._accessibleDialogKeydown);
    this._accessibleDialogKeyListenerInstalled = false;
  },

  _cancelDialogFocusFrame() {
    if (this._accessibleDialogFocusFrame === null) return;

    cancelAnimationFrame(this._accessibleDialogFocusFrame);
    this._accessibleDialogFocusFrame = null;
    this._accessibleDialogFocusOnSync = false;
  },

  _restoreDialogFocus() {
    const invoker = this._accessibleDialogInvoker;
    this._accessibleDialogInvoker = null;

    if (!invoker || invoker.isConnected === false) return;

    this._dialogFocusTarget(invoker)?.focus?.();
  },
};

export default AccessibleDialog;
