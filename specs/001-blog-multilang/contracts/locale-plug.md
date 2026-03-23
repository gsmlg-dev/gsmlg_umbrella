# Contract: GSMLG.Web.Plugs.Locale

**Module**: `GSMLG.Web.Plugs.Locale`
**Path**: `apps/gsmlg_web/lib/gsmlg/web/plugs/locale.ex`

---

## Purpose

Resolves the visitor's preferred display locale and makes it available to all downstream controllers and templates via `conn.assigns.current_locale`. Sets Gettext locale for the request.

---

## Resolution Priority (FR-003)

1. `conn.params["lang"]` — explicit URL parameter
   - If valid supported locale: save to session, redirect to same path without `?lang=` param
   - If invalid: ignore, fall through to next source
2. `get_session(conn, :locale)` — previously saved preference
3. `get_req_header(conn, "accept-language")` — browser preference
   - Parse the first locale tag that maps to a supported locale
   - Use BCP 47 prefix matching: `"zh-CN"` matches `"zh-Hans"`, `"zh-TW"` matches `"zh-Hant"`
4. Config default: `Application.get_env(:gsmlg, :i18n)[:default_locale]`

---

## Side Effects

- Calls `Gettext.put_locale(GSMLG.Web.Gettext, resolved_locale)` — affects all `gettext/dgettext` calls in the request.
- Assigns `conn.assigns[:current_locale]` — available in all templates as `@current_locale`.
- Saves resolved locale to session: `put_session(conn, :locale, resolved_locale)`.

---

## `init/1` and `call/2` signatures

```elixir
@spec init(keyword()) :: keyword()
def init(opts), do: opts

@spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
def call(conn, _opts) do
  locale = resolve_locale(conn)
  conn
  |> put_session(:locale, locale)
  |> assign(:current_locale, locale)
  |> tap(fn _ -> Gettext.put_locale(GSMLG.Web.Gettext, locale) end)
end
```

---

## Router Placement

In `apps/gsmlg_web/lib/gsmlg/web/router.ex`, inside the `:browser` pipeline:

```elixir
pipeline :browser do
  plug :accepts, ["html"]
  plug :fetch_session
  plug :fetch_live_flash
  plug :put_root_layout, html: {GSMLG.Web.Layouts, :root}
  plug :protect_from_forgery
  plug :put_secure_browser_headers
  plug GSMLG.Web.Plugs.Locale    # ← add here, after session is available
  plug GSMLG.Web.Plugs.MaybeBrowserAuth
end
```

---

## Locale Mapping (Accept-Language → supported locale)

| Browser header prefix | Mapped supported locale |
|-----------------------|------------------------|
| `zh-Hans`, `zh-CN`, `zh-SG` | `"zh-Hans"` |
| `zh-Hant`, `zh-TW`, `zh-HK`, `zh-MO` | `"zh-Hant"` |
| `fr` | `"fr"` |
| `es` | `"es"` |
| `de` | `"de"` |
| `it` | `"it"` |
| `ja` | `"ja"` |
| `en`, anything else | `"en"` (if supported) or default |

Matching is case-insensitive. Unknown tags fall through to the config default.
