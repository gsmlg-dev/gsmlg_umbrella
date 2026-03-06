import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import { WebComponentHook, FormElementHook, ThemeSwitcher as UpstreamThemeSwitcher, PageHeader, Spotlight } from "phoenix_duskmoon/hooks";

// Register duskmoon custom elements
import "@duskmoon-dev/elements/register";

// Workaround: upstream ThemeSwitcher doesn't apply data-theme to <html>
// See: https://github.com/duskmoon-dev/phoenix-duskmoon-ui/issues/15
function applyTheme(theme) {
  if (theme && theme !== "default") {
    document.documentElement.setAttribute("data-theme", theme);
  } else {
    document.documentElement.removeAttribute("data-theme");
  }
}

const ThemeSwitcher = {
  mounted() {
    UpstreamThemeSwitcher.mounted.call(this);
    applyTheme(localStorage.getItem("theme"));
    this.el.querySelectorAll(".theme-controller-item").forEach(input => {
      input.addEventListener("change", (e) => applyTheme(e.target.value));
    });
  },
  updated() { UpstreamThemeSwitcher.updated?.call(this); },
  destroyed() { UpstreamThemeSwitcher.destroyed?.call(this); },
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
  const socket = new LiveSocket("/live", Socket, { params, hooks, longPollFallbackMs: 2500 });
  return socket;
};

export const joinChannels = (socket) => {
  const channel = socket.channel("node:lobby", {});
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
