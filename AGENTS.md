# AGENTS.md - AI Development Guidelines for GSMLG Phoenix Application

## Commands
- Build: `mix compile` (umbrella) or `cd apps/app_name && mix compile`
- Test: `mix test` (umbrella) or `cd apps/app_name && mix test`
- Single test: `mix test path/to/test.exs:line_number`
- Format: `mix format` (uses .formatter.exs config with Phoenix.LiveView.HTMLFormatter)
- Lint: No dedicated linter - use `mix format` and `mix compile` warnings
- Setup: `mix setup` (runs setup in all child apps)
- Assets: `mix assets.deploy` (builds and minifies assets)

## Code Style
- Use `mix format` for all Elixir/HEEX files (configured with Phoenix.LiveView.HTMLFormatter)
- Import dependencies at top of modules, group by type (standard lib, third-party, local)
- Use `@moduledoc` and `@doc` attributes for documentation
- Error handling with `case` statements and proper error tuples (`{:ok, result}`/`{:error, changeset}`)
- Test files in `test/` directory with `*_test.exs` naming
- Umbrella project: work in specific app directories (`cd apps/app_name`) for app-specific tasks
- Use `use GSMLG.Web, :controller` or `use GSMLG.Web, :html` for web modules
- Use PhoenixDuskmoon components and GSMLG.Component for UI elements