import { blogFormHook } from "./hooks/blog_form";
import TerminalHook from "./hooks/terminal_hook";

export const hooks = {
  ...blogFormHook,
  Terminal: TerminalHook,
};
