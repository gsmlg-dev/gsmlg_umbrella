import { LitElement, html, css } from 'lit';
import { ref, createRef } from 'lit/directives/ref.js';


class ConnectNode extends LitElement {

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

    this.target_node = '';
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
          action: 'connect-node',
          target_node: this.target_node,
        }),
      });
      const data = await resp.json();
      const { target_node } = data;
      const el = document.getElementById('node-target_node-value');
      el.innerText = target_node;
      this.loading = false;
    } catch (e) {
      this.loading = false;
    }
  }

  render() {
    return html`
      <div class="form-group">
          <input type="text" @change=${(evt) => this.target_node = evt.target.value} .value=${this.target_node} ?disabled=${this.loading} />
          <button @click=${this.clickMe} ?disabled=${this.loading}>
              ${this.loading ? 'Connecting ...' : 'Connect Node'}
          </button>
      </div>
    `;
  }
}

customElements.define('connect-node', ConnectNode);
