# GaoNote Agent Note API Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** GaoNote 提供固定参考 commit 的 Note REST 24 操作和 `/mcp` 12 工具契约，包含数据、错误、并发、附件与搜索行为，并明确部署安全例外。

**Architecture:** 在现有 GaoNote context / PostgreSQL / GSMLG.Storage 之上增加兼容 adapter 和独立 REST/MCP DTO。revision、selector、原子 mutation 放在共享领域层；保留旧 `/api/gao_notes` 和 `/mcp/gao_note` 与 LiveView，所有写入口须遵守 revision 规则。MCP 2026 transport 依赖上游发布，搜索通过现有 external indexing 边界完成，Org/System 不自动纳入。

**Tech Stack:** Elixir 1.18 / OTP 28、Phoenix/Plug、Ecto/PostgreSQL、Oban、GSMLG.Storage、Backplane MCP Protocol。

---

## 当前状态和范围

此计划已进入实施：隔离 worktree 中已有共享领域、Note REST24、canonical MCP12 与 external service adapters。参考 `gsmlg-opt/agent-note@1a16690d3f0bcdb08e00752e46d76f234313416b`；GaoNote 基线 `9d7e129c7b65fd5f3f51057e6feab9b3df6c5810`。源码与部分 scoped contract evidence 不等于完整 parity；最终集成测试为343项、340通过、3项因Backplane#58失败，详见[实施报告](../../reviews/2026-10-08-gaonote-agent-note-api-implementation.md)，现代协议、真实搜索/index、真实 renderer 与 render/decoder 差异仍待验收。

- [x] 固定/验证两项目 SHA，完成 REST/MCP 源码审查。
- [x] 保存 68 REST 操作清单和 12 MCP 工具 source-derived inventory。
- [x] 运行 pure controller/依赖 probes，确认 labels500、无revision与现代协议缺口。
- [x] 向上游提交 Feature blocker [gsmlg-opt/backplane#56](https://github.com/gsmlg-opt/backplane/issues/56)，两个 callsite 添加上游追踪注释。
- [x] 尝试 scoped baseline，记录现有语法/编译错误和 DB 权限限制；不宣称 green。
- [ ] 任务1后重新建立可运行 baseline。
- [ ] 任务2–8逐阶段实现并验证，不将准备完成视为 API 已实现。

默认范围：Note REST24 + Note MCP12；System REST4 / Org REST40 + MCP40 作为扩展单列。用户尚未明确要求 Org / System，不能自动扩大。详细对照：[审查报告](../../reviews/2026-10-08-gaonote-agent-note-api-parity.md)。

MCP source inventory 不能替代运行时 JSON Schema：输入是否拒绝未知字段、nullable、defaults、oneOf、outputSchema、annotations 和协议元数据需依照固定版本 discovery / 源码生成机制验证。REST labels 是 `[key,value]` 二元数组；MCP 输出 labels 是 `key/value/description/value_type` 对象，不能复用一个 wire DTO。

## Execution 状态（2026-10-08）

以下仅记录已看到的源码实施与测试覆盖；仍未满足的复合验收项保持未勾选。原始审查和 baseline logs 保留，不把历史失败或单独 green 当最终集成结果。

| 任务 | 当前实施 | 未关闭的验收 |
|---|---|---|
| 1 baseline | syntax/import、Bandit teardown、session helper 等 fixture 修复已实施 | 最终完整 scoped baseline 计数待 parent |
| 2 contract/data | REST24/MCP12 源码清单匹配；public 4110 `/mcp`；note-scoped api_id 与 case-sensitive keys | modern discovery、生产存量/rollback、Origin qualification |
| 3 revision | migration、shared legacy/compat writers、no-op 与独立 DB writer tests 已加入 | 最终 scoped evidence 与生产存量验证 |
| 4 labels | selectors/catalog/atomic bulk/batch、typed validation 与 legacy ambiguity guard 已加入 | 最终 scoped evidence；PCRE 并非完整 Rust regex parity |
| 5 patch/attachments | strict patch、FNV lines、aggregate/standalone 编码区别与附件隔离已加入 | 最终 rollback/storage/legacy regression evidence |
| 6 REST/OpenAPI | 24 operation adapters、独立 DTO 与 operation-specific errors 已加入 | 全请求/header/error matrix 与 reference 对照 |
| 7 MCP | canonical12 tools、schemas、public auth、legacy Backplane HTTP tests 已加入 | **BLOCKED_UPSTREAM #56**：2026 wire/session/header/metadata；**#58**：未知字段触发 Backplane/Peri 崩溃，invalid-input cases 保留失败 |
| 8 services | external adapters、Oban index delivery、raw/render/dashboard、PDF admission/deadline/header checks 已加入 | 真实 RRF/index/tombstones/status、limit filling、Gotenberg、完整 decoder、Mermaid/highlight/render 差异 |

未运行部署、发布或集成到主分支。服务 stub 与 header parser evidence 不提升为 `runtime-qualified`。

Catalog 并发仍有 lock-order tradeoff：note-first/catalog writer 冲突时失败事务完整 rollback；catalog writer 返回 tagged failure，但 Compat note/attachment transaction 仍可能抛 Postgrex 异常并由 Phoenix 返回500，需要客户端重试。DB 安全的 race tests 不等于所有 transport 错误体已对齐。迁移 down 也不保证任意数据可回退：新 case variants 会阻止 lower unique index 重建，string audit entity ids 可能无法 cast UUID；需先决定数据处理策略。

## 执行边界、依赖关系与交付

实施时使用 `<project-root>/.trees/gaonote-api-parity`，分支 `codex/gaonote-api-parity`；保留本轮 review 产物及其他用户工作，不自动 commit/push/merge/release/deploy。

```text
1 baseline + 2 contract / migration decisions
                   ↓
            3 shared revision
            ↙        ↓        ↘
4 selectors/batches 5 patch/attachments 6 REST adapters
            ↘        ↓        ↙
         7 MCP tools (transport blocked by upstream #56)
                   ↓
           8 search/raw/export
```

独立 parser、DTO 和 regression fixture 任务可并行。多个 worker 不同时修改 gao_note.ex、router、mix.lock 或同一 migration；共享文件由一个 integration worker负责。每个阶段应形成小且可 review 的提交，但发布操作需有对应用户请求。

必须区分三种状态：`source-reviewed`、`contract-tested`、`runtime-qualified`。只有对应验证完成才能提升状态；mock embedding/renderer 不代表生产能力。遇到 scope 外失败列出并停止，不修无关 app。

## 任务1：恢复 scoped 测试基线

**Files:**
- Modify: `apps/gsmlg_gao_note/test/gsmlg/gao_note/attachment_input_test.exs`
- Modify: `apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/gao_note_attachment_content_controller_test.exs`
- Read: `config/test.exs`, `apps/gsmlg_config/lib/gsmlg/config/setup.ex`
- Evidence: `docs/reviews/fixtures/gaonote-agent-note-20261008/baseline-{full,focused}.log`

- [ ] 在 worktree 中先重跑这两个文件，确认当前 SyntaxError/get2 import ambiguity，没有改动即 green 的误报。
- [x] 将 mixed-key map 的 keyword 项放最后，保留原测试含义：

```elixir
AttachmentInput.cast(%{
  "id" => " attachment-id ",
  "mime" => " text/plain ",
  path: " docs\\./report..txt "
})
```

- [x] 在 Admin 附件测试的 nested S3Stub 中显式排除继承的 ConnTest get/2：

```elixir
defmodule S3Stub do
  import Phoenix.ConnTest, except: [get: 2]
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  # 保留现有 get route 和 handler body。
end
```

该 snippet 是 import 修复位置说明；不得替换/删除原 S3Stub handler。若 lexical import 仍冲突，先以该文件 compile 证据调整 namespace，不能改运行断言来隐藏错误。

- [ ] 验证测试 DB 角色对相关表/sequence 的权限，优先选择已正确配置的测试 DB/角色；本轮不为 review 修改权限。只读检查：

```sql
SELECT current_user, tableowner,
       has_table_privilege(current_user, 'gao_note_attachments', 'SELECT,INSERT,UPDATE,DELETE')
FROM pg_tables
WHERE schemaname = 'public' AND tablename = 'gao_note_attachments';
```

预期权限 true；现在 owner=gao，gsmlg_test无权限。若需 provisioning，把环境变更单独记录，不混进业务迁移，不触碰 dev/production 数据。

- [ ] 在正确 DB 环境运行下方 scoped baseline，预期全部执行且 0 failures；未满足时此阶段未完成。

```sh
DATABASE_URL=postgres://gsmlg_test:gsmlg_test@localhost:5433/gsmlg_test \
PGHOST="$PWD/.devenv/run/postgres" PGPORT=5433 \
mix test apps/gsmlg_gao_note/test/ \
  apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_controller_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_label_controller_test.exs \
  apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_attachment_content_controller_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/gao_note_mcp_controller_test.exs \
  apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/gao_note_attachment_content_controller_test.exs
```

凭据为仓库已有测试默认，按实际测试 DB 更换；worktree 的 socket 路径应指向实际项目运行中的 PostgreSQL。仅设 PGPORT/POSTGRES_PORT 不足以覆盖 TOML port，DATABASE_URL 必须包含5433。

## 任务2：冻结契约并完成存量数据决策

**Files:**
- Read: `docs/reviews/fixtures/gaonote-agent-note-20261008/{rest,mcp}-inventory.json`
- Read: `docs/reviews/fixtures/gaonote-agent-note-20261008/mcp-contract-vectors.json`（20 个来源可核查的验收向量；符号替换/harness 尚需实现）
- Create: `apps/gsmlg_gao_note/test/fixtures/agent_note/`（从固定版本提取实际 wire schema 与 fixture）
- Create: `apps/gsmlg_gao_note/test/gsmlg/gao_note/compat/contract_test.exs`
- Read: `apps/gsmlg_gao_note/lib/gsmlg/gao_note/{attachment,label_setting}.ex`
- Read: `apps/gsmlg/priv/repo/migrations/20260718000000_redesign_gao_note_attachments.exs`

- [ ] 从 reference 源码 schema generator / local isolated HTTP 服务抓取 discover/tools-list，禁用业务写入；记录 SHA、协议、请求 headers 和响应。
- [x] 比较 canonical inventory：12工具且不混入 old gao_note.*、label-setting工具或resources；Note REST恰有24操作，参考无 REST PATCH `/api/notes/{id}`，MCP patch不能误当REST endpoint。（源码匹配；modern runtime discovery 仍未关闭。）
- [x] 选择并记录 canonical MCP listener：选定 public web 4110 的 `/api/notes` 与同一 base URL `/mcp`，使用 public Guardian access token 或现有 GaoNote service key，不开放匿名 MCP 写入。
- [ ] 列明 safety exceptions：auth、Origin、Range enhancement；记录客户端需要的 Bearer/API key，不移除既有控制来达到表面 parity。
- [ ] 设计附件外部 ID 映射：当前 id global string PK，参考 id note-scoped。建议保留内部存储PK、新增 note-scoped API id，以 `(note_id, api_id)` 唯一约束映射；旧数据 api_id=id。验证两个 note 可以各有 `attachment-1`，旧 URL/清理引用仍正确。不得对全局PK直接降约束导致读写/worker关联串笔记。
- [ ] 冻结 label case 决策：参考 case-sensitive，当前 lower unique与lower lookup。兼容入口须能区分 `Topic`/`topic`，存量保留；迁移/legacy ambiguous lookup 策略需先写清，不能静默重命名或合并。此项是完整兼容的设计门槛，不是可略过的 cosmetic diff。
- [ ] 确认 external indexing/search 服务和 PDF renderer 的实际服务边界；`note_chunking.md` 明确禁止本版本地 chunks/vector table。API shape可先做，能力验收不得绕过该边界。

## 任务3：共享 revision 和原子 mutation

**Files:**
- Modify: `apps/gsmlg_gao_note/lib/gsmlg/gao_note/note.ex`
- Modify: `apps/gsmlg_gao_note/lib/gsmlg/gao_note.ex`
- Modify: `apps/gsmlg_gao_note/lib/gsmlg/gao_note/{attachments,batch_actions}.ex`
- Create: `apps/gsmlg/priv/repo/migrations/20261008000000_add_gao_note_revision.exs`（实施时检查timestamp唯一）
- Create: `apps/gsmlg_gao_note/test/gsmlg/gao_note/compat/revision_test.exs`

- [ ] 先添加 public-domain regression：同一 expected_revision 两个真实 DB writer，最多一个 changed成功，另一个 revision_conflict；stale失败笔记/标签/附件/清理jobs均不变。
- [x] Migration增加 bigint not-null default1，并check revision>0；保留已有记录。迁移内容：

```elixir
defmodule GSMLG.Repo.Migrations.AddGaoNoteRevision do
  use Ecto.Migration

  def change do
    alter table(:gao_notes) do
      add :revision, :bigint, null: false, default: 1
    end

    create constraint(:gao_notes, :gao_notes_positive_revision, check: "revision > 0")
  end
end
```

- [x] Note schema增加 `field(:revision, :integer, default: 1)`；不能把 revision 放进 caller可任意cast的普通attrs allowlist。
- [ ] 锁 active/deleted note后在事务内比较 expected/current；根据最终 title/content/labels/attachments 的语义差异更新 revision，no-op不递增、不改updated_at。mutation结果固定 `id/revision/changed`；不同transport只负责映射错误。
- [ ] 为 legacy/UI label-only/附件/批量/soft-delete/restore全部写路径建立revision递增，避免只在compat API递增造成绕过。旧入口未带 expected_revision 时保持旧交互语义，但每次实际变化必须更新共享revision。
- [ ] 复用现有 deterministic locks、Attachment staging cleanup、Oban purge和BatchActions事务，不重写成best-effort。
- [ ] 运行新增 revision tests + `gao_note_test.exs` + `batch_actions_test.exs` + 相关附件tests；验证 migrated old note revision1、rollback、same-state no-op、deleted state预条件和不同连接并发。

## 任务4：selectors、label catalog 和 bulk/batch

**Files:**
- Create: `apps/gsmlg_gao_note/lib/gsmlg/gao_note/compat/label_selector.ex`
- Modify: `apps/gsmlg_gao_note/lib/gsmlg/gao_note/{label_setting,label_value,batch_actions}.ex`
- Modify: `apps/gsmlg_gao_note/lib/gsmlg/gao_note.ex`
- Create: `apps/gsmlg_gao_note/test/gsmlg/gao_note/compat/{label_selector,label_mutation}_test.exs`

- [ ] parser/table vectors覆盖 presence、`&` AND、`= != > >= < <= ^= $= ~=`、`~<percent-key>==<percent-value>` exact语法；保留raw空白、UTF8与百分号。
- [ ] `label="~bad"` 应 client error；不能把 invalid syntax 当无条件查询。不要把 `"="` 误定为参考400：参考将它作bare key，这是现有reference实际行为。
- [ ] 建立 case-sensitive key、typed比较、datetime wire名的compat映射；G额外 year/year-month/year-season类型不能出现在参考closed type contract。保留其原legacy可用性。
- [ ] catalog CRUD以key为外部身份，按reference status/body规则；labels input tuple转换仅在compat adapter，MCP输出labels对象与REST tuple分开。
- [ ] 两种批量入口独立：selector bulk set/remove原子返回matched/updated/unchanged；selected notes+expected_revision action add/update/remove返回requested/updated/unchanged。counts按笔记计算；当前changed也是每笔记最多一个change的计数，仍需按reference operation与matched/unchanged定义验证后映射字段，不能只改返回名称。
- [ ] 无匹配返回0/0/0；no-op不变revision；某笔记stale/invalid时selected batch全量回滚；remove key保留catalog。测试duplicate keys、set/remove同key、reserved key、typed错误和empty mutations。
- [ ] 修复 malformed labels 的5xx误分类：compat合法tuple应成功，坏类型应参考client error；旧API malformed labels也需确定性4xx，内部storage错误仍5xx。

## 任务5：严格内容补丁、read-lines 和附件兼容

**Files:**
- Create: `apps/gsmlg_gao_note/lib/gsmlg/gao_note/compat/{content_patch,note_lines}.ex`
- Modify: `apps/gsmlg_gao_note/lib/gsmlg/gao_note/{attachment,attachments}.ex`
- Modify: `apps/gsmlg_gao_note/lib/gsmlg/gao_note.ex`
- Create: `apps/gsmlg_gao_note/test/gsmlg/gao_note/compat/{content_patch,note_lines,attachment}_test.exs`
- Add migration for任务2确定的note-scoped attachment API id。

- [ ] 从 reference `crates/note-core/tests/content_patch_test.rs` 移植有限完整向量，失败先于实现。最小行为断言：

```elixir
assert {:ok, "before\nnew\nafter\n"} =
  ContentPatch.apply("before\nold\nafter\n", "@@\n before\n-old\n+new\n after")

assert {:ok, "α\r\n新\r\nβ\r\nlast"} =
  ContentPatch.apply("α\r\nold\nβ\r\nlast", "@@\n α\n-old\n+新\n β")
```

测试中alias `GSMLG.GaoNote.Compat.ContentPatch`；此新模块公开 `apply/2 -> {:ok,binary} | {:error,reason}`。拒绝 fuzzy、ambiguous、unanchored、重叠/逆序和file-level patch；不能用外部git apply模糊匹配。

- [ ] read-lines以原文 `String.split(content, "\n", trim: false)` 生成1-based `n/text`，保留CR和末尾空行；tag为UTF8原始字节FNV-1a32（seed0x811c9dc5、xor byte、乘0x01000193 modulo2^32、小写8hex），不是SHA256。返回id/revision/tag/lines。
- [ ] replace要求title/content/attachments/labels全部提供；patch省略保留、[]清空、explicit null拒绝、全省略拒绝，content允许string或strict `{apply_patch}`，原子处理全部字段。
- [ ] 实现 note-scoped upsert、revision检查、新建/替换路径collision/清理、文本与binary表示。MCP put没有update_content；**standalone put允许content+base64同时提供且bytes相等**；aggregate replace/patch attachment要求XOR。保留两种不同规则，不统一简化。
- [ ] get attachment返回metadata对象与content/content_base64平级；UTF8用content，binary用base64，互斥输出。delete missing参考false/null；mutation成功带revision。
- [ ] scoped tests验证双note相同public attachment id不串读、不串删、文件失败/事务回滚无残留、旧附件页面/HTTP Range继续通过。

## 任务6：REST兼容入口与OpenAPI

**Files:**
- Create: `apps/gsmlg_web/lib/gsmlg/web/controllers/agent_note_controller.ex`
- Create: `apps/gsmlg_web/lib/gsmlg/web/controllers/agent_note_json.ex`
- Create: `apps/gsmlg_web/lib/gsmlg/web/open_api/agent_note_operations.ex`
- Modify: `apps/gsmlg_web/lib/gsmlg/web/router.ex`
- Create: `apps/gsmlg_web/test/gsmlg_web/controllers/agent_note_controller_test.exs`
- Create: `apps/gsmlg_web/test/gsmlg_web/controllers/agent_note_labels_controller_test.exs`

- [ ] 先实现list/get/create/PUT/DELETE/count/trash，后接任务4的catalog/bulk/batch和任务8的raw/render/search/export。只添加目标真实24操作，不增加参考没有的REST patch假契约。
- [ ] bare JSON、Unix秒、summary无content/attachments，detail metadata无content_url；REST labels tuple。
- [ ] 示例验收：`POST /api/notes` with title/content/labels返回200 `{id}`；`GET /api/notes?limit=0`返回 `[]`；`DELETE /api/notes/{id}?expected_revision=1`成功204；stale PUT409结构化error；not-found GET404 text/plain。auth例外按任务2明确。
- [ ] 错误逐operation实现：参考read/search/create常text/plain；mutation为code/message/details/retryable。不要全局统一一种JSON后宣称same API。
- [x] OpenAPI纳入专用operation模块，生成路径/method与Note24 inventory逐项比较；legacy paths/spec仍存在。（源码清单比较完成，完整 runtime schema matrix 仍待验收。）
- [ ] 运行新增controller tests + 当前三个GaoNote web controller files；closed schema/headers/status/errors与auth负向覆盖。

## 任务7：12 MCP兼容工具与上游transport门槛

**Files:**
- Create: `apps/gsmlg_gao_note/lib/gsmlg/gao_note/mcp/agent_note_server.ex`
- Create: `apps/gsmlg_gao_note/lib/gsmlg/gao_note/mcp/agent_note_tools.ex`
- Create: `apps/gsmlg_gao_note/lib/gsmlg/gao_note/mcp/agent_note_plug.ex`
- Modify: task2选定的web listener `application.ex` / `router.ex`，复用其已有auth pipeline。
- Modify only after upstream release: `apps/gsmlg_gao_note/mix.exs`, `mix.lock`
- Create: `apps/gsmlg_gao_note/test/gsmlg/gao_note/mcp/agent_note_contract_test.exs`
- Create: chosen listener的 `controllers/agent_note_mcp_controller_test.exs`

- [x] 12名字精确为 save_note/get_note/list_notes/semantic_search/read_note_lines/replace_note/patch_note/delete_note/bulk_update_note_labels/put_note_attachment/get_note_attachment_content/delete_note_attachment，canonical `/mcp`只tools不混入旧resources。（源码注册匹配。）
- [ ] save_note只title/content/labels，不收initial attachments；返回id/revision。get返回top-level note；list返回 `{notes}`，search返回 `{results}`；mutation返回id/revision/changed。schema未知字段、required/default/null策略逐工具照fixture，不全局猜测。
- [ ] Domain error转换正确：validation对应invalid_params、mutation tool error包含structured code/message/details/retryable。revision conflict包含expected/current供客户端重新读取；失败不得mutation。
- [ ] tools/DTO的单元与domain tests可先做。**现代HTTP实现当前 BLOCKED_UPSTREAM #56**，不能fork依赖或在app写protocol shim。
- [ ] [Backplane #58](https://github.com/gsmlg-opt/backplane/issues/58) Bug / `internal request` / blocker 修复并更新依赖后，重新验收 unknown top-level/nested input fields；当前 installed validator 可崩溃，失败测试保留，不能跳过或 app-side shim。
- [ ] 只有上游issue resolved、新package发布并更新lock后，执行2026 discover/list/call无initialize/no-session、headers/metadata/resultType/cacheScope/ttlMs、header mismatches与legacy2025客户端回归。前置条件未满足时该阶段不能标complete。

## 任务8：真实搜索、raw/render/dashboard与PDF

**Files:**
- Create: `apps/gsmlg_gao_note/lib/gsmlg/gao_note/compat/search.ex`
- Modify: existing `note_chunking.md`（只在external service contract确定后更新）
- Modify: `apps/gsmlg_web/lib/gsmlg/web/controllers/agent_note_controller.ex`
- Read/reuse: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/gao_note_markdown.ex`
- Add scoped search/render/export tests under GaoNote compat 和AgentNote controller tests。
- Config changes, if required: `apps/gsmlg_config/lib/gsmlg/config/{schema,setup}.ex` + TOML defaults/test config。

- [ ] external search返回真实 title/dense检索并采用reference weighted RRF语义（title3/content1、k60）；minimum_score过滤在shared pipeline、REST/MCP一致，标签匹配、limit filling、deleted exclusion与索引更新一致。不能ILIKE加固定score，也不能违背当前external chunk storage边界创建本地chunks/vector table。
- [ ] 将save/update/delete/restore/revision变化持久化为索引任务并验证retry/idempotency；服务离线时明确capability/error，不把未索引笔记当成功匹配。
- [ ] raw Markdown/HTML和 `/notes/{id}/content` alias、render片段、attachment relative links、CSP/nosniff、dashboard ETag/304按REST matrix验证。
- [ ] export capabilities按reference已配置条件返回（pdf_export.is_some()，不代表renderer健康探针）；PDF功能验收另需真实renderer运行证据，验证content-type/disposition、revision snapshot、timeout/size/status和real renderer生成可读PDF；renderer未配置不能声称PDF parity。
- [ ] 完成后只跑相关GaoNote/AgentNote tests与修改文件format；按批准scope要求CI strict compile时保留既有warnings证据，不擅自修无关app。最终以同一组request fixtures分别请求reference与GaoNote，对动态id/time作声明的规范化，其余JSON/headers/status逐项比较。

## 退出门槛

- [ ] Note24和MCP12全部通过contract matrix；shape兼容与真实capability分别有证据。
- [ ] 现有数据/legacy endpoints/UI、附件storage/purge、auth与audit无回归。
- [ ] 上游协议门槛已解除并在更新依赖后实测；auth/Origin安全例外有明确记录。
- [ ] 范围内tests全部通过，未在scope外修问题。
- [ ] 清单完成即停止；合并、推送、部署、Org/System是后续明确授权的任务。

**当前交接状态：** 领域、REST24、MCP12 与服务 adapters 已在隔离 worktree 实施，最终 scoped 测试计数待 parent 填入实施报告。未满足退出门槛：MCP现代transport blocked by upstream #56、invalid-input acceptance blocked by upstream #58；真实搜索/index/renderer、Origin 与 render/decoder 差异仍待验收。不自动 commit/push/merge/deploy，不将本轮实施标为完整 parity。
