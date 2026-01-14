/**
 * Clipboard Hook for copying text to clipboard
 *
 * Usage: Add phx-hook="Clipboard" and data-clipboard-target="#element-id" to a button
 */

export const ClipboardHook = {
  mounted() {
    this.el.addEventListener('click', (e) => {
      e.preventDefault();

      const targetSelector = this.el.dataset.clipboardTarget;
      const targetEl = document.querySelector(targetSelector);

      if (targetEl) {
        const text = targetEl.value || targetEl.textContent;

        navigator.clipboard.writeText(text).then(() => {
          // Show feedback
          this.showCopiedFeedback();
        }).catch((err) => {
          console.error('Failed to copy text:', err);
          // Fallback for older browsers
          this.fallbackCopy(text);
        });
      }
    });
  },

  showCopiedFeedback() {
    const originalContent = this.el.innerHTML;
    this.el.innerHTML = `
      <svg class="w-5 h-5 text-green-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"></path>
      </svg>
    `;

    setTimeout(() => {
      this.el.innerHTML = originalContent;
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
      document.execCommand('copy');
      this.showCopiedFeedback();
    } catch (err) {
      console.error('Fallback copy failed:', err);
    }

    document.body.removeChild(textarea);
  }
};

export default ClipboardHook;
