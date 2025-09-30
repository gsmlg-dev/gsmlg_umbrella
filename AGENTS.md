# AGENTS.md - AI Development Guidelines for GSMLG Phoenix Application

This file contains guidelines and rules for Large Language Models (LLMs) and AI-powered coding assistants working with the GSMLG Phoenix 1.8 application. These rules ensure AI-generated code follows Phoenix 1.8 best practices and integrates properly with the existing codebase.

## Phoenix 1.8 Core Principles

### 1. Security by Default (Scopes Pattern)
- **Always use scoped functions** when accessing user-specific data
- Use `list_users(scope)` instead of `list_users()` for user-specific operations
- Scope functions automatically filter data by the current user
- Access scope via `@current_scope` in templates and `socket.assigns.current_scope` in LiveViews

### 2. Explicit Layout System
- **Never use implicit layout configuration** - use explicit function calls
- Use `<Layouts.unified_layout>` component instead of old layout system
- Layouts are now function components that accept slots (header, footer, sidebar)
- Example: `<Layouts.unified_layout page_title="My Page"><:header>...</:header>...</Layouts.unified_layout>`

### 3. Magic Link Authentication
- **Default to magic links** for authentication, fall back to passwords only when necessary
- Use `MagicLink.generate_magic_link(email)` for authentication
- Magic links expire in 24 hours and are single-use
- Check email confirmation with `MagicLink.email_confirmed?(user)`

### 4. DaisyUI Component System
- **Use DaisyUI component classes** for styling: `btn`, `card`, `alert`, `modal`, etc.
- Theme switching is built-in - use `data-theme` attribute on HTML element
- Available themes: light, dark, cupcake, bumblebee, emerald, corporate, synthwave, retro, cyberpunk, valentine, halloween, garden, forest, aqua, lofi, pastel, fantasy, wireframe, black, luxury, dracula, cmyk, autumn, business, acid, lemonade, night, coffee, winter, dim, nord, sunset

## Phoenix 1.8 Code Patterns

### Controllers
```elixir
# Phoenix 1.8 Pattern - Explicit layout usage
def index(conn, _params) do
  conn
  |> put_root_layout({GSMLG.Web.Layouts, :unified_layout})
  |> render(:index, page_title: "My Page")
end

# ❌ Old Pattern - Implicit layout (DO NOT USE)
def index(conn, _params) do
  render(conn, :index)
end
```

### Context Functions (with Scopes)
```elixir
# Phoenix 1.8 Pattern - Scoped functions
def list_users(%Scope{} = scope) do
  query = from u in User, where: u.id == ^Scope.user_id(scope)
  Repo.all(query)
end

# ❌ Old Pattern - Unscoped (DO NOT USE unless public data)
def list_users do
  Repo.all(User)
end
```

### LiveViews
```elixir
# Phoenix 1.8 Pattern - Explicit layout in render function
def render(assigns) do
  ~H"""
  <Layouts.unified_layout page_title={@page_title}>
    <div class="container mx-auto px-4">
      <h1 class="text-3xl font-bold">My Content</h1>
    </div>
  </Layouts.unified_layout>
  """
end

# ❌ Old Pattern - Layout in use macro (DO NOT USE)
# use Phoenix.LiveView, layout: {GSMLG.Web.Layouts, :app}
```

### Templates with DaisyUI
```heex
<!-- Phoenix 1.8 Pattern - DaisyUI components -->
<div class="card bg-base-100 shadow-xl">
  <div class="card-body">
    <h2 class="card-title">Card Title</h2>
    <p>Card content</p>
    <div class="card-actions justify-end">
      <button class="btn btn-primary">Action</button>
    </div>
  </div>
</div>

<!-- Phoenix 1.8 Pattern - DaisyUI form components -->
<div class="form-control">
  <label class="label" for="email">
    <span class="label-text">Email</span>
  </label>
  <input type="email" name="email" id="email" class="input input-bordered" />
</div>
```

## Component Usage Rules

### Core Components (Phoenix 1.8)
Use the simplified core components from `GSMLG.Web.Components.CoreComponents`:

```elixir
# Buttons
<.button variant="primary" size="md">Click me</.button>
<.button variant="ghost" loading={@loading}>Loading...</.button>

# Forms
<.input field={@form[:email]} type="email" label="Email" />
<.input field={@form[:password]} type="password" label="Password" />
<.input field={@form[:remember_me]} type="checkbox" label="Remember me" />

# Layout
<.header>Page Title</.header>
<.footer />
<.card>
  <:header>Card Header</:header>
  <:body>Card Body</:body>
  <:footer>Card Footer</:footer>
</.card>

# Feedback
<.alert type="success">Success message!</.alert>
<.alert type="error">Error message!</.alert>
<.flash kind="info" flash={@flash} />
```

### Theme Switcher
Always include the theme switcher component in layouts:
```heex
<GSMLG.Web.Components.ThemeSwitcher.theme_switcher />
```

## Database Schema Guidelines

### User Model (Phoenix 1.8 Magic Links)
```elixir
# Required fields for Phoenix 1.8 magic link authentication
field :email, :string
field :magic_link_token, :string
field :magic_link_sent_at, :utc_datetime
field :magic_link_confirmed_at, :utc_datetime
field :email_confirmed_at, :utc_datetime
```

### Scoped Resources
When creating new resources that should be user-scoped:
```elixir
# Add user_id foreign key
field :user_id, :string

# Add belongs_to association
belongs_to :user, GSMLG.Accounts.User, foreign_key: :user_id, type: :string
```

## Security Guidelines

### Authorization (Scopes)
- Always check scope before data access: `Scope.has_user?(@current_scope)`
- Use scoped context functions: `Accounts.get_user(@current_scope, id)`
- Never bypass scope validation
- Scope is automatically available in controllers and LiveViews via plugs/hooks

### Authentication
- Use magic links as primary authentication method
- Store session tokens securely
- Implement proper session management
- Use Guardian for JWT tokens when needed

### Input Validation
- Always validate user input
- Use changesets for data validation
- Sanitize user-generated content
- Implement proper CSRF protection

## Error Handling

### Phoenix 1.8 Error Patterns
```elixir
# Use error components in templates
<.error :for={msg <- @errors} message={msg} />

# Handle errors gracefully in controllers
case Accounts.create_user(attrs) do
  {:ok, user} ->
    conn
    |> put_flash(:info, "User created successfully")
    |> redirect(to: ~p"/users/#{user}")

  {:error, changeset} ->
    render(conn, :new, changeset: changeset)
end
```

## Testing Guidelines

### Scope Testing
```elixir
# Test scoped functions
test "list_users/1 returns only user's own data" do
  scope = scope_fixture()
  user = user_fixture()

  assert Accounts.list_users(scope) == [user]
end
```

### Magic Link Testing
```elixir
# Test magic link generation
test "generate_magic_link/1 creates magic link for user" do
  email = "test@example.com"
  {:ok, user} = MagicLink.generate_magic_link(email)

  assert user.magic_link_token != nil
  assert user.magic_link_sent_at != nil
end
```

## File Structure Conventions

### Controllers
- Place in `lib/gsmlg_web/controllers/`
- Use explicit layout calls
- Handle scope properly
- Include proper error handling

### LiveViews
- Place in `lib/gsmlg_web/live/`
- Use explicit layout in render function
- Handle scope in mount/handle_params
- Include proper event handling

### Contexts
- Place in `lib/gsmlg/`
- Provide both scoped and unscoped functions
- Handle authorization at context level
- Include proper error handling

### Components
- Place in `lib/gsmlg_web/components/`
- Use DaisyUI classes for styling
- Follow Phoenix 1.8 component patterns
- Include proper documentation

## Common Pitfalls to Avoid

1. **Don't use implicit layouts** - Always be explicit about layout usage
2. **Don't bypass scopes** - Always use scoped functions for user data
3. **Don't use old authentication patterns** - Default to magic links
4. **Don't use complex Tailwind classes** - Use DaisyUI component classes
5. **Don't create overly complex components** - Keep components simple and focused
6. **Don't ignore Phoenix 1.8 patterns** - Follow the new architectural patterns

## Integration with Existing Code

When working with existing code that hasn't been updated to Phoenix 1.8 patterns:

1. **Gradually migrate** - Don't rewrite everything at once
2. **Maintain compatibility** - Keep existing functionality working
3. **Add new features** using Phoenix 1.8 patterns
4. **Update incrementally** - Migrate one component/context at a time
5. **Test thoroughly** - Ensure changes don't break existing functionality

## Performance Considerations

### Database Queries
- Use Ecto preloading for associations
- Implement proper pagination for large datasets
- Use database indexes for frequently queried fields
- Consider using materialized views for complex queries

### Frontend Performance
- Use Phoenix LiveView for dynamic content
- Implement proper caching strategies
- Optimize asset loading
- Use DaisyUI's optimized CSS

This AGENTS.md file should be updated as the application evolves and new Phoenix 1.8 patterns are implemented. Always refer to the latest Phoenix 1.8 documentation for the most up-to-date best practices.