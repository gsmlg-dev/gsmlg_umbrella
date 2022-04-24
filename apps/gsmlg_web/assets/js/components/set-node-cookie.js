import { LitElement, html, css } from 'lit';
import { ref, createRef } from 'lit/directives/ref.js';


class SetNodeCookie extends LitElement {

  static styles = css`
    :root {
      width: inherit;
      height: inherit;
      font-size: inherit;
    }
    .form-group input,
    .form-group button {
      padding: 0.3rem;
      font-size: inherit;
    }
    .form-group input {
      min-width: 400px;
    }
    .form-group button {
      cursor: pointer;
    }
  `;

  inputRef = createRef();

  constructor() {
    super();

    this.cookie = '';
    this._loading = false;
  }

  get loading() {
    return this._loading;
  }

  set loading(val) {
    this._loading = !!val;
    this.requestUpdate();
  }

  async clickMe(evt) {
    this.loading = true;
    try {
      const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");

      const resp = await fetch('/admin/node_management', {
        method: 'POST',
        headers: {
          'x-csrf-token': csrfToken,
          'content-type': 'application/json',
        },
        body: JSON.stringify({
          action: 'set-node-cookie',
          cookie: this.cookie,
        }),
      });
      const data = await resp.json();
      const { cookie } = data;
      const el = document.getElementById('node-cookie-value');
      el.innerText = cookie;
      this.loading = false;
    } catch (e) {
      this.loading = false;
    }
  }

  render() {
    return html`
      <div class="form-group">
          <input type="text" @change=${(evt) => this.cookie = evt.target.value} .value=${this.cookie} ?disabled=${this.loading} />
          <button @click=${this.clickMe} ?disabled=${this.loading}>
              ${this.loading ? 'Updating ...' : 'Set Cookie'}
          </button>
      </div>
    `;
  }
}

customElements.define('set-node-cookie', SetNodeCookie);
