import { blogFormHook } from "./hooks/blog_form";
import TerminalHook from "./hooks/terminal_hook";
import ClipboardHook from "./hooks/clipboard_hook";
import { GaoNoteLabelsMultiSelect } from "./hooks/gao_note_labels_multi_select";
import ProxyRulesSourceViewer from "./hooks/proxy_rules_source_viewer";
import { WebComponentHook, FormElementHook, ThemeSwitcher as UpstreamThemeSwitcher, PageHeader, Spotlight } from "phoenix_duskmoon/hooks";

// Register duskmoon custom elements
import "@duskmoon-dev/elements/register";
import "@duskmoon-dev/el-markdown/register";
import "@duskmoon-dev/el-markdown-input/register";

window.addEventListener("phx:close-dialog", (event) => {
  document.getElementById(event.detail.id)?.close?.();
});

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

export const hooks = {
  ...blogFormHook,
  Terminal: TerminalHook,
  Clipboard: ClipboardHook,
  GaoNoteLabelsMultiSelect,
  ProxyRulesSourceViewer,
  WebComponentHook,
  FormElementHook,
  ThemeSwitcher,
  PageHeader,
  Spotlight,
};
