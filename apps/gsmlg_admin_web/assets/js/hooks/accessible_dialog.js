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

const AccessibleDialog = {
  mounted() {
    this._accessibleDialogDestroyed = false;
    this._accessibleDialogOpen = false;
    this._accessibleDialogInvoker = null;
    this._accessibleDialogFocusFrame = null;
    this._accessibleDialogKeyListenerInstalled = false;
    this._accessibleDialogFallbackLabel =
      this.el.getAttribute("aria-label")?.trim() || "";
    this._accessibleDialogKeydown = (event) => this._containDialogFocus(event);

    this._configureDialogSemantics();
    this._refreshDialogFocusables();

    this._accessibleDialogObserver = new MutationObserver((mutations) => {
      if (mutations.some(({ attributeName }) => attributeName === "open")) {
        this._configureDialogSemantics();
        this._syncDialogOpenState();
      }
    });
    this._accessibleDialogObserver.observe(this.el, {
      attributes: true,
      attributeFilter: ["open"],
    });

    this._syncDialogOpenState();
  },

  updated() {
    if (this._accessibleDialogDestroyed) return;

    this._configureDialogSemantics();
    this._refreshDialogFocusables();
    this._syncDialogOpenState();
  },

  destroyed() {
    this._accessibleDialogDestroyed = true;
    this._accessibleDialogObserver?.disconnect();
    this._accessibleDialogObserver = null;
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
    this._refreshDialogFocusables();
    this._installDialogKeyListener();
    this._cancelDialogFocusFrame();
    this._accessibleDialogFocusFrame = requestAnimationFrame(() => {
      this._accessibleDialogFocusFrame = null;
      if (this._accessibleDialogDestroyed || !this._accessibleDialogOpen) return;

      this._focusDialogItem(
        this._accessibleDialogInitialFocusable ||
          this._accessibleDialogFocusables[0],
      );
    });
  },

  _closeAccessibleDialog() {
    this._accessibleDialogOpen = false;
    this._cancelDialogFocusFrame();
    this._removeDialogKeyListener();
    this._restoreDialogFocus();
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
    return element.shadowRoot?.querySelector(FOCUSABLE_SELECTOR) || element;
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
  },

  _restoreDialogFocus() {
    const invoker = this._accessibleDialogInvoker;
    this._accessibleDialogInvoker = null;

    if (!invoker || invoker.isConnected === false) return;

    this._dialogFocusTarget(invoker)?.focus?.();
  },
};

export default AccessibleDialog;
