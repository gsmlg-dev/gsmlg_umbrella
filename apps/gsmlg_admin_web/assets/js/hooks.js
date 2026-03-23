import { blogFormHook } from "./hooks/blog_form";
import TerminalHook from "./hooks/terminal_hook";
import ClipboardHook from "./hooks/clipboard_hook";
import { WebComponentHook, FormElementHook, ThemeSwitcher as UpstreamThemeSwitcher, PageHeader, Spotlight } from "phoenix_duskmoon/hooks";

// Register duskmoon custom elements
import "@duskmoon-dev/elements/register";
import "@duskmoon-dev/el-markdown-input/register";

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

export const hooks = {
  ...blogFormHook,
  Terminal: TerminalHook,
  Clipboard: ClipboardHook,
  WebComponentHook,
  FormElementHook,
  ThemeSwitcher,
  PageHeader,
  Spotlight,
};
