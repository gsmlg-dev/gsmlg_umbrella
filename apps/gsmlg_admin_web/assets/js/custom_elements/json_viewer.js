export function formatJson(source) {
  try {
    return JSON.stringify(JSON.parse(source), null, 2);
  } catch {
    return source;
  }
}

const HTMLElementBase = globalThis.HTMLElement ?? class {};

export class ElGsmlgJson extends HTMLElementBase {
  connectedCallback() {
    this.format();

    this.observer?.disconnect();
    this.observer = new MutationObserver(() => this.format());
    this.observer.observe(this, {
      childList: true,
      characterData: true,
      subtree: true,
    });
  }

  disconnectedCallback() {
    this.observer?.disconnect();
  }

  format() {
    const formatted = formatJson(this.textContent ?? "");

    if (formatted !== this.textContent) {
      this.textContent = formatted;
    }
  }
}

if (
  globalThis.customElements &&
  !globalThis.customElements.get("el-gsmlg-json")
) {
  globalThis.customElements.define("el-gsmlg-json", ElGsmlgJson);
}
