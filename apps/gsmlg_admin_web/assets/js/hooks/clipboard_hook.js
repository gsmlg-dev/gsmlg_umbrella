/**
 * Clipboard Hook for copying text to clipboard
 *
 * Usage:
 * - data-clipboard-text="literal text"
 * - data-clipboard-target="#element-id" for existing target-based callers
 */

export const ClipboardHook = {
  mounted() {
    this._clipboardClick = (event) => {
      event.preventDefault();

      const text = this.clipboardText();

      if (text === null) {
        this.showFeedback('Copy unavailable', 'error');
        return;
      }

      if (navigator.clipboard?.writeText) {
        navigator.clipboard.writeText(text)
          .then(() => this.showFeedback('Copied', 'copied'))
          .catch(() => this.fallbackCopy(text));
      } else {
        this.fallbackCopy(text);
      }
    };

    this.el.addEventListener('click', this._clipboardClick);
  },

  destroyed() {
    this.el.removeEventListener('click', this._clipboardClick);
    clearTimeout(this._clipboardFeedbackTimer);
  },

  clipboardText() {
    if (Object.prototype.hasOwnProperty.call(this.el.dataset, 'clipboardText')) {
      return this.el.dataset.clipboardText;
    }

    const targetSelector = this.el.dataset.clipboardTarget;
    const targetEl = targetSelector ? document.querySelector(targetSelector) : null;

    return targetEl ? (targetEl.value || targetEl.textContent) : null;
  },

  showFeedback(message, state) {
    const feedback = this.el.querySelector('[data-clipboard-feedback]');
    this.el.dataset.clipboardState = state;

    if (!feedback) return;

    this._clipboardOriginalText ??= feedback.textContent;
    feedback.textContent = message;
    clearTimeout(this._clipboardFeedbackTimer);

    this._clipboardFeedbackTimer = setTimeout(() => {
      feedback.textContent = this._clipboardOriginalText;
      delete this.el.dataset.clipboardState;
    }, 2000);
  },

  fallbackCopy(text) {
    const textarea = document.createElement('textarea');
    textarea.value = text;
    textarea.style.position = 'fixed';
    textarea.style.opacity = '0';
    document.body.appendChild(textarea);
    textarea.select();

    try {
      if (document.execCommand('copy')) {
        this.showFeedback('Copied', 'copied');
      } else {
        this.showFeedback('Copy failed', 'error');
      }
    } catch (_error) {
      this.showFeedback('Copy failed', 'error');
    }

    document.body.removeChild(textarea);
  }
};

export default ClipboardHook;
