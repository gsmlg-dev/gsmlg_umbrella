import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import { WebComponentHook, FormElementHook, ThemeSwitcher as UpstreamThemeSwitcher, PageHeader, Spotlight } from "phoenix_duskmoon/hooks";

// Register duskmoon custom elements
import "@duskmoon-dev/elements/register";

const darkQuery = window.matchMedia("(prefers-color-scheme: dark)");

function resolveTheme(theme) {
  return (!theme || theme === "default") ? (darkQuery.matches ? "moonlight" : "sunshine") : theme;
}

function applyTheme(theme) {
  document.documentElement.setAttribute("data-theme", resolveTheme(theme));
}

const ThemeSwitcher = {
  mounted() {
    UpstreamThemeSwitcher.mounted.call(this);

    applyTheme(this.el.dataset.theme || localStorage.getItem("theme") || "default");

    this._gsmlgMediaListener = () => {
      const theme = localStorage.getItem("theme") || "default";
      if (theme === "default") applyTheme(theme);
    };
    darkQuery.addEventListener("change", this._gsmlgMediaListener);

    this._gsmlgChangeListeners = [];
    this.el.querySelectorAll(".theme-controller-item").forEach(input => {
      const listener = (event) => requestAnimationFrame(() => applyTheme(event.target.value));
      input.addEventListener("change", listener);
      this._gsmlgChangeListeners.push({ element: input, listener });
    });
  },
  updated() {
    UpstreamThemeSwitcher.updated?.call(this);
    applyTheme(this.el.dataset.theme || localStorage.getItem("theme") || "default");
  },
  destroyed() {
    this._gsmlgChangeListeners?.forEach(({ element, listener }) => {
      element.removeEventListener("change", listener);
    });
    this._gsmlgChangeListeners = null;

    if (this._gsmlgMediaListener) {
      darkQuery.removeEventListener("change", this._gsmlgMediaListener);
      this._gsmlgMediaListener = null;
    }

    UpstreamThemeSwitcher.destroyed?.call(this);
  },
};

const hooks = { WebComponentHook, FormElementHook, ThemeSwitcher, PageHeader, Spotlight };

let token;

export const startSocket = (t) => {
  if (t) token = t;
  const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
  const params = { _csrf_token: csrfToken };
  if (token != null) {
    params.token = token;
  }
  // LiveSocket for LiveView — connects to /live
  const liveSocket = new LiveSocket("/live", Socket, { params, hooks, longPollFallbackMs: 2500 });
  return liveSocket;
};

export const joinChannels = () => {
  // Separate raw Socket for custom channels — connects to /socket (UserSocket)
  const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
  const userSocket = new Socket("/socket", { params: { _csrf_token: csrfToken } });
  userSocket.connect();

  const channel = userSocket.channel("node:lobby", {});
  channel.join()
    .receive("ok", resp => { console.log("Joined successfully", resp) })
    .receive("error", resp => { console.log("Unable to join", resp) });

  channel.on('node_info', (info) => {
    console.log('node info: ', info);
  });
  channel.on('list_info', (info) => {
    console.log('list info: ', info);
  });
};
