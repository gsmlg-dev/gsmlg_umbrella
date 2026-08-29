# Admin mTLS Certificate Login Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bind Caddy-verified client certificates to admin users after one password login, then automatically establish that user's Guardian browser session whenever the same certificate returns.

**Architecture:** `GSMLG.Accounts` owns an immutable, fingerprint-unique certificate binding table. A dedicated admin header parser turns Caddy's DER-base64 assertion into a validated certificate value, while a browser-only plug handles enrollment or Guardian session establishment and a LiveView hook rejects stale certificate-session reconnects. Existing API, MCP, Commander, bearer-token, and password-only behavior stays outside this certificate pipeline.

**Tech Stack:** Elixir 1.18, OTP 28 `:public_key` and `:crypto`, Phoenix 1.8, Plug, Guardian/GuardianDB, LiveView, Ecto/PostgreSQL, NimbleOptions/TOML, PhoenixDuskmoon.

**Design:** `docs/superpowers/specs/2026-08-29-admin-mtls-certificate-login-design.md`

---

## File Structure

### New files

- `apps/gsmlg/priv/repo/migrations/20260829000000_create_user_client_certificates.exs` — durable ownership, uniqueness, cascade, and fingerprint-format constraints.
- `apps/gsmlg/lib/gsmlg/accounts/user_client_certificate.ex` — binding schema and create-only changeset.
- `apps/gsmlg_admin_web/lib/gsmlg/admin_web/client_certificate.ex` — strict Caddy header parsing, X.509 validation, fingerprinting, and PEM reconstruction.
- `apps/gsmlg_admin_web/lib/gsmlg/admin_web/guardian/optional_web_auth_error_handler.ex` — bounded optional browser Guardian error handling.
- `apps/gsmlg_admin_web/lib/gsmlg/admin_web/plugs/client_certificate_auth.ex` — browser request enrollment and Guardian-session policy.
- `apps/gsmlg_admin_web/test/support/client_certificate_fixtures.ex` — OTP-generated public test certificates and request-header helpers.
- `apps/gsmlg_admin_web/test/gsmlg/admin_web/client_certificate_test.exs` — parser boundary tests.
- `apps/gsmlg_admin_web/test/gsmlg/admin_web/client_certificate_isolation_test.exs` — bearer, API, MCP, browser-JSON, and socket transport-isolation tests.
- `apps/gsmlg_admin_web/test/gsmlg/admin_web/plugs/client_certificate_auth_test.exs` — end-to-end browser pipeline/session tests.
- `apps/gsmlg_admin_web/test/gsmlg/admin_web/live/hooks/assign_current_user_test.exs` — LiveView reconnect enforcement tests.
- `apps/gsmlg_telemetry/test/gsmlg/telemetry/handler_test.exs` — telemetry whitelist, redaction, and traversal-bound tests.

### Modified files

- `apps/gsmlg_config/lib/gsmlg/config/schema.ex` — `admin_web.client_certificate_auth` schema.
- `apps/gsmlg_config/lib/gsmlg/config/setup.ex` — propagate the toggle to admin endpoint config.
- `apps/gsmlg_config/priv/gsmlg.toml` — default disabled.
- `apps/gsmlg_config/priv/gsmlg.dev.toml` — development disabled.
- `apps/gsmlg_config/priv/gsmlg.test.toml` — tests disabled unless a test enables it explicitly.
- `apps/gsmlg_config/priv/gsmlg.prod.toml` — production template enabled.
- `apps/gsmlg_config/test/gsmlg/config/schema_test.exs` — validation and checked-in TOML assertions.
- `apps/gsmlg_config/test/gsmlg/config/setup_test.exs` — endpoint propagation assertions.
- `apps/gsmlg/lib/gsmlg/accounts/user.ex` — `has_many` binding association.
- `apps/gsmlg/lib/gsmlg/accounts.ex` — fingerprint lookup and race-safe binding API.
- `apps/gsmlg/test/support/fixtures/accounts_fixtures.ex` — domain binding attributes/fixture.
- `apps/gsmlg/test/gsmlg/accounts_test.exs` — ownership, idempotence, uniqueness, multiplicity, and cascade tests.
- `apps/gsmlg_admin_web/mix.exs` — declare `:public_key` as a runtime application.
- `apps/gsmlg_admin_web/lib/gsmlg/admin_web/router.ex` — add an HTML-only certificate pipeline after Guardian loading.
- `apps/gsmlg_admin_web/lib/gsmlg/admin_web/controllers/auth_controller.ex` — enrollment, password-session marker, certificate-authoritative POST, and sign-out behavior.
- `apps/gsmlg_admin_web/lib/gsmlg/admin_web/controllers/auth_html/sign_in.html.heex` — certificate disclosure and permanence notice.
- `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/hooks/assign_current_user.ex` — verify certificate-created LiveView reconnects.
- `apps/gsmlg_admin_web/lib/gsmlg/admin_web.ex` — install the reconnect hook and set `log: false` for all three admin LiveView macros; Phoenix lifecycle logging is suppressed while telemetry remains active.
- `apps/gsmlg_admin_web/lib/gsmlg/admin_web/components/layouts/root.html.heex` — expose the server-established auth method to scoped styling.
- `apps/gsmlg_admin_web/assets/css/main.css` — certificate panel styling and certificate-session sign-out hiding.
- `apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/auth_controller_test.exs` — enrollment, rendering, conflicts, fallbacks, and sign-out tests.
- `apps/gsmlg_component/lib/gsmlg/component/admin.ex` — stable sign-out element ID.
- `apps/gsmlg_component/test/gsmlg/component_test.exs` — sign-out hook assertion.
- `apps/gsmlg_telemetry/lib/gsmlg/telemetry/handler.ex` — sanitize known Phoenix/GSMLG Repo/Ecto events and bounded custom metadata before Metrics, Reporter, and backends.
- `config/config.exs` — defense-in-depth Phoenix parameter filtering for password, password confirmation, token, and certificate.

No endpoint change is required: `/live` already exposes `:x_headers` and the cookie session in its connect info.

The optional Guardian web-auth error handler is part of the browser pipeline so
an intentionally cleared certificate session remains an ordinary optional-auth
redirect. It does not expand certificate authentication to JSON, MCP,
Commander, bearer-token, or socket transports.

## Shared contracts

Use these names consistently in every task:

```elixir
# Plug session keys
"admin_auth_method"                  # "password" | "client_certificate"
"admin_client_certificate_fingerprint" # lowercase SHA-256 DER hex

# Connection assigns
:admin_auth_method
:client_certificate
:client_certificate_authenticated
```

The certificate value is:

```elixir
%GSMLG.AdminWeb.ClientCertificate{
  certificate_der: binary(),
  fingerprint: <<_::512>>,
  pem: binary(),
  subject: binary(),
  email: binary()
}
```

The Accounts binding API accepts only the authenticated `%User{}` plus certificate data. It recomputes the fingerprint and never accepts caller-supplied ownership.

---

### Task 1: Add the production-gated configuration toggle

**Files:**

- Modify: `apps/gsmlg_config/lib/gsmlg/config/schema.ex:111-140`
- Modify: `apps/gsmlg_config/lib/gsmlg/config/setup.ex:166-183`
- Modify: `apps/gsmlg_config/priv/gsmlg.toml:23-28`
- Modify: `apps/gsmlg_config/priv/gsmlg.dev.toml:21-26`
- Modify: `apps/gsmlg_config/priv/gsmlg.test.toml:24-29`
- Modify: `apps/gsmlg_config/priv/gsmlg.prod.toml:23-28`
- Test: `apps/gsmlg_config/test/gsmlg/config/schema_test.exs`
- Test: `apps/gsmlg_config/test/gsmlg/config/setup_test.exs`

- [ ] **Step 1: Write failing schema and checked-in TOML tests**

Add these tests to `SchemaTest`:

```elixir
test "admin certificate authentication defaults to disabled" do
  assert {:ok, %{admin_web: settings}} =
           Schema.validate(%{admin_web: %{url: "https://admin.example.test"}})

  assert settings.client_certificate_auth == false
end

test "accepts an enabled admin certificate authentication setting" do
  assert {:ok, %{admin_web: settings}} =
           Schema.validate(%{
             admin_web: %{
               url: "https://admin.example.test",
               client_certificate_auth: true
             }
           })

  assert settings.client_certificate_auth == true
end

test "rejects a non-boolean admin certificate authentication setting" do
  assert {:error, reason} =
           Schema.validate(%{
             admin_web: %{
               url: "https://admin.example.test",
               client_certificate_auth: "true"
             }
           })

  assert reason =~ "admin_web"
  assert reason =~ "boolean"
end

test "checked-in TOML files configure admin certificate authentication" do
  config_dir = Path.expand("../../../priv", __DIR__)

  for {filename, expected} <- [
        {"gsmlg.toml", false},
        {"gsmlg.dev.toml", false},
        {"gsmlg.test.toml", false},
        {"gsmlg.prod.toml", true}
      ] do
    assert {:ok, config} = Toml.decode_file(Path.join(config_dir, filename), keys: :atoms)
    assert config.admin_web.client_certificate_auth == expected
  end
end
```

Extend the existing `"configures admin web endpoint"` setup test with `client_certificate_auth: true` and:

```elixir
assert endpoint_config[:client_certificate_auth] == true
```

Add this setup test:

```elixir
test "defaults admin certificate authentication to disabled" do
  Setup.setup_admin_web(%{
    url: "https://admin.example.test",
    secret_key_base: "admin_secret",
    port: 4111
  })

  endpoint_config = Application.get_env(:gsmlg_admin_web, GSMLG.AdminWeb.Endpoint)
  assert endpoint_config[:client_certificate_auth] == false
end
```

- [ ] **Step 2: Run the focused tests and confirm the expected failures**

Run:

```bash
mix test \
  apps/gsmlg_config/test/gsmlg/config/schema_test.exs \
  apps/gsmlg_config/test/gsmlg/config/setup_test.exs
```

Expected: failures because the schema does not return `client_certificate_auth`, setup does not propagate it, and the TOML keys are absent.

- [ ] **Step 3: Add the schema and setup implementation**

Add to `@admin_web_schema` immediately after `user_register`:

```elixir
client_certificate_auth: [
  type: :boolean,
  default: false,
  doc: "Trust reverse-proxy-verified client certificate headers for admin browser login"
],
```

Add to `setup_admin_web/1`:

```elixir
client_certificate_auth: config[:client_certificate_auth] == true
```

- [ ] **Step 4: Set explicit values in active TOML files**

Add under each `[admin_web]` section:

```toml
client_certificate_auth = false
```

Use `true` only in `apps/gsmlg_config/priv/gsmlg.prod.toml`.

- [ ] **Step 5: Run the focused tests**

Run the Step 2 command.

Expected: all schema and setup tests pass.

- [ ] **Step 6: Format and commit the configuration slice**

```bash
mix format \
  apps/gsmlg_config/lib/gsmlg/config/schema.ex \
  apps/gsmlg_config/lib/gsmlg/config/setup.ex \
  apps/gsmlg_config/test/gsmlg/config/schema_test.exs \
  apps/gsmlg_config/test/gsmlg/config/setup_test.exs
git add apps/gsmlg_config
git commit -m "feat(config): add admin certificate auth toggle"
```

---

### Task 2: Persist immutable certificate ownership in Accounts

**Files:**

- Create: `apps/gsmlg/priv/repo/migrations/20260829000000_create_user_client_certificates.exs`
- Create: `apps/gsmlg/lib/gsmlg/accounts/user_client_certificate.ex`
- Modify: `apps/gsmlg/lib/gsmlg/accounts/user.ex`
- Modify: `apps/gsmlg/lib/gsmlg/accounts.ex`
- Modify: `apps/gsmlg/test/support/fixtures/accounts_fixtures.ex`
- Test: `apps/gsmlg/test/gsmlg/accounts_test.exs`

- [ ] **Step 1: Add failing Accounts tests and fixture helpers**

Add to `AccountsFixtures`:

```elixir
def client_certificate_attrs(overrides \\ %{}) do
  Map.merge(
    %{
      certificate_der: :crypto.strong_rand_bytes(64),
      subject: "CN=Admin Client,O=GSMLG Test",
      email: "admin-client@example.test"
    },
    Map.new(overrides)
  )
end

def user_client_certificate_fixture(user, attrs \\ %{}) do
  {:ok, binding} =
    GSMLG.Accounts.bind_user_client_certificate(user, client_certificate_attrs(attrs))

  binding
end
```

Add a `describe "user client certificates"` block to `AccountsTest` covering the public contract:

```elixir
describe "user client certificates" do
  alias GSMLG.Accounts.User
  alias GSMLG.Accounts.UserClientCertificate

  import GSMLG.AccountsFixtures

  test "binds DER to a user and loads its authoritative owner" do
    user = user_fixture()
    attrs = client_certificate_attrs()

    assert {:ok, %UserClientCertificate{} = binding} =
             Accounts.bind_user_client_certificate(user, attrs)

    expected_fingerprint =
      attrs.certificate_der
      |> :crypto.hash(:sha256)
      |> Base.encode16(case: :lower)

    assert binding.user_id == user.id
    assert binding.certificate_der == attrs.certificate_der
    assert binding.fingerprint == expected_fingerprint
    assert binding.subject == attrs.subject
    assert binding.email == attrs.email

    loaded = Accounts.get_user_client_certificate_by_fingerprint(expected_fingerprint)
    assert %User{id: user_id} = loaded.user
    assert user_id == user.id
  end

  test "rebinding the same certificate to the same user is idempotent" do
    user = user_fixture()
    attrs = client_certificate_attrs()

    assert {:ok, first} = Accounts.bind_user_client_certificate(user, attrs)

    assert {:ok, second} =
             Accounts.bind_user_client_certificate(user, %{
               attrs
               | subject: "CN=Changed Display Value",
                 email: "changed@example.test"
             })

    assert second.id == first.id
    assert second.subject == attrs.subject
    assert second.email == attrs.email
  end

  test "a certificate cannot be rebound to another user" do
    owner = user_fixture(%{username: "cert_owner", email: "owner@example.test"})
    other = user_fixture(%{username: "cert_other", email: "other@example.test"})
    attrs = client_certificate_attrs()

    assert {:ok, binding} = Accounts.bind_user_client_certificate(owner, attrs)

    assert {:error, {:client_certificate_already_bound, owner_id}} =
             Accounts.bind_user_client_certificate(other, attrs)

    assert owner_id == owner.id
    assert Accounts.get_user_client_certificate_by_fingerprint(binding.fingerprint).user_id ==
             owner.id
  end

  test "one user can own multiple certificates and deletion cascades" do
    user = user_fixture()
    first = user_client_certificate_fixture(user)
    second = user_client_certificate_fixture(user)

    refute first.id == second.id
    assert {:ok, _user} = Accounts.delete_user(user)
    assert GSMLG.Repo.get(UserClientCertificate, first.id) == nil
    assert GSMLG.Repo.get(UserClientCertificate, second.id) == nil
  end
end
```

- [ ] **Step 2: Run the Accounts tests and verify the missing-module/API failure**

```bash
mix test apps/gsmlg/test/gsmlg/accounts_test.exs
```

Expected: compilation fails because `UserClientCertificate` and the context functions do not exist.

- [ ] **Step 3: Create the migration**

Create `20260829000000_create_user_client_certificates.exs`:

```elixir
defmodule GSMLG.Repo.Migrations.CreateUserClientCertificates do
  use Ecto.Migration

  def change do
    create table(:user_client_certificates, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id,
          references(:users,
            type: :string,
            on_delete: :delete_all,
            name: :user_client_certificates_user_id_fkey
          ),
          null: false

      add :fingerprint, :string, size: 64, null: false
      add :certificate_der, :binary, null: false
      add :subject, :text, null: false
      add :email, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:user_client_certificates, [:fingerprint],
             name: :user_client_certificates_fingerprint_index
           )

    create index(:user_client_certificates, [:user_id],
             name: :user_client_certificates_user_id_index
           )

    create constraint(
             :user_client_certificates,
             :user_client_certificates_fingerprint_format,
             check: "fingerprint ~ '^[0-9a-f]{64}$'"
           )
  end
end
```

Run:

```bash
MIX_ENV=test mix ecto.migrate
```

Expected: migration applies successfully to the test database.

- [ ] **Step 4: Create the schema and user association**

Create `user_client_certificate.ex`:

```elixir
defmodule GSMLG.Accounts.UserClientCertificate do
  use Ecto.Schema
  import Ecto.Changeset

  alias GSMLG.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "user_client_certificates" do
    belongs_to(:user, User, type: :string)
    field(:fingerprint, :string)
    field(:certificate_der, :binary)
    field(:subject, :string)
    field(:email, :string)
    timestamps()
  end

  def create_changeset(binding, attrs) do
    binding
    |> cast(attrs, [:user_id, :fingerprint, :certificate_der, :subject, :email])
    |> validate_required([:user_id, :fingerprint, :certificate_der, :subject, :email])
    |> validate_format(:fingerprint, ~r/\A[0-9a-f]{64}\z/)
    |> foreign_key_constraint(:user_id, name: :user_client_certificates_user_id_fkey)
    |> unique_constraint(:fingerprint,
      name: :user_client_certificates_fingerprint_index
    )
    |> check_constraint(:fingerprint,
      name: :user_client_certificates_fingerprint_format
    )
  end
end
```

In `User`, alias the schema and add:

```elixir
has_many(:client_certificates, UserClientCertificate, foreign_key: :user_id)
```

Do not add an update changeset or public delete/reassign operation.

- [ ] **Step 5: Add race-safe context functions**

Add the alias and functions to `GSMLG.Accounts`:

```elixir
alias GSMLG.Accounts.UserClientCertificate

def get_user_client_certificate_by_fingerprint(fingerprint) when is_binary(fingerprint) do
  from(binding in UserClientCertificate,
    join: user in assoc(binding, :user),
    where: binding.fingerprint == ^fingerprint,
    preload: [user: user]
  )
  |> Repo.one()
end

def bind_user_client_certificate(
      %User{id: user_id},
      %{certificate_der: certificate_der, subject: subject, email: email}
    )
    when is_binary(certificate_der) and is_binary(subject) and is_binary(email) do
  fingerprint =
    certificate_der
    |> :crypto.hash(:sha256)
    |> Base.encode16(case: :lower)

  insert_result =
    %UserClientCertificate{}
    |> UserClientCertificate.create_changeset(%{
      user_id: user_id,
      fingerprint: fingerprint,
      certificate_der: certificate_der,
      subject: subject,
      email: email
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:fingerprint])

  case insert_result do
    {:ok, _candidate} -> resolve_client_certificate_owner(fingerprint, user_id)
    {:error, changeset} -> {:error, changeset}
  end
end

defp resolve_client_certificate_owner(fingerprint, requested_user_id) do
  case get_user_client_certificate_by_fingerprint(fingerprint) do
    %UserClientCertificate{user_id: ^requested_user_id} = binding ->
      {:ok, binding}

    %UserClientCertificate{user_id: owner_user_id} ->
      {:error, {:client_certificate_already_bound, owner_user_id}}

    nil ->
      {:error, :client_certificate_binding_failed}
  end
end
```

Do not accept a caller-provided fingerprint or user ID.

- [ ] **Step 6: Run the focused Accounts tests**

Run the Step 2 command.

Expected: all Accounts tests pass.

- [ ] **Step 7: Format and commit the persistence slice**

```bash
mix format \
  apps/gsmlg/lib/gsmlg/accounts.ex \
  apps/gsmlg/lib/gsmlg/accounts/user.ex \
  apps/gsmlg/lib/gsmlg/accounts/user_client_certificate.ex \
  apps/gsmlg/test/support/fixtures/accounts_fixtures.ex \
  apps/gsmlg/test/gsmlg/accounts_test.exs \
  apps/gsmlg/priv/repo/migrations/20260829000000_create_user_client_certificates.exs
git add \
  apps/gsmlg/lib/gsmlg/accounts.ex \
  apps/gsmlg/lib/gsmlg/accounts/user.ex \
  apps/gsmlg/lib/gsmlg/accounts/user_client_certificate.ex \
  apps/gsmlg/test/support/fixtures/accounts_fixtures.ex \
  apps/gsmlg/test/gsmlg/accounts_test.exs \
  apps/gsmlg/priv/repo/migrations/20260829000000_create_user_client_certificates.exs
git commit -m "feat(accounts): persist client certificate bindings"
```

---

### Task 3: Parse Caddy's header-safe certificate assertion

**Files:**

- Create: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/client_certificate.ex`
- Create: `apps/gsmlg_admin_web/test/support/client_certificate_fixtures.ex`
- Create: `apps/gsmlg_admin_web/test/gsmlg/admin_web/client_certificate_test.exs`
- Modify: `apps/gsmlg_admin_web/mix.exs`

- [ ] **Step 1: Add the test certificate helper**

Create the support module. OTP's `pkix_test_data/1` is explicitly a test-data API; only the public leaf DER is exposed to tests.

```elixir
defmodule GSMLG.AdminWeb.ClientCertificateFixtures do
  import Plug.Conn

  def client_certificate(overrides \\ %{}) do
    config = :public_key.pkix_test_data(%{root: [], peer: []})
    certificate_der = Keyword.fetch!(config, :cert)

    base = %{
      certificate_der: certificate_der,
      der_base64: Base.encode64(certificate_der),
      fingerprint:
        certificate_der
        |> :crypto.hash(:sha256)
        |> Base.encode16(case: :lower),
      pem: :public_key.pem_encode([{:Certificate, certificate_der, :not_encrypted}]),
      subject: "CN=Admin Client,O=GSMLG Test",
      email: "certificate-display@example.test"
    }

    Map.merge(base, Map.new(overrides))
  end

  def client_certificate_headers(certificate) do
    [
      {"x-client-cert-subject", certificate.subject},
      {"x-client-cert-certificate-pem", certificate.der_base64},
      {"x-client-cert-email", certificate.email}
    ]
  end

  def put_client_certificate_headers(conn, certificate) do
    Enum.reduce(client_certificate_headers(certificate), conn, fn {name, value}, conn ->
      put_req_header(conn, name, value)
    end)
  end
end
```

- [ ] **Step 2: Write the failing parser tests**

Create `client_certificate_test.exs`:

```elixir
defmodule GSMLG.AdminWeb.ClientCertificateTest do
  use ExUnit.Case, async: true

  alias GSMLG.AdminWeb.ClientCertificate
  import GSMLG.AdminWeb.ClientCertificateFixtures

  test "parses Caddy DER-base64 and reconstructs canonical PEM" do
    fixture = client_certificate()

    assert {:ok, certificate} =
             ClientCertificate.parse_headers(client_certificate_headers(fixture))

    assert certificate.certificate_der == fixture.certificate_der
    assert certificate.fingerprint == fixture.fingerprint
    assert certificate.pem == fixture.pem
    assert certificate.subject == fixture.subject
    assert certificate.email == fixture.email
  end

  test "requires exactly one nonblank value for all three headers" do
    fixture = client_certificate()
    headers = client_certificate_headers(fixture)

    assert {:error, :missing_headers} = ClientCertificate.parse_headers([])
    assert {:error, :incomplete_headers} = ClientCertificate.parse_headers(tl(headers))
    assert {:error, :blank_header} =
             ClientCertificate.parse_headers(
               List.keyreplace(headers, "x-client-cert-email", 0, {
                 "x-client-cert-email",
                 " "
               })
             )

    assert {:error, :duplicate_header} =
             ClientCertificate.parse_headers([
               {"x-client-cert-email", "duplicate@example.test"} | headers
             ])
  end

  test "rejects malformed, empty, oversized, and non-X.509 DER" do
    fixture = client_certificate()

    replace_der = fn encoded ->
      List.keyreplace(
        client_certificate_headers(fixture),
        "x-client-cert-certificate-pem",
        0,
        {"x-client-cert-certificate-pem", encoded}
      )
    end

    assert {:error, :invalid_base64} = ClientCertificate.parse_headers(replace_der.("%%%"))

    assert {:error, :certificate_too_large} =
             ClientCertificate.parse_headers(
               replace_der.(Base.encode64(:binary.copy(<<0>>, 16_385)))
             )

    assert {:error, :invalid_certificate} =
             ClientCertificate.parse_headers(replace_der.(Base.encode64("not an x509 cert")))
  end
end
```

- [ ] **Step 3: Run the parser test and verify the missing-module failure**

```bash
mix test apps/gsmlg_admin_web/test/gsmlg/admin_web/client_certificate_test.exs
```

Expected: compilation fails because `GSMLG.AdminWeb.ClientCertificate` does not exist.

- [ ] **Step 4: Implement the parser**

Create `client_certificate.ex`:

```elixir
defmodule GSMLG.AdminWeb.ClientCertificate do
  @moduledoc false

  @max_der_size 16 * 1024
  @max_encoded_size div((@max_der_size + 2) * 4, 3)
  @headers [
    "x-client-cert-subject",
    "x-client-cert-certificate-pem",
    "x-client-cert-email"
  ]

  defstruct [:certificate_der, :fingerprint, :pem, :subject, :email]

  def parse_conn(%Plug.Conn{req_headers: headers}), do: parse_headers(headers)

  def parse_headers(headers) when is_list(headers) do
    values =
      Map.new(@headers, fn name ->
        matches =
          for {header, value} <- headers,
              String.downcase(header) == name,
              do: value

        {name, matches}
      end)

    with :ok <- validate_presence(values),
         {:ok, subject} <- single_value(values, "x-client-cert-subject"),
         {:ok, encoded} <- single_value(values, "x-client-cert-certificate-pem"),
         {:ok, email} <- single_value(values, "x-client-cert-email"),
         :ok <- validate_nonblank([subject, encoded, email]),
         :ok <- validate_encoded_size(encoded),
         {:ok, certificate_der} <- Base.decode64(encoded),
         :ok <- validate_canonical_base64(encoded, certificate_der),
         :ok <- validate_der_size(certificate_der),
         :ok <- validate_x509(certificate_der) do
      {:ok,
       %__MODULE__{
         certificate_der: certificate_der,
         fingerprint: fingerprint(certificate_der),
         pem: :public_key.pem_encode([{:Certificate, certificate_der, :not_encrypted}]),
         subject: subject,
         email: email
       }}
    else
      :error -> {:error, :invalid_base64}
      {:error, _reason} = error -> error
    end
  end

  defp validate_presence(values) do
    counts = Enum.map(@headers, &length(Map.fetch!(values, &1)))

    cond do
      counts == [0, 0, 0] -> {:error, :missing_headers}
      Enum.any?(counts, &(&1 > 1)) -> {:error, :duplicate_header}
      counts != [1, 1, 1] -> {:error, :incomplete_headers}
      true -> :ok
    end
  end

  defp single_value(values, name), do: {:ok, values |> Map.fetch!(name) |> hd()}

  defp validate_nonblank(values) do
    if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")),
      do: :ok,
      else: {:error, :blank_header}
  end

  defp validate_encoded_size(encoded) when byte_size(encoded) <= @max_encoded_size, do: :ok
  defp validate_encoded_size(_encoded), do: {:error, :certificate_too_large}

  defp validate_canonical_base64(encoded, der) do
    if Base.encode64(der) == encoded, do: :ok, else: {:error, :invalid_base64}
  end

  defp validate_der_size(<<>>), do: {:error, :empty_certificate}
  defp validate_der_size(der) when byte_size(der) <= @max_der_size, do: :ok
  defp validate_der_size(_der), do: {:error, :certificate_too_large}

  defp validate_x509(der) do
    try do
      certificate = :public_key.pkix_decode_cert(der, :otp)

      case :public_key.pkix_encode(:OTPCertificate, certificate, :otp) do
        ^der -> :ok
        _other -> {:error, :invalid_certificate}
      end
    catch
      _, _ -> {:error, :invalid_certificate}
    end
  end

  defp fingerprint(der) do
    der
    |> :crypto.hash(:sha256)
    |> Base.encode16(case: :lower)
  end
end
```

Add `:public_key` to `extra_applications` in `apps/gsmlg_admin_web/mix.exs`.

- [ ] **Step 5: Run the parser tests**

Run the Step 3 command.

Expected: all parser tests pass.

- [ ] **Step 6: Format and commit the parser slice**

```bash
mix format \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/client_certificate.ex \
  apps/gsmlg_admin_web/test/support/client_certificate_fixtures.ex \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/client_certificate_test.exs \
  apps/gsmlg_admin_web/mix.exs
git add \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/client_certificate.ex \
  apps/gsmlg_admin_web/test/support/client_certificate_fixtures.ex \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/client_certificate_test.exs \
  apps/gsmlg_admin_web/mix.exs
git commit -m "feat(admin): parse Caddy client certificates"
```

---

### Task 4: Establish certificate-owned Guardian browser sessions

**Files:**

- Create: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/plugs/client_certificate_auth.ex`
- Create: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/guardian/optional_web_auth_error_handler.ex`
- Create: `apps/gsmlg_admin_web/test/gsmlg/admin_web/plugs/client_certificate_auth_test.exs`
- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/router.ex:4-100`

- [ ] **Step 1: Write failing browser pipeline tests**

Create an integration test module using `GSMLG.AdminWeb.ConnCase` with
`async: false` and these imports:

```elixir
import GSMLG.AccountsFixtures
import GSMLG.AdminWeb.ClientCertificateFixtures
```

In setup, save the endpoint config, set `client_certificate_auth: true`, and
restore it in `on_exit/1`:

```elixir
setup do
  endpoint = GSMLG.AdminWeb.Endpoint
  original = Application.get_env(:gsmlg_admin_web, endpoint, [])
  Application.put_env(:gsmlg_admin_web, endpoint, Keyword.put(original, :client_certificate_auth, true))
  on_exit(fn -> Application.put_env(:gsmlg_admin_web, endpoint, original) end)
  :ok
end
```

Use these helpers:

```elixir
defp bind_certificate(user, fixture) do
  GSMLG.Accounts.bind_user_client_certificate(user, %{
    certificate_der: fixture.certificate_der,
    subject: fixture.subject,
    email: fixture.email
  })
end

defp put_guardian_session(conn, user, method \\ "password") do
  {:ok, token, _claims} =
    GSMLG.AdminWeb.Guardian.encode_and_sign(user, %{}, token_type: "access")

  conn
  |> Plug.Test.init_test_session(%{})
  |> put_session(:guardian_default_token, token)
  |> put_session("admin_auth_method", method)
end
```

Write tests for:

```elixir
test "bound certificate opens a protected browser route", %{conn: conn} do
  user = user_fixture()
  certificate = client_certificate()
  assert {:ok, _binding} = bind_certificate(user, certificate)

  conn =
    conn
    |> put_client_certificate_headers(certificate)
    |> get(~p"/")

  assert html_response(conn, 200)
  assert get_session(conn, "admin_auth_method") == "client_certificate"
  assert get_session(conn, "admin_client_certificate_fingerprint") == certificate.fingerprint
end

test "bound certificate replaces a different password user", %{conn: conn} do
  owner = user_fixture(%{username: "cert_owner", email: "owner@example.test"})
  other = user_fixture(%{username: "password_user", email: "password@example.test"})
  certificate = client_certificate()
  assert {:ok, _binding} = bind_certificate(owner, certificate)

  conn =
    conn
    |> put_guardian_session(other)
    |> put_client_certificate_headers(certificate)
    |> get(~p"/")

  token = get_session(conn, :guardian_default_token)
  assert {:ok, resource, _claims} =
           Guardian.resource_from_token(GSMLG.AdminWeb.Guardian, token)
  assert resource.id == owner.id
end

test "unbound certificate clears a password session and redirects to enrollment", %{conn: conn} do
  user = user_fixture()
  certificate = client_certificate()

  conn =
    conn
    |> put_guardian_session(user)
    |> put_client_certificate_headers(certificate)
    |> get(~p"/")

  assert redirected_to(conn) == ~p"/sign_in"
  assert get_session(conn, :guardian_default_token) == nil
end

test "removing a certificate clears a certificate-created session", %{conn: conn} do
  user = user_fixture()

  conn =
    conn
    |> put_guardian_session(user, "client_certificate")
    |> put_session("admin_client_certificate_fingerprint", String.duplicate("a", 64))
    |> get(~p"/")

  assert redirected_to(conn) == ~p"/sign_in"
  assert get_session(conn, :guardian_default_token) == nil
end

test "missing certificate preserves a password-created session", %{conn: conn} do
  user = user_fixture()
  conn = conn |> put_guardian_session(user) |> get(~p"/")
  assert html_response(conn, 200)
end
```

Also add a disabled test that temporarily sets the toggle to false, sends a bound certificate without a cookie, and expects redirect to `/sign_in`.

- [ ] **Step 2: Run the plug test and verify the missing behavior**

```bash
mix test apps/gsmlg_admin_web/test/gsmlg/admin_web/plugs/client_certificate_auth_test.exs
```

Expected: bound-certificate tests redirect because no certificate plug exists.

- [ ] **Step 3: Implement the browser plug**

Create `ClientCertificateAuth` with this public boundary:

```elixir
defmodule GSMLG.AdminWeb.Plugs.ClientCertificateAuth do
  import Plug.Conn

  alias GSMLG.Accounts
  alias GSMLG.Accounts.User
  alias GSMLG.AdminWeb.ClientCertificate
  alias GSMLG.AdminWeb.Guardian
  alias Elixir.Guardian.Plug.Keys, as: GuardianKeys

  @auth_method_key "admin_auth_method"
  @fingerprint_key "admin_client_certificate_fingerprint"

  def init(opts), do: opts
  def auth_method_key, do: @auth_method_key
  def fingerprint_key, do: @fingerprint_key

  def enabled? do
    :gsmlg_admin_web
    |> Application.get_env(GSMLG.AdminWeb.Endpoint, [])
    |> Keyword.get(:client_certificate_auth, false)
  end

  def call(conn, _opts) do
    if enabled?(), do: authenticate(conn, ClientCertificate.parse_conn(conn)), else: conn
  end

  def certificate_authenticated?(conn),
    do: conn.assigns[:client_certificate_authenticated] == true

  def sign_in_with_certificate(conn, %User{} = user, %ClientCertificate{} = certificate) do
    conn =
      case {Guardian.Plug.current_resource(conn), Guardian.Plug.current_claims(conn)} do
        {%User{id: current_id}, %{"typ" => "access"}} when current_id == user.id -> conn
        _other -> conn |> sign_out_guardian_identity() |> Guardian.Plug.sign_in(user)
      end

    conn
    |> put_session(@auth_method_key, "client_certificate")
    |> put_session(@fingerprint_key, certificate.fingerprint)
    |> assign(:admin_auth_method, "client_certificate")
    |> assign(:client_certificate, certificate)
    |> assign(:client_certificate_authenticated, true)
  end

  def sign_in_with_password(conn, %User{} = user) do
    conn
    |> Guardian.Plug.sign_in(user)
    |> put_session(@auth_method_key, "password")
    |> delete_session(@fingerprint_key)
    |> assign(:admin_auth_method, "password")
  end

  defp authenticate(conn, {:ok, certificate}) do
    case Accounts.get_user_client_certificate_by_fingerprint(certificate.fingerprint) do
      %{user: %User{} = user} -> sign_in_with_certificate(conn, user, certificate)
      nil -> prepare_enrollment(conn, certificate)
    end
  end

  defp authenticate(conn, {:error, reason}) do
    if reason != :missing_headers do
      GSMLG.Telemetry.warn("Invalid admin client certificate assertion",
        metadata: %{reason: reason}
      )
    end

    preserve_password_or_clear_certificate_session(conn)
  end

  defp prepare_enrollment(conn, certificate) do
    conn
    |> sign_out_guardian_identity()
    |> delete_session(@auth_method_key)
    |> delete_session(@fingerprint_key)
    |> assign(:admin_auth_method, nil)
    |> assign(:client_certificate, certificate)
    |> assign(:client_certificate_authenticated, false)
  end

  defp preserve_password_or_clear_certificate_session(conn) do
    if get_session(conn, @auth_method_key) == "client_certificate" do
      conn
      |> sign_out_guardian_identity()
      |> delete_session(@auth_method_key)
      |> delete_session(@fingerprint_key)
      |> assign(:admin_auth_method, nil)
    else
      conn
      |> delete_session(@fingerprint_key)
      |> assign(:admin_auth_method, get_session(conn, @auth_method_key))
    end
  end

  defp sign_out_guardian_identity(conn) do
    conn = Guardian.Plug.sign_out(conn)

    private =
      Map.drop(conn.private, [
        GuardianKeys.token_key(),
        GuardianKeys.claims_key(),
        GuardianKeys.resource_key()
      ])

    %{conn | private: private}
  end
end
```

Keep conflict/failure metadata to bounded categories (the fixed event/category
or reason atom), relevant user IDs, and the derived fingerprint. Successful
binding and automatic certificate login may contain only `user_id` and
fingerprint. Never log raw headers/params, DER, PEM, subject, email, passwords,
or Guardian tokens.

Create `apps/gsmlg_admin_web/lib/gsmlg/admin_web/guardian/optional_web_auth_error_handler.ex`:

```elixir
defmodule GSMLG.AdminWeb.Guardian.OptionalWebAuthErrorHandler do
  @behaviour Elixir.Guardian.Plug.ErrorHandler

  alias GSMLG.AdminWeb.Guardian
  alias GSMLG.AdminWeb.Guardian.WebAuthErrorHandler

  @impl true
  def auth_error(conn, {:unauthenticated, _reason} = error, opts) do
    WebAuthErrorHandler.auth_error(conn, error, opts)
  end

  def auth_error(conn, {_type, _reason}, _opts), do: Guardian.Plug.sign_out(conn)
end
```

- [ ] **Step 4: Add an HTML-only router pipeline**

Add:

```elixir
pipeline :client_certificate_browser_auth do
  plug(GSMLG.AdminWeb.Plugs.ClientCertificateAuth)
end
```

Change only the public HTML auth scope and protected HTML scope to:

```elixir
pipe_through([:browser, :maybe_browser_auth, :client_certificate_browser_auth])
```

and:

```elixir
pipe_through([
  :browser,
  :maybe_browser_auth,
  :client_certificate_browser_auth,
  :ensure_authed_access
])
```

Update `:maybe_browser_auth` to use
`GSMLG.AdminWeb.Guardian.OptionalWebAuthErrorHandler`. An actual unauthenticated
error still delegates to the existing web handler; other optional verification
failures passively sign out. Do not add the certificate plug to `:browser_json`,
`:api`, `:mcp_admin_api`, or bearer pipelines.

The Guardian pipeline configuration is:

```elixir
plug(Guardian.Plug.Pipeline,
  module: GSMLG.AdminWeb.Guardian,
  error_handler: GSMLG.AdminWeb.Guardian.OptionalWebAuthErrorHandler
)
```

- [ ] **Step 5: Run the focused plug tests**

Run the Step 2 command.

Expected: browser session tests cover malformed and revoked-cookie recovery,
same-owner access-token preservation, replacement of other or non-access
tokens, stale-session clearing, and GuardianDB revocation.

- [ ] **Step 6: Format and commit the browser-auth slice**

```bash
mix format \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/plugs/client_certificate_auth.ex \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/guardian/optional_web_auth_error_handler.ex \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/router.ex \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/plugs/client_certificate_auth_test.exs
git add \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/plugs/client_certificate_auth.ex \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/guardian/optional_web_auth_error_handler.ex \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/router.ex \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/plugs/client_certificate_auth_test.exs
git commit -m "feat(admin): authenticate client certificate sessions"
```

---

### Task 5: Enroll certificates through password sign-in

**Files:**

- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/controllers/auth_controller.ex`
- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/controllers/auth_html/sign_in.html.heex`
- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/components/layouts/root.html.heex`
- Modify: `apps/gsmlg_admin_web/assets/css/main.css`
- Modify: `apps/gsmlg_component/lib/gsmlg/component/admin.ex`
- Modify: `apps/gsmlg_component/test/gsmlg/component_test.exs`
- Test: `apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/auth_controller_test.exs`

- [ ] **Step 1: Write failing enrollment and rendering tests**

Expand `AuthControllerTest` with these imports, helpers, and the explicit
endpoint-config save/enable/restore setup shown in Task 4:

```elixir
import GSMLG.AdminWeb.ClientCertificateFixtures

defp bind_certificate(user, fixture) do
  GSMLG.Accounts.bind_user_client_certificate(user, %{
    certificate_der: fixture.certificate_der,
    subject: fixture.subject,
    email: fixture.email
  })
end

defp put_guardian_session(conn, user, method \\ "password") do
  {:ok, token, _claims} =
    GSMLG.AdminWeb.Guardian.encode_and_sign(user, %{}, token_type: "access")

  conn
  |> Plug.Test.init_test_session(%{})
  |> put_session(:guardian_default_token, token)
  |> put_session("admin_auth_method", method)
end
```

Add Floki-backed assertions for:

```elixir
test "renders unbound certificate enrollment without form certificate fields", %{conn: conn} do
  certificate = client_certificate(%{email: "display-only@example.test"})

  conn = conn |> put_client_certificate_headers(certificate) |> get(~p"/sign_in")
  html = html_response(conn, 200)
  {:ok, document} = Floki.parse_document(html)

  assert Floki.find(document, "#client-certificate-enrollment") != []
  assert Floki.text(Floki.find(document, "#client-certificate-subject")) =~ certificate.subject
  assert Floki.text(Floki.find(document, "#client-certificate-email")) =~ certificate.email
  assert [{"textarea", attrs, [pem]}] = Floki.find(document, "#client-certificate-pem")
  assert {"readonly", "readonly"} in attrs
  refute Enum.any?(attrs, fn {name, _value} -> name == "name" end)
  assert pem =~ "-----BEGIN CERTIFICATE-----"
  refute html =~ certificate.der_base64
end

test "successful password login binds certificate despite unrelated display email", %{conn: conn} do
  user = user_fixture(%{email: "account@example.test"})
  certificate = client_certificate(%{email: "certificate@example.test"})

  conn =
    conn
    |> put_client_certificate_headers(certificate)
    |> post(~p"/sign_in", %{
      "auth" => %{"username" => user.username, "password" => "some password"}
    })

  assert redirected_to(conn) == ~p"/users/#{user.id}"
  assert GSMLG.Accounts.get_user_client_certificate_by_fingerprint(certificate.fingerprint).user_id ==
           user.id
  assert get_session(conn, "admin_auth_method") == "client_certificate"
end

test "failed credentials preserve certificate display and create no binding", %{conn: conn} do
  user = user_fixture()
  certificate = client_certificate()

  conn =
    conn
    |> put_client_certificate_headers(certificate)
    |> post(~p"/sign_in", %{
      "auth" => %{"username" => user.username, "password" => "incorrect password"}
    })

  html = html_response(conn, 200)
  assert html =~ certificate.subject
  assert html =~ "-----BEGIN CERTIFICATE-----"
  assert GSMLG.Accounts.get_user_client_certificate_by_fingerprint(certificate.fingerprint) == nil
  assert get_session(conn, :guardian_default_token) == nil
end

test "ordinary password login creates no certificate binding", %{conn: conn} do
  user = user_fixture()

  conn =
    post(conn, ~p"/sign_in", %{
      "auth" => %{"username" => user.username, "password" => "some password"}
    })

  assert redirected_to(conn) == ~p"/users/#{user.id}"
  assert get_session(conn, "admin_auth_method") == "password"
  assert GSMLG.Repo.aggregate(GSMLG.Accounts.UserClientCertificate, :count) == 0
end
```

Add these authoritative-owner and sign-out tests using those local helpers:

```elixir
test "already-bound certificate ignores another user's submitted credentials", %{conn: conn} do
  owner = user_fixture(%{username: "bound_owner", email: "bound-owner@example.test"})
  other = user_fixture(%{username: "submitted_user", email: "submitted@example.test"})
  certificate = client_certificate()
  assert {:ok, _binding} = bind_certificate(owner, certificate)

  conn =
    conn
    |> put_client_certificate_headers(certificate)
    |> post(~p"/sign_in", %{
      "auth" => %{"username" => other.username, "password" => "some password"}
    })

  assert redirected_to(conn) == ~p"/users/#{owner.id}"
end

test "certificate-authenticated sign-out keeps its owner signed in", %{conn: conn} do
  owner = user_fixture()
  certificate = client_certificate()
  assert {:ok, _binding} = bind_certificate(owner, certificate)

  conn =
    conn
    |> put_client_certificate_headers(certificate)
    |> delete(~p"/sign_out")

  assert redirected_to(conn) == ~p"/users/#{owner.id}"
  assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Remove the client certificate"
  assert is_binary(get_session(conn, :guardian_default_token))
end

test "password-authenticated sign-out retains existing behavior", %{conn: conn} do
  user = user_fixture()

  conn =
    conn
    |> put_guardian_session(user, "password")
    |> delete(~p"/sign_out")

  assert redirected_to(conn) == ~p"/sign_in"
  assert get_session(conn, :guardian_default_token) == nil
end

test "certificate session marks the root document for sign-out hiding", %{conn: conn} do
  owner = user_fixture()
  certificate = client_certificate()
  assert {:ok, _binding} = bind_certificate(owner, certificate)

  html =
    conn
    |> put_client_certificate_headers(certificate)
    |> get(~p"/")
    |> html_response(200)

  assert html =~ ~s(data-admin-auth-method="client_certificate")
  assert html =~ ~s(id="admin-sign-out")
end
```

The context test from Task 2 is the deterministic cross-user uniqueness-conflict
test. The HTML controller still handles that race result generically without
attempting reassignment.

In `GSMLG.ComponentTest`, import `Phoenix.LiveViewTest`, render `GSMLG.Component.Admin.local_app_bar/1`, and assert the sign-out link has `id="admin-sign-out"`.

- [ ] **Step 2: Run the focused tests and confirm the missing enrollment/UI failures**

```bash
mix test \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/auth_controller_test.exs \
  apps/gsmlg_component/test/gsmlg/component_test.exs
```

Expected: certificate disclosure, binding, session marker, sign-out behavior, and stable element ID assertions fail.

- [ ] **Step 3: Refactor the HTML controller flow around explicit session completion**

Add aliases for `GSMLG.Accounts` and `GSMLG.AdminWeb.Plugs.ClientCertificateAuth`. Keep JSON clauses unchanged. Implement these private helpers and use them from `index/2`, the HTML `sign_in/2` clause, and `sign_out/2`:

```elixir
defp render_sign_in(conn, changeset, opts \\ []) do
  conn
  |> put_status(Keyword.get(opts, :status, :ok))
  |> render(:sign_in,
    changeset: changeset,
    client_certificate: conn.assigns[:client_certificate],
    page_title: "SIGN IN"
  )
end

defp complete_html_sign_in(conn, user) do
  case conn.assigns[:client_certificate] do
    nil ->
      conn
      |> put_flash(:info, "Sign in successfully.")
      |> ClientCertificateAuth.sign_in_with_password(user)
      |> redirect(to: ~p"/users/#{user.id}")

    certificate ->
      case Accounts.bind_user_client_certificate(user, %{
             certificate_der: certificate.certificate_der,
             subject: certificate.subject,
             email: certificate.email
           }) do
        {:ok, _binding} ->
          GSMLG.Telemetry.info("Admin client certificate bound",
            metadata: %{
              user_id: user.id,
              fingerprint: certificate.fingerprint
            }
          )

          conn
          |> put_flash(:info, "Certificate bound and signed in successfully.")
          |> ClientCertificateAuth.sign_in_with_certificate(user, certificate)
          |> redirect(to: ~p"/users/#{user.id}")

        {:error, {:client_certificate_already_bound, owner_user_id}} ->
          GSMLG.Telemetry.warn("Admin client certificate binding conflict",
            metadata: %{
              attempted_user_id: user.id,
              owner_user_id: owner_user_id,
              fingerprint: certificate.fingerprint
            }
          )

          conn
          |> put_flash(:error, "This certificate is already bound to another user.")
          |> render_sign_in(Auth.sign_in_changeset(%Auth{}, %{}), status: :conflict)

        {:error, reason} ->
          GSMLG.Telemetry.warn("Admin client certificate binding failed",
            metadata: %{
              user_id: user.id,
              fingerprint: certificate.fingerprint,
              reason: certificate_binding_failure_category(reason)
            }
          )

          conn
          |> put_flash(:error, "The certificate could not be bound. Please try again.")
          |> render_sign_in(Auth.sign_in_changeset(%Auth{}, %{}),
            status: :unprocessable_entity
          )
      end
  end
end
```

At the start of the HTML `%{"auth" => params}` clause, make a bound certificate authoritative:

```elixir
if ClientCertificateAuth.certificate_authenticated?(conn) do
  user = Guardian.Plug.current_resource(conn)
  redirect(conn, to: ~p"/users/#{user.id}")
else
  case Auth.sign_in(params) do
    {:ok, %User{} = user} -> complete_html_sign_in(conn, user)
    {:error, %Ecto.Changeset{} = changeset} ->
      conn |> put_flash(:error, "invalid") |> render_sign_in(changeset)
  end
end
```

For `index/2`, route all unauthenticated rendering through `render_sign_in/2`.

For HTML certificate sign-out, do not call Guardian sign-out:

```elixir
if Phoenix.Controller.get_format(conn) == "html" and
     ClientCertificateAuth.certificate_authenticated?(conn) do
  user = Guardian.Plug.current_resource(conn)

  conn
  |> put_flash(:info, "Remove the client certificate to end certificate access.")
  |> redirect(to: ~p"/users/#{user.id}")
else
  conn
  |> Guardian.Plug.sign_out()
  |> delete_session(ClientCertificateAuth.auth_method_key())
  |> delete_session(ClientCertificateAuth.fingerprint_key())
  |> redirect(to: ~p"/sign_in")
end
```

- [ ] **Step 4: Render the accessible certificate enrollment panel**

Insert this between the sign-in header and form:

```heex
<section
  :if={@client_certificate}
  id="client-certificate-enrollment"
  aria-labelledby="client-certificate-enrollment-title"
  class="si-certificate"
>
  <h3 id="client-certificate-enrollment-title" class="si-certificate-title">
    Client certificate detected
  </h3>
  <p id="client-certificate-notice" class="si-certificate-notice">
    Successful password login permanently binds this certificate to your user.
  </p>
  <dl class="si-certificate-details">
    <div>
      <dt>SUBJECT</dt>
      <dd id="client-certificate-subject">{@client_certificate.subject}</dd>
    </div>
    <div>
      <dt>EMAIL</dt>
      <dd id="client-certificate-email">{@client_certificate.email}</dd>
    </div>
  </dl>
  <label for="client-certificate-pem" class="si-label">CERTIFICATE PEM</label>
  <textarea
    id="client-certificate-pem"
    class="si-certificate-pem"
    readonly
    spellcheck="false"
    wrap="off"
    rows="8"
  >{@client_certificate.pem}</textarea>
</section>
```

Set username `autofocus={!@client_certificate}` and `aria-describedby={@client_certificate && "client-certificate-notice"}`. Do not add `name` or hidden certificate fields.

- [ ] **Step 5: Style only the new panel and sign-out state**

Add focused styles beside the existing `.si-*` rules:

```css
.si-certificate {
  display: flex;
  flex-direction: column;
  gap: 0.625rem;
  padding: 0.875rem;
  border: 1px solid var(--color-outline-variant);
  background: var(--color-surface-container);
  color: var(--color-on-surface);
}

.si-certificate-title,
.si-certificate-details dt {
  font-family: var(--font-mono, ui-monospace, monospace);
  color: var(--color-primary);
}

.si-certificate-notice,
.si-certificate-details dd {
  overflow-wrap: anywhere;
  font-family: var(--font-mono, ui-monospace, monospace);
  font-size: 0.6875rem;
}

.si-certificate-pem {
  width: 100%;
  max-height: 12rem;
  overflow: auto;
  resize: vertical;
  font-family: var(--font-mono, ui-monospace, monospace);
  font-size: 0.625rem;
  background: var(--color-surface);
  color: var(--color-on-surface);
  border: 1px solid var(--color-outline-variant);
}

.si-certificate-pem:focus-visible {
  outline: 2px solid var(--color-primary);
  outline-offset: 2px;
}

html[data-admin-auth-method="client_certificate"] #admin-sign-out {
  display: none;
}
```

Add `id="admin-sign-out"` to the shared app-bar sign-out link. Add this to the root `<html>` element:

```heex
data-admin-auth-method={assigns[:admin_auth_method]}
```

The plug establishes this assign on the initial HTTP render. `display: none` removes the link from layout and the accessibility tree; the controller remains the direct-route backstop.

- [ ] **Step 6: Run controller and component tests**

Run the Step 2 command.

Expected: all enrollment, fallback, sign-out, and component tests pass.

- [ ] **Step 7: Format and commit the enrollment UI slice**

```bash
mix format \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/controllers/auth_controller.ex \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/controllers/auth_html/sign_in.html.heex \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/components/layouts/root.html.heex \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/auth_controller_test.exs \
  apps/gsmlg_component/lib/gsmlg/component/admin.ex \
  apps/gsmlg_component/test/gsmlg/component_test.exs
git add \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/controllers/auth_controller.ex \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/controllers/auth_html/sign_in.html.heex \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/components/layouts/root.html.heex \
  apps/gsmlg_admin_web/assets/css/main.css \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/auth_controller_test.exs \
  apps/gsmlg_component/lib/gsmlg/component/admin.ex \
  apps/gsmlg_component/test/gsmlg/component_test.exs
git commit -m "feat(admin): enroll client certificates at sign-in"
```

---

### Task 6: Reject stale certificate-created LiveView reconnects

**Files:**

- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/hooks/assign_current_user.ex`
- Modify: `apps/gsmlg_admin_web/lib/gsmlg/admin_web.ex:32-65`
- Create: `apps/gsmlg_admin_web/test/gsmlg/admin_web/live/hooks/assign_current_user_test.exs`
- Create: `apps/gsmlg_admin_web/test/gsmlg/admin_web/client_certificate_isolation_test.exs`

- [ ] **Step 1: Write failing LiveView reconnect tests**

In the new test module, use `GSMLG.AdminWeb.ConnCase`, import
`Phoenix.LiveViewTest`, `GSMLG.AccountsFixtures`, and
`GSMLG.AdminWeb.ClientCertificateFixtures`, and repeat these local helpers:

```elixir
defp bind_certificate(user, fixture) do
  GSMLG.Accounts.bind_user_client_certificate(user, %{
    certificate_der: fixture.certificate_der,
    subject: fixture.subject,
    email: fixture.email
  })
end

defp put_guardian_session(conn, user, method) do
  {:ok, token, _claims} =
    GSMLG.AdminWeb.Guardian.encode_and_sign(user, %{}, token_type: "access")

  conn
  |> Plug.Test.init_test_session(%{})
  |> put_session(:guardian_default_token, token)
  |> put_session("admin_auth_method", method)
end
```

Use the Task 4 endpoint save/enable/restore setup. Exercise the existing
lightweight authenticated `/gao_notes` LiveView through the real HTTP plug, then
override only the simulated websocket connect info:

```elixir
test "matching certificate permits the LiveView connection", %{conn: conn} do
  user = user_fixture()
  certificate = client_certificate()
  assert {:ok, _binding} = bind_certificate(user, certificate)

  conn = put_client_certificate_headers(conn, certificate)
  assert {:ok, _view, _html} = live(conn, ~p"/gao_notes")
end

test "certificate session cannot reconnect without certificate headers", %{conn: conn} do
  user = user_fixture()
  certificate = client_certificate()
  assert {:ok, _binding} = bind_certificate(user, certificate)

  conn =
    conn
    |> put_client_certificate_headers(certificate)
    |> Plug.Conn.put_private(:live_view_connect_info, %{x_headers: []})

  assert {:error, {:redirect, %{to: "/sign_in"}}} = live(conn, ~p"/gao_notes")
end
```

Add the malformed/unbound/different reconnect cases with fresh connections so a
LiveView test process is not reused:

```elixir
test "certificate session rejects unusable or different reconnect assertions", %{conn: conn} do
  owner = user_fixture(%{username: "live_owner", email: "live-owner@example.test"})
  other = user_fixture(%{username: "live_other", email: "live-other@example.test"})
  owner_certificate = client_certificate()
  other_certificate = client_certificate()
  unbound_certificate = client_certificate()

  assert {:ok, _binding} = bind_certificate(owner, owner_certificate)
  assert {:ok, _binding} = bind_certificate(other, other_certificate)

  malformed_headers =
    List.keyreplace(
      client_certificate_headers(owner_certificate),
      "x-client-cert-certificate-pem",
      0,
      {"x-client-cert-certificate-pem", "%%%"}
    )

  for connected_headers <- [
        malformed_headers,
        client_certificate_headers(unbound_certificate),
        client_certificate_headers(other_certificate)
      ] do
    reconnect_conn =
      Phoenix.ConnTest.build_conn()
      |> put_client_certificate_headers(owner_certificate)
      |> Plug.Conn.put_private(:live_view_connect_info, %{x_headers: connected_headers})

    assert {:error, {:redirect, %{to: "/sign_in"}}} =
             live(reconnect_conn, ~p"/gao_notes")
  end
end

test "password session reconnects without certificate headers", %{conn: conn} do
  user = user_fixture()
  conn = put_guardian_session(conn, user, "password")
  assert {:ok, _view, _html} = live(conn, ~p"/gao_notes")
end
```

- [ ] **Step 2: Run the hook test and verify stale reconnect currently succeeds**

```bash
mix test apps/gsmlg_admin_web/test/gsmlg/admin_web/live/hooks/assign_current_user_test.exs
```

Expected: missing/malformed/different certificate reconnect assertions fail because the hook only decodes Guardian.

- [ ] **Step 3: Extend the hook with certificate-session verification**

Keep Guardian token loading as the first authority, then validate the marked certificate:

```elixir
def on_mount(:default, _params, session, socket) do
  current_user = load_user_from_session(session)
  auth_method = Map.get(session, "admin_auth_method")

  case validate_certificate_session(socket, session, current_user, auth_method) do
    :ok ->
      {:cont,
       socket
       |> assign(:current_user, current_user)
       |> assign(:admin_auth_method, auth_method)}

    :error ->
      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(:error, "Client certificate authentication expired.")
       |> Phoenix.LiveView.redirect(to: "/sign_in")}
  end
end

defp validate_certificate_session(_socket, _session, _user, method)
     when method != "client_certificate",
     do: :ok

defp validate_certificate_session(socket, session, current_user, "client_certificate") do
  if GSMLG.AdminWeb.Plugs.ClientCertificateAuth.enabled?() do
    headers = Phoenix.LiveView.get_connect_info(socket, :x_headers) || []
    expected_fingerprint = Map.get(session, "admin_client_certificate_fingerprint")

    with %GSMLG.Accounts.User{id: user_id} <- current_user,
         {:ok, certificate} <- GSMLG.AdminWeb.ClientCertificate.parse_headers(headers),
         true <- certificate.fingerprint == expected_fingerprint,
         %{user: %GSMLG.Accounts.User{id: ^user_id}} <-
           GSMLG.Accounts.get_user_client_certificate_by_fingerprint(
             certificate.fingerprint
           ) do
      :ok
    else
      _ -> :error
    end
  else
    :ok
  end
end
```

Keep the existing `load_user_from_session/1` semantics for password and legacy
sessions: it reads `guardian_default_token` and calls
`Guardian.resource_from_token(GSMLG.AdminWeb.Guardian, token, %{}, [])`,
returning `nil` for absent, invalid, or revoked tokens.

- [ ] **Step 4: Install the hook and suppress session-bearing lifecycle logs**

In `GSMLG.AdminWeb`, retain the existing hook under `user_live_view` and add it
to both `live_view` and `aws_live_view`. All three macros must use
`use Phoenix.LiveView, log: false`:

```elixir
on_mount GSMLG.AdminWeb.Live.Hooks.AssignCurrentUser
```

Every current application LiveView uses one of these three macros. This stops
`Phoenix.LiveView.Logger` from printing session tokens or certificate
fingerprints; the `GSMLG.Telemetry.Handler` lifecycle events remain active and
sanitized. Do not restructure router route ordering. LiveDashboard keeps its
existing initial HTTP Guardian protection and externally enforced mTLS; its
library-owned session payload is not changed by this feature.

- [ ] **Step 5: Add the consolidated browser-only isolation test**

Create `client_certificate_isolation_test.exs` with the Task 4 endpoint
save/enable/restore setup, one bound certificate, and a shared request-header
fixture. Cover all non-browser transports in this one module: API sign-out,
AdminBearer Scout, browser-JSON proxy sources, MCP, `UserSocket`, and
CommanderSocket signature authentication. Each assertion must prove that
certificate headers alone do not authenticate the transport (or bypass its
existing signature/authentication check). The malformed/revoked-cookie
recovery cases remain in `client_certificate_auth_test.exs`, including
GuardianDB revocation assertions. The LiveView test also retains the real
connected GaoNote mount assertion that all session-bearing lifecycle logging is
suppressed by `log: false` while telemetry remains active.

- [ ] **Step 6: Run the hook and isolation tests**

```bash
mix test \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/live/hooks/assign_current_user_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/client_certificate_isolation_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/plugs/client_certificate_auth_test.exs
```

Expected: all tests pass and no non-browser pipeline accepts certificate headers as authentication.

- [ ] **Step 7: Format and commit the LiveView/isolation slice**

```bash
mix format \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/hooks/assign_current_user.ex \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web.ex \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/live/hooks/assign_current_user_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/client_certificate_isolation_test.exs
git add \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/hooks/assign_current_user.ex \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web.ex \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/live/hooks/assign_current_user_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/client_certificate_isolation_test.exs
git commit -m "feat(admin): verify certificate LiveView reconnects"
```

---

## Review-driven hardening and final implementation notes

The reviewed implementation includes these final boundaries:

- A valid bound certificate is authoritative over an invalid, stale, revoked,
  or different-user Guardian cookie. Replacing that identity signs out the old
  Guardian identity through the configured GuardianDB `on_revoke` hook before
  establishing the certificate owner's access; an invalid cookie never wins.
- Certificate assertions require strict canonical Base64 and exact DER
  round-trip X.509 encoding. Empty, trailing-data, malformed, duplicate,
  oversized, and non-certificate values are rejected as unusable.
- The certificate plug is attached only to browser HTML scopes. Bearer HTTP,
  JSON/API, MCP, Commander, and socket transports remain isolated; headers
  alone never authenticate those paths.
- The new enrollment panel has verified contrast in both sunshine and
  moonlight themes. Pre-existing authentication contrast and meta-description
  issues remain outside this feature.
- Telemetry privacy is enforced before Metrics, Reporter, or backends: success
  events use only user ID plus fingerprint; conflicts/failures use bounded
  categories, relevant IDs, and fingerprint. DER/PEM/subject/email/password/
  token/raw headers/params are never logged. Known Phoenix and GSMLG Repo/Ecto
  events use whitelists, and custom metadata uses normalized sensitive-key
  redaction plus bounded recursive traversal. All three admin LiveView macros
  set `log: false`, while telemetry lifecycle events remain active.
- Final focused coverage includes parser canonicality, browser precedence and
  revocation behavior, LiveView reconnects, transport isolation, panel/session
  behavior, and `GSMLG.Telemetry.Handler` whitelist/redaction/traversal tests.

### Verification status

The focused feature checks are the relevant completion evidence. Strict
umbrella compilation with `--warnings-as-errors` remains blocked by the
pre-existing GaoNote attachments warning; four unrelated MCP mutation failures
are excluded and are not fixed by this plan. Browser verification confirms the
new certificate panel contrast fix; pre-existing authentication contrast and
meta-description findings remain open and out of scope. Do not describe those
pre-existing failures as fixed.

---

### Task 7: Run scoped verification and browser acceptance

**Files:**

- Verify all files listed above.
- Do not modify Caddy or deployment configuration.

- [ ] **Step 1: Run the complete focused test set**

```bash
mix test \
  apps/gsmlg_config/test/gsmlg/config/schema_test.exs \
  apps/gsmlg_config/test/gsmlg/config/setup_test.exs \
  apps/gsmlg/test/gsmlg/accounts_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/client_certificate_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/client_certificate_isolation_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/plugs/client_certificate_auth_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/auth_controller_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/live/hooks/assign_current_user_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/proxy_rules_source_controller_test.exs \
  apps/gsmlg_component/test/gsmlg/component_test.exs \
  apps/gsmlg_telemetry/test/
```

Expected: the in-scope focused tests pass. Four unrelated MCP mutation failures
remain excluded; if an out-of-scope test fails, report it and stop rather than
repairing it.

- [ ] **Step 2: Run scoped formatting, compilation, and diff checks**

```bash
mix format --check-formatted \
  apps/gsmlg_config/lib/gsmlg/config/schema.ex \
  apps/gsmlg_config/lib/gsmlg/config/setup.ex \
  apps/gsmlg_config/test/gsmlg/config/schema_test.exs \
  apps/gsmlg_config/test/gsmlg/config/setup_test.exs \
  apps/gsmlg/lib/gsmlg/accounts.ex \
  apps/gsmlg/lib/gsmlg/accounts/user.ex \
  apps/gsmlg/lib/gsmlg/accounts/user_client_certificate.ex \
  apps/gsmlg/test/support/fixtures/accounts_fixtures.ex \
  apps/gsmlg/test/gsmlg/accounts_test.exs \
  apps/gsmlg/priv/repo/migrations/20260829000000_create_user_client_certificates.exs \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/client_certificate.ex \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/plugs/client_certificate_auth.ex \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/guardian/optional_web_auth_error_handler.ex \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/router.ex \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/controllers/auth_controller.ex \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/controllers/auth_html/sign_in.html.heex \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/live/hooks/assign_current_user.ex \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web.ex \
  apps/gsmlg_admin_web/lib/gsmlg/admin_web/components/layouts/root.html.heex \
  apps/gsmlg_admin_web/test/support/client_certificate_fixtures.ex \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/client_certificate_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/client_certificate_isolation_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/plugs/client_certificate_auth_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/auth_controller_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/live/hooks/assign_current_user_test.exs \
  apps/gsmlg_component/lib/gsmlg/component/admin.ex \
  apps/gsmlg_component/test/gsmlg/component_test.exs \
  apps/gsmlg_telemetry/lib/gsmlg/telemetry/handler.ex \
  apps/gsmlg_telemetry/test/gsmlg/telemetry/handler_test.exs \
  config/config.exs
mix compile --warnings-as-errors
git diff --check
```

Expected: formatting and whitespace checks pass. Strict umbrella compilation
remains blocked by the pre-existing GaoNote attachments warning; report it
without scope expansion and do not repair unrelated warnings.

- [ ] **Step 3: Verify the rendered enrollment and session behavior in Chromium**

Start the development server in an interactive IEx session. In that session, enable the runtime toggle and create one disposable local user:

```elixir
endpoint_config = Application.get_env(:gsmlg_admin_web, GSMLG.AdminWeb.Endpoint, [])
Application.put_env(
  :gsmlg_admin_web,
  GSMLG.AdminWeb.Endpoint,
  Keyword.put(endpoint_config, :client_certificate_auth, true)
)

{:ok, browser_user} =
  GSMLG.Accounts.create_user(%{
    username: "mtls_browser_check",
    email: "mtls-browser-check@example.test",
    password: "mtls-browser-password"
  })

certificate_config = :public_key.pkix_test_data(%{root: [], peer: []})
browser_der = Keyword.fetch!(certificate_config, :cert)
browser_der_base64 = Base.encode64(browser_der)
IO.puts(browser_der_base64)
```

Use Chrome DevTools network header overrides for:

```text
X-Client-Cert-Subject: CN=Browser Acceptance,O=GSMLG Test
X-Client-Cert-Certificate-PEM: copy the single Base64 line printed by IEx
X-Client-Cert-Email: browser-certificate@example.test
```

Verify at `http://localhost:4111/sign_in`:

1. The certificate section has heading, permanence notice, subject, email, and canonical PEM.
2. The PEM control is read-only, selectable, horizontally/vertically scrollable, and never submitted with the form.
3. Keyboard order reaches PEM, username, password, Authenticate, and Create Account with visible focus.
4. The panel remains usable at 375 px width in sunshine and moonlight themes.
5. Login with `mtls_browser_check` / `mtls-browser-password` succeeds despite the different certificate email.
6. A later navigation with the same headers automatically stays logged in.
7. The sign-out control is absent from the accessibility tree, and direct `DELETE /sign_out` reports that removing the certificate ends access.
8. Removing the header override returns the browser to password login on the next navigation.

Delete only the disposable user after verification:

```elixir
GSMLG.Accounts.delete_user(browser_user)
```

The binding is removed by the tested foreign-key cascade.

- [ ] **Step 4: Inspect final scope and stop**

```bash
git status --short --branch
base=$(git merge-base origin/main HEAD)
git diff --stat "$base"..HEAD
git diff --check "$base"..HEAD
git log --oneline "$base"..HEAD
```

Expected: the approved config, Accounts, admin browser auth/UI, shared sign-out
hook, telemetry privacy files, tests, design, and plan files are the complete
feature range. Do not push, release, or deploy unless separately requested.
