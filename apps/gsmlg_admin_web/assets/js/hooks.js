import { blogFormHook } from "./hooks/blog_form";
import TerminalHook from "./hooks/terminal_hook";
import ClipboardHook from "./hooks/clipboard_hook";

export const hooks = {
  ...blogFormHook,
  Terminal: TerminalHook,
  Clipboard: ClipboardHook,
};
