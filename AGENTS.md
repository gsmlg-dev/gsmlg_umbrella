# AGENTS.md - AI Development Guidelines for GSMLG Phoenix Application

## Commands
- Build: `mix compile` (umbrella) or `cd apps/app_name && mix compile`
- Test: `mix test` (umbrella) or `cd apps/app_name && mix test`
- Single test: `mix test path/to/test.exs:line_number`
- Format: `mix format` (uses .formatter.exs config)
- Lint: No dedicated linter - use `mix format` and `mix compile` warnings
- Setup: `mix setup` (runs setup in all child apps)
- Assets: `mix assets.deploy` (builds and minifies assets)

## Code Style
- Use `mix format` for all Elixir/HEEX files (configured with Phoenix.LiveView.HTMLFormatter)
- Import dependencies at top of modules, group by type (standard lib, third-party, local)
- Use `@moduledoc` and `@doc` attributes for documentation
- Follow Phoenix 1.8 patterns: explicit layouts, scoped functions, magic links
- Use DaisyUI component classes for styling
- Error handling with `case` statements and proper error tuples (`{:ok, result}`/`{:error, changeset}`)
- Test files in `test/` directory with `*_test.exs` naming
- Umbrella project: work in specific app directories (`cd apps/app_name`) for app-specific tasks

## Phoenix 1.8 Core Principles

### 1. Security by Default (Scopes Pattern)
- **Always use scoped functions** when accessing user-specific data
- Use `list_users(scope)` instead of `list_users()` for user-specific operations
- Scope functions automatically filter data by the current user
- Access scope via `@current_scope` in templates and `socket.assigns.current_scope` in LiveViews

### 2. Explicit Layout System
- **Root layout is set in router** with `plug(:put_root_layout, {GSMLG.Web.Layouts, :root})`
- **App and Auth layouts are function components** in `GSMLG.Web.Layouts` module
- Use `<Layouts.app flash={@flash}>` for main application pages
- Use `<Layouts.auth flash={@flash}>` for authentication pages
- Layouts accept `flash` and `current_scope` assigns, plus `inner_block` slot
- Example: `<Layouts.app flash={@flash}><h1>Content</h1></Layouts.app>`

### 3. Magic Link Authentication
- **Default to magic links** for authentication, fall back to passwords only when necessary
- Use `MagicLink.generate_magic_link(email)` for authentication
- Magic links expire in 24 hours and are single-use
- Check email confirmation with `MagicLink.email_confirmed?(user)`

### 4. DaisyUI Component System
- **Use DaisyUI component classes** for styling: `btn`, `card`, `alert`, `modal`, etc.
- Theme switching is built-in - use `data-theme` attribute on HTML element

## Phoenix 1.8 Patterns
- Controllers: Root layout set in router with `put_root_layout({GSMLG.Web.Layouts, :root})`
- Contexts: Provide scoped functions like `list_users(scope)` for user data
- LiveViews: Use explicit layout in render function, not in `use` macro
- Templates: Use DaisyUI classes (`btn`, `card`, `alert`) and core components
- Authentication: Default to magic links, use Guardian for JWT tokens
- Error handling: Use `case` statements with `{:ok, result}` and `{:error, changeset}` tuples