# GaoNote / Agent Note API 兼容性审查

审查日期：2026-10-08。当前项目 `gsmlg-dev/gsmlg_umbrella`：`main@9d7e129c7b65fd5f3f51057e6feab9b3df6c5810`。
参考：[gsmlg-opt/agent-note](https://github.com/gsmlg-opt/agent-note/tree/1a16690d3f0bcdb08e00752e46d76f234313416b)，固定 SHA `1a16690d3f0bcdb08e00752e46d76f234313416b`。已通过 `git ls-remote https://github.com/gsmlg-opt/agent-note.git HEAD refs/heads/main` 确认参考本地源码与该 GitHub main 一致。

## 结论

**GaoNote 已有笔记、标签、附件、回收站和原子批量操作的领域基础，但不是 Agent Note API 的兼容实现；客户端不能只更换服务器地址就直接使用。** REST 当前 7 个操作，参考 Note 范围 24 个；当前 MCP 11 个 prefixed tools，参考 `/mcp` 12 个 unprefixed tools。这些是接口数量，不是完成度比例：已有接口也有重要行为差异。

开发准备默认范围为 **Note REST 24 操作 + MCP 12 工具**。System 4 REST 和 Org 40 REST / 40 MCP 工具单列为扩展，未获得明确包含要求前不进入实施范围。此范围是假设，并非用户已经确认。

| 优先级 | 差异 / 风险 | 修复方向 |
|---|---|---|
| P1 | 缺 revision / expected_revision，旧客户端写入可覆盖并发修改；行锁本身不能发现 stale client | 为所有笔记写入建立共享 revision 检查、变更递增和 no-op 规则 |
| P1 | `/api/gao_notes`、`/mcp/gao_note` 与参考路径不同；工具名称/注册也不同 | 专用兼容入口与 DTO，保留旧 API / LiveView 的既有契约 |
| P1 | labels 二元数组请求被当前 controller 误报 500；当前 envelope、ISO 时间、summary 等不兼容 | 对照 REST 与 MCP 各自 DTO，时间使用 Unix 秒，显式处理客户端错误 |
| P1 | 无 replace_note、strict patch_note、read_note_lines、selector bulk-labels | 共享领域实现；先测试事务回滚、并发、null/省略/空数组与精确补丁 |
| P1 | MCP 2026-07-28 协议不受当前 Backplane 1.6.3 支持 | 上游 Feature blocker [gsmlg-opt/backplane#56](https://github.com/gsmlg-opt/backplane/issues/56) |
| P1 | 附件现在 global ID、update-only、update_content flag；参考 note 内 ID 和 upsert | 明确存量映射，再实现 note-scoped ID、revision 与内容编码矩阵 |
| P2 | selector grammar、大小写、typed labels、分页 defaults/bounds 不同 | 独立 parser 与参考语义向量；不能只改 String.split |
| P2 | 当前 ILIKE 搜索无 embedding / score / minimum_score；PDF 等缺失 | 对接真实检索 / renderer 服务，不能用伪 score 或占位响应声称兼容 |

两边相同的领域能力包括 title + Markdown content、自动创建缺失标签 key、note-owned 相对路径附件、软删除/恢复/清除以及事务批量写入。本项目额外有标签 color/status/errors、category dashboard、审计记录、附件流式 Range 支持、Guardian/API key 边界、MCP resources。应通过兼容序列化复用这些能力，避免重写已可靠的事务/存储基础。

## 实测证据与限制

1. `MIX_ENV=test mix run --no-start docs/reviews/fixtures/gaonote-agent-note-20261008/controller-probes.exs`：直接 controller probe，不启动应用、不访问 DB。参考 labels 请求 `[["topic","ecto"]]` 返回 **500**；非数组 labels 也返回 **500**；legacy create 携带 expected_revision 返回 **400 unknown_fields**。Note schema 无 revision。脚本内容归档在 fixtures 中，可重新运行；这证明 controller 行为，不代表经过 router/auth 的网络 E2E。
2. Backplane 纯运行 probe：`Registry.negotiate("2026-07-28")` 返回 unsupported_version；`server/discover` handler 返回 method_not_found；tool serializer 无 resultType。已开 Feature + `internal request` + severity blocker 的上游 issue #56，并在两个 StreamableHTTP plug 的调用处加入 `TODO(upstream)`。只阻塞现代 MCP 协议实现，REST / 领域准备可继续；不实现本地 transport 绕过。
3. 全 GaoNote + 关联 controller scoped baseline 未通过：`apps/gsmlg_gao_note/test/gsmlg/gao_note/attachment_input_test.exs:56` 混用 map keyword 与 `=>` 顺序导致 SyntaxError，测试尚未执行。
4. 排除上述文件的 scoped interface baseline：GaoNote 11 tests / 1 failure；Web 合计 30 tests / 30 failures。共 **41 tests / 31 failures**，失败为 `gsmlg_test` 用户无 `gao_note_attachments` 权限，不能认定为 API 行为失败。只读 PostgreSQL 查询确认此表 owner=gao，测试角色 SELECT/DELETE 权限=false。Admin 附件测试另有编译错误：`gao_note_attachment_content_controller_test.exs:12` 的 get/2 同时从 Plug.Router / Phoenix.ConnTest 导入；Admin MCP 文件在此次组合运行中未完成。
5. 环境连接应显式使用 DATABASE_URL 的 5433 端口；仅 POSTGRES_PORT 会被 TOML 5432 覆盖。第一次错误角色/端口启动失败已纠正为运行参数；未改应用配置、未 grant 权限、未改测试或业务实现。
6. 编译还报告既有 warnings（Attachments.stage_entry/3 不可达 error clause、Admin 临时附件 unused destination、LiveView clause grouping 等）；未执行全仓 warnings-as-errors / Credo / Dialyzer，不将本轮结果视作 CI green。

日志归档仅包含最终 scoped 尝试和 pure probes，不包含配置凭据。业务源码本轮只新增两个上游追踪注释；未实现 API 修复、未提交或推送、未检查部署环境。

## 开发准备产物

- [修复实施分阶段清单](../superpowers/plans/2026-10-08-gaonote-agent-note-api-parity.md)：文件范围、依赖关系、验收向量与停止条件。
- [REST inventory](fixtures/gaonote-agent-note-20261008/rest-inventory.json)：固定参考 SHA 的 Note24 + System4 + Org40，68 个唯一 method/path，带来源行号。
- [MCP inventory](fixtures/gaonote-agent-note-20261008/mcp-inventory.json)：12 tools 的 source-derived 输入/输出字段清单。不是完整运行时 JSON Schema snapshot，生成的 schema/annotations 仍需后续真实 discovery fixture 验证。
- [20 个 MCP 验收向量](fixtures/gaonote-agent-note-20261008/mcp-contract-vectors.json)：包含 revision、strict patch、read-lines、附件编码与现代协议行为。动态 id/revision 使用声明的符号绑定；这是测试数据，尚无自动执行 harness，不能把 JSON 校验当成行为测试通过。

**部署例外：** 当前 Guardian/API key 和 Origin 策略与参考不同；开发默认保留本项目安全边界。必须在最终兼容验收中明确这项例外，不能声称匿名访问和 CORS 已完全一致。不要把整个 umbrella system config 暴露成笔记配置。

下文 G 为当前项目，R/A 为参考源码。参考证据可在固定 SHA 的 GitHub tree 中核验；引用行号对应本轮基线，后续代码变动后需重新冻结。

---

## 完整Note24操作矩阵

所有R路径为参考对外真实合同。GaoNote有相近功能不等于兼容；基础请求/返回细节见后文。

| # | Method | 参考Path | 参考输入 | 参考输出/错误 | 当前GaoNote | 参考源码证据 |
|---|---|---|---|---|---|---|
| 1 | GET | `/api/dashboard` | If-None-Match支持；10秒缓存 | 200 DashboardDto+ETag；匹配304无body | REST缺失；有LiveView Dashboard，不能当REST | R `crates/note-server/src/notes_api.rs:1066` |
| 2 | POST | `/api/notes` | title/content必填，attachments/labels默认[]；labels为二元数组 | 200 {id}；非法400，重复409；错误text/plain | 相近 POST /api/gao_notes，但201完整data envelope、labels格式不同、Bearer必需 | R `crates/note-server/src/notes_api.rs:1109` |
| 3 | POST | `/api/notes/bulk-labels` | selector非空，set:[[key,value]]，remove:[key]；拒绝unknown fields | 200 {matched,updated,unchanged}；400/500 text/plain | REST缺失；需selector批量领域入口 | R `crates/note-server/src/notes_api.rs:1162` |
| 4 | POST | `/api/notes/batch-labels` | notes:[{id,expected_revision}], action:{type:add/update/remove,...}；拒绝unknown fields | 200 {requested,updated,unchanged}；400/404/409/500 mutation JSON | REST缺失；现有BatchActions事务原子，但入参/返回和revision不同 | R `crates/note-server/src/notes_api.rs:1200` |
| 5 | POST | `/api/notes/batch-delete` | notes:[{id,expected_revision}]；原子预检查 | 200 {requested,deleted}；400/404/409/500 mutation JSON | REST缺失；现有batch_delete_notes为事务原子，无revision | R `crates/note-server/src/notes_api.rs:1234` |
| 6 | GET | `/api/notes` | limit默认10，clamp0..1000；offset非负；label完整selector | 200裸summary数组（无content/attachments）；错误text/plain | 相近GET /api/gao_notes，默认50/clamp1..200、完整笔记envelope，selector不等价 | R `crates/note-server/src/notes_api.rs:1352` |
| 7 | GET | `/api/notes/count` | label selector；兼容接收并验证limit/offset但不影响count | 200 {total}；400/500 text/plain | REST缺失 | R `crates/note-server/src/notes_api.rs:1385` |
| 8 | GET | `/api/notes/{id}` | opaque id string | 200裸NoteDto；404/500 text/plain | 相近GET /api/gao_notes/{id}，UUID、data envelope、ISO时间、labels对象、无revision | R `crates/note-server/src/notes_api.rs:1406` |
| 9 | GET | `/api/notes/{id}/raw` | type缺省Markdown；type=html为嵌入HTML，其他值400 | 200 text/markdown或text/html；HTML有CSP/nosniff、附件链接改写 | 缺失 | R `crates/note-server/src/notes_api.rs:1430` |
| 10 | GET | `/notes/{id}/content` | raw endpoint别名，注意不在/api下 | 同raw | 缺失 | R `crates/note-server/src/notes_api.rs:1507` |
| 11 | GET | `/api/notes/{id}/attachments/{*path}` | opaque note id + greedy附件path；直接读取完整content | 200原mime+nosniff；404/500 text/plain；无Range支持 | 相近GET /api/gao_notes/{id}/attachments/{*path}；Bearer必需；增强Range206/416、stream、storage503 | R `crates/note-server/src/notes_api.rs:1544`; runtime R `crates/note-server/src/notes_api.rs:1880` |
| 12 | PUT | `/api/notes/{id}` | expected_revision/title/content必填；attachments/labels默认[]、完整替换 | 200裸NoteDto；400/404/409/500 mutation JSON | 相近PUT /api/gao_notes/{id}；expected_revision被拒、attachments必须提供、title/content部分修改、缺labels保留 | R `crates/note-server/src/notes_api.rs:1579` |
| 13 | DELETE | `/api/notes/{id}` | query expected_revision必填，soft delete | 204；400/404/409/500 mutation JSON | REST缺失；有领域soft delete但无revision | R `crates/note-server/src/notes_api.rs:1623` |
| 14 | GET | `/api/trash` | 无分页query | 200裸TrashNoteDto数组，含deleted_at/revision | REST缺失；有LiveView回收站和领域能力 | R `crates/note-server/src/notes_api.rs:1653` |
| 15 | POST | `/api/trash/restore` | notes:[{id,expected_revision}]非空；原子恢复 | 204；400/404/409/500 mutation JSON | REST缺失；有领域restore但无revision | R `crates/note-server/src/notes_api.rs:1683` |
| 16 | DELETE | `/api/trash/{id}` | query expected_revision必填 | 204；400/404/409/500 mutation JSON | REST缺失；有领域permanent delete但无revision | R `crates/note-server/src/notes_api.rs:1727` |
| 17 | POST | `/api/notes/search` | JSON query/limit必填，label可选完整selector | 200裸数组summary+revision+score（融合RRF分数）；400/500 text/plain | 缺失；当前GET search只ILIKE(title/content)，没有rank/score | R `crates/note-server/src/notes_api.rs:1779` |
| 18 | POST | `/api/render` | JSON content，attachment_base可选 | 200 text/html片段，改写相对附件URL | 缺失；后台Markdown模块不是此API | R `crates/note-server/src/notes_api.rs:1830` |
| 19 | POST | `/api/labels` | key/description必填，value_type默认text；reserved字符禁止 | 200空body；400非法key/type，其他500 text/plain（当前参考重复key也可能500） | REST缺失；领域create_label_setting存在，schema/key/case不同 | R `crates/note-server/src/labels_api.rs:58` |
| 20 | GET | `/api/labels` | 无query | 200裸[{key,description,value_type}] | 相近GET /api/gao_notes/label_settings，data envelope且多id/name/color/metadata | R `crates/note-server/src/labels_api.rs:105` |
| 21 | PUT | `/api/labels/{key}` | path用label key；description必填；value_type可选 | 200空body；400 text/plain | REST缺失；领域按UUID更新 | R `crates/note-server/src/labels_api.rs:123` |
| 22 | DELETE | `/api/labels/{key}` | path用label key；配置为category的label禁止删除 | 200空body；400 category在用，500 storage text/plain | REST缺失；领域delete_label_setting/category保护已存在 | R `crates/note-server/src/labels_api.rs:159` |
| 23 | GET | `/api/export/capabilities` | 无query；根据renderer配置报告能力 | 200 {markdown:true,pdf:boolean}；Cache-Control:no-store | 缺失 | R `crates/note-server/src/export_api.rs:116` |
| 24 | GET | `/api/notes/{id}/export/pdf` | expected_revision query必须正数；renderer能力可关闭 | 200 PDF+X-Note-Revision/no-store/nosniff/安全文件名；400/404/409/413/422/429/500/502/503/504 ExportApiError | 缺失；不能用HTML或假PDF替代 | R `crates/note-server/src/export_api.rs:135` |

## 响应、创建和更新的实质差异

- G返回`{data:...}`，R返回裸数组/对象。G `apps/gsmlg_web/lib/gsmlg/web/controllers/gao_note_json.ex:4`；R `crates/note-server/src/notes_api.rs:1363`、`:1417`。
- G列表`note_summary/1`直接调用完整`note/1`，包括content/attachments；R summary只有id/title/labels/created_at/updated_at/revision。G `apps/gsmlg_gao_note/lib/gsmlg/gao_note/presenter.ex:22`；R `crates/note-server/src/notes_api.rs:637`。
- G时间为ISO8601，R为Unix秒级i64（写入使用Utc::now().timestamp()）。G Presenter `:129`，R notes_api `:629`；R `crates/note-pipelines/src/save_note.rs:92`、`crates/note-pipelines/src/update_note.rs:117`。
- G labels是对象，含value_type/description/status/errors；R是`[[key,value],...]`。G Presenter `:38`；R notes_api `:624`。G attachment metadata额外content_url（Presenter`:60`），R只id/path/mime/description（notes_api`:598`）。
- G创建201+完整envelope；R创建200+`{id}`。G `apps/gsmlg_web/lib/gsmlg/web/controllers/gao_note_controller.ex:44`；R notes_api`:1159`。
- R PUT必须expected_revision/title/content；attachments/labels默认空，完整替换。G PUT/PATCH共用update，title/content可部分修改，labels不传保留，attachments必须传。R notes_api`:54`；G router`:114`，G `apps/gsmlg_gao_note/lib/gsmlg/gao_note.ex:472`、`:946`。既有缺attachments400测试：G `apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_attachment_content_controller_test.exs:504`。
- G schema无revision（G `apps/gsmlg_gao_note/lib/gsmlg/gao_note/note.ex:11`），write allowlist拒绝expected_revision（G controller`:9`、`:114`），参考合法PUT即使映射路径也会400。R revision用于PUT/DELETE/restore/permanent delete/batch，并保证stale409。
- G只接受labels字符串或map，不接受R二元数组（G gao_note.ex`:1036`、`:1043`、`:1054`）。例如合法R请求labels:`[["topic","ecto"]]`会得到字符串domain error，再落入G controller`:269`的500 catchall。此500已由直接controller probe复现；未进行router/auth/HTTP E2E。
- G顶层unknown fields400；R Save/Update DTO没有serde deny_unknown_fields而默认忽略顶层unknown字段，R attachment/bulk/batch明确拒绝。这种操作差异应按参考fixture对齐，不能统一“更严格”后宣称相同合同。R notes_api`:41`、`:53`、`:230`、`:348`；G controller`:114`。

## Labels、selector、大小写和空白

- R key匹配区分大小写：`label.key != selector.key`，R `crates/note-core/src/types.rs:194`。G key匹配case-fold：lower(setting.name)==normalized_key，G gao_note.ex`:855`。G写入labels按normalized_key去重（`:1025`），因此`Topic`与`topic`不能保持参考的独立key语义。
- R普通selector按`&` AND拆分，term/key/value trim；presence，以及`= != > >= < <= ^= $= ~=`；只有`~<encoded-key>==<encoded-value>`是保留原始key/value字节（空白/空值/特殊字符）的ExactEq。R types.rs`:131`、`:242`。不要把普通`key==value`误认为ExactEq：legacy把它解析成`key`等于`=value`，测试在`:661`。
- R普通Eq/text比较保留大小写但trim字符串；number/version/date/datetime/time按typed comparable比较。StartsWith/EndsWith/Regex对value不区分大小写；ExactEq直接原字节比较，仍按精确key匹配。R types.rs`:210`、`:293`。
- G仅presence/单次`key=value`，数组可AND；不支持单字符串`&`和复杂operator，value直接数据库 equality。G gao_note.ex`:849`、`:879`。G未匹配parser时忽略filter，G`:874`。
- **修正先前口头审查：R `label="="`不是400。** split_selector_term空key返回None（R types.rs`:260`），try_parse把整term作为bare key（`:163`）。因此不可用它作为双方400/200不一致的例子。可靠例子是`label="~bad"`：R缺`==`返回MalformedExactSelector（`:141`-`:144`），API读错误映射400（R notes_api`:1818`）；G当普通presence key处理，返回200（通常空数组）。这是源代码推导，未运行HTTP验证。参考坏exact测试R types.rs`:513`。
- G default limit50/clamp1..200，非法numeric字符串回默认；R default10/clamp0..1000、typed Query拒绝非法数值。G gao_note.ex`:25`、`:922`；R notes_api`:1315`。limit=0等边界需fixture。
- G搜索仅ILIKE(title/content)，G gao_note.ex`:836`；R POST JSON query/limit/label调用search_notes_filtered并返回RRF score，R notes_api`:1755`、`:1794`。不可把ILIKE结果加一个虚假score冒充混合检索。

## 错误、鉴权和附件

- G validation422、通常`{errors:...}`，401`{message:...}`；R create/read/search/labels错误多text/plain，validation400；R mutation为`{code,message,details,retryable}`。G controller`:192`、`:271`；G `apps/gsmlg_web/lib/gsmlg/web/guardian/api_auth_error_handler.ex:26`；R notes_api`:71`、`:1115`、`:1586`。应按操作对齐status/body/content-type，不设计一种统一JSON去替代参考实际合同。
- G匿名读notes/label settings，但写入和附件需要Guardian access JWT（router`:104`、`:118`）；R入站无auth middleware，是trusted network/reverse proxy边界（R `crates/note-server/src/main.rs:301`、`:640`）。R embedding bearer是出站认证，不是REST API key。
- **不得为parity静默取消G现有认证。** 准备需列为明确的兼容例外或另行定义安全访问入口；本轮不作架构扩张。
- G所谓public notes==全部active notes，G gao_note.ex`:79`；不要在审查报告中暗示已有visibility/owner过滤。
- G附件是有意义的增强：Range206/416、分块stream、storage503、受限inline/disposition；G `apps/gsmlg_web/lib/gsmlg/web/controllers/gao_note_attachment_content_controller.ex:61`。R直接整content body且不读Range，nosniff（R notes_api`:1558`）。保留增强同时明确基础合同/认证差异，避免回退安全属性。

## 已有BatchActions不是best-effort

G `apps/gsmlg_gao_note/lib/gsmlg/gao_note/batch_actions.ex:14`、`:40`、`:54`均Repo.transaction，失败rollback；锁定active notes按id排序FOR UPDATE（`:229`），标签setting FOR SHARE（`:163`）。已经具备原子事务基础。差距在revision预条件、R按key/action输入、counts命名、REST端点，**不需要把现有batch重写成原子实现，更不能误称当前best-effort**。R batch-label action用type=add/update/remove（R notes_api`:372`、`:379`），响应requested/updated/unchanged；G domain返回selected/matched/changed/unchanged。R bulk-selector与selected batch是不同API。

## System4操作（单列，待范围明确）

| Method | Path | 行为/差距 | 参考来源 |
|---|---|---|---|
| GET | `/api/system/config` | 200 SystemConfig；G无对应REST | R `crates/note-server/src/system_api.rs:17` |
| PUT | `/api/system/config` | 204，非法400，系统500；G无对应REST，需映射现有配置，不暴露整个umbrella配置 | R `crates/note-server/src/system_api.rs:35` |
| GET | `/api/system/info` | 200 SystemInfo，storage/embedding状态；G无对应REST | R `crates/note-server/src/system_api.rs:72` |
| GET | `/api/system/backup` | 200 gzip tar archive，no-store/nosniff、安全filename；G无对应REST | R `crates/note-server/src/system_api.rs:90` |

## Org40操作（扩展，不在默认开发范围）

R inventory明确40：`crates/note-server/tests/org_api_inventory_test.rs:29`；涉及workspace/documents/items/queue/agenda/execution/reviews/dependencies/note-links/audit完整领域，不是GaoNote现有笔记路由别名。以下逐项由该inventory提取，来源对应真实handler annotation或macro invocation。

| Method | Path | operation_id | 参考handler来源 |
|---|---|---|---|
| GET | `/api/org/workspaces` | `org_list_workspaces` | R `crates/note-server/src/org_api/workspaces.rs:19` |
| POST | `/api/org/workspaces` | `org_create_workspace` | R `crates/note-server/src/org_api/workspaces.rs:44` |
| GET | `/api/org/workspaces/{workspace_id}` | `org_get_workspace` | R `crates/note-server/src/org_api/workspaces.rs:70` |
| PATCH | `/api/org/workspaces/{workspace_id}` | `org_update_workspace` | R `crates/note-server/src/org_api/workspaces.rs:95` |
| POST | `/api/org/workspaces/{workspace_id}/archive` | `org_archive_workspace` | R `crates/note-server/src/org_api/workspaces.rs:123` |
| GET | `/api/org/workspaces/{workspace_id}/documents` | `org_list_documents` | R `crates/note-server/src/org_api/documents.rs:25` |
| GET | `/api/org/documents/{document_id}` | `org_get_document` | R `crates/note-server/src/org_api/documents.rs:82` |
| PUT | `/api/org/documents/{document_id}` | `org_put_document` | R `crates/note-server/src/org_api/documents.rs:111` |
| POST | `/api/org/workspaces/{workspace_id}/documents` | `org_create_document` | R `crates/note-server/src/org_api/documents.rs:54` |
| PATCH | `/api/org/documents/{document_id}/path` | `org_rename_document` | R `crates/note-server/src/org_api/documents.rs:139` |
| POST | `/api/org/documents/{document_id}/archive` | `org_archive_document` | R `crates/note-server/src/org_api/documents.rs:167` |
| POST | `/api/org/documents/{document_id}/restore` | `org_restore_document` | R `crates/note-server/src/org_api/documents.rs:195` |
| POST | `/api/org/documents/{document_id}/move` | `org_move_document` | R `crates/note-server/src/org_api/documents.rs:223` |
| POST | `/api/org/items/{item_id}/move` | `org_move_item` | R `crates/note-server/src/org_api/documents.rs:251` |
| POST | `/api/org/workspaces/{workspace_id}/import` | `org_import_workspace` | R `crates/note-server/src/org_api/documents.rs:279` |
| GET | `/api/org/workspaces/{workspace_id}/export` | `org_export_workspace` | R `crates/note-server/src/org_api/documents.rs:307` |
| POST | `/api/org/workspaces/{workspace_id}/items` | `org_create_item` | R `crates/note-server/src/org_api/items.rs:20` |
| GET | `/api/org/items/{item_id}` | `org_get_item` | R `crates/note-server/src/org_api/items.rs:46` |
| GET | `/api/org/items/{item_id}/context` | `org_get_item_context` | R `crates/note-server/src/org_api/items.rs:73` |
| POST | `/api/org/items/{item_id}/follow-ups` | `org_create_follow_up` | R `crates/note-server/src/org_api/items.rs:132` |
| POST | `/api/org/items/{item_id}/assignment` | `org_assign_item` | R `crates/note-server/src/org_api/items.rs:140` |
| POST | `/api/org/items/{item_id}/schedule` | `org_schedule_item` | R `crates/note-server/src/org_api/items.rs:148` |
| GET | `/api/org/queue` | `org_query_queue` | R `crates/note-server/src/org_api/operational.rs:17` |
| GET | `/api/org/agenda` | `org_query_agenda` | R `crates/note-server/src/org_api/operational.rs:41` |
| POST | `/api/org/items/{item_id}/claim` | `org_claim_item` | R `crates/note-server/src/org_api/execution.rs:20` |
| POST | `/api/org/items/{item_id}/claim/heartbeat` | `org_heartbeat_claim` | R `crates/note-server/src/org_api/execution.rs:77` |
| POST | `/api/org/items/{item_id}/claim/release` | `org_release_claim` | R `crates/note-server/src/org_api/execution.rs:85` |
| POST | `/api/org/items/{item_id}/progress` | `org_report_progress` | R `crates/note-server/src/org_api/execution.rs:93` |
| POST | `/api/org/items/{item_id}/result` | `org_submit_result` | R `crates/note-server/src/org_api/execution.rs:101` |
| POST | `/api/org/items/{item_id}/transition` | `org_transition_item` | R `crates/note-server/src/org_api/execution.rs:109` |
| POST | `/api/org/items/{item_id}/retry` | `org_retry_item` | R `crates/note-server/src/org_api/execution.rs:117` |
| POST | `/api/org/items/{item_id}/review/request` | `org_request_review` | R `crates/note-server/src/org_api/review.rs:48` |
| POST | `/api/org/items/{item_id}/review/approve` | `org_approve_item` | R `crates/note-server/src/org_api/review.rs:56` |
| POST | `/api/org/items/{item_id}/review/reject` | `org_reject_item` | R `crates/note-server/src/org_api/review.rs:64` |
| POST | `/api/org/items/{item_id}/dependencies` | `org_add_dependency` | R `crates/note-server/src/org_api/relationships.rs:20` |
| DELETE | `/api/org/items/{item_id}/dependencies/{dependency_item_id}` | `org_remove_dependency` | R `crates/note-server/src/org_api/relationships.rs:46` |
| POST | `/api/org/items/{item_id}/note-links` | `org_link_note` | R `crates/note-server/src/org_api/relationships.rs:76` |
| DELETE | `/api/org/items/{item_id}/note-links` | `org_unlink_note` | R `crates/note-server/src/org_api/relationships.rs:102` |
| GET | `/api/org/notes/{note_id}/work-items` | `org_list_note_work_items` | R `crates/note-server/src/org_api/relationships.rs:128` |
| GET | `/api/org/workspaces/{workspace_id}/events` | `org_list_events` | R `crates/note-server/src/org_api/audit.rs:18` |

## 开发修复准备与验收

1. P0冻结参考commit和合同fixture；默认Note REST24+MCP，System明确单列，Org仅扩展。需明确canonical路径、旧API保留策略和认证例外。所有DTO/status/content-type/headers作为transport合同，不将“功能类似”计为通过。
2. P1 revision schema+migration和写入链路原子预条件；新增兼容DTO/controller/router/OpenAPI，list/get/create/PUT/DELETE/count/trash。两请求同revision只能一成功；stale409、失败无部分修改；原有数据保留。
3. P2完整selector parser、key/case语义、catalog CRUD、bulk-selector和selected batch；保留现有事务基础，补revision和输入/输出映射。测试encoded exact、unicode、empty/whitespace、typed compare、malformed exact400、no-op counts与回滚。
4. P3 raw/content/render/dashboard，校验HTML和Markdowncontent-type、CSP、附件链接、ETag/304。
5. P4真实搜索与导出：RRF/embedding/标签组合语义，PDF capabilities/revision一致性/renderer/limits/error headers。服务不可用时按合同报告，不伪造兼容结果。
6. System需要scope确认后独立准备；Org独立PRD，默认不实施。

预计scope：GaoNote context/schema、必要migration、新增兼容DTO/controller/parser、web router/OpenAPI和对应tests；不要将REST DTO强塞进共享Presenter导致LiveView/MCP无关回归。labels大小写保留是存量兼容决策，先检查所有唯一约束和现有调用，不能只移除lower条件。

既有测试回归入口：

- G `apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_controller_test.exs`
- G `apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_label_controller_test.exs`
- G `apps/gsmlg_web/test/gsmlg_web/controllers/gao_note_attachment_content_controller_test.exs`（已有鉴权/创建/更新/附件/400/409/422，不可误报没有write tests）
- G `apps/gsmlg_gao_note/test/gsmlg/gao_note_test.exs` 与parser/revision/batch变更对应focused tests。

新增合同测试应独立于legacy API测试，以参考输入/输出fixture覆盖24个Note操作、并发/事务失败/坏输入。只运行范围内测试；本轮本节来源为静态源码，实际 baseline 证据见本文前部；数据库需显式 DATABASE_URL 端口5433。


---

# MCP 详细对照

## 结论和优先级

现有 GaoNote 功能概念相似，但不能让 Agent Note MCP 客户端原样切换使用。现有 tests 也明确固化旧 11 工具契约，不能视为参考 API 已一致。完整 MCP 2026-07-28 transport 一致性 **BLOCKED_UPSTREAM**；普通 schema、domain、结果 DTO、REST 准备可继续。

1. **P0：工具名和 endpoint 全面不一致。** G `apps/gsmlg_admin_web/lib/gsmlg/admin_web/router.ex:280` 只挂 `/mcp/gao_note`；G `apps/gsmlg_gao_note/lib/gsmlg/gao_note/mcp/admin_server.ex:15` 注册 11 个 `gao_note.*` 工具。A `crates/note-mcp/src/http.rs:65` 挂 `/mcp` + `/org/mcp`，A `crates/note-mcp/tests/org_inventory_test.rs:68` 列出精确 12 Note 工具。不仅 rename，还缺 list/read_lines/bulk labels/replace/patch 语义。G 的 label-setting 管理和 MCP resources 是额外能力，不在 A 12 Note 工具内。
2. **P0：无 revision 并发保护和原子 replace/patch。** G `apps/gsmlg_gao_note/lib/gsmlg/gao_note/note.ex:11` 无 revision；G `.../mcp/tools.ex:150` update 仅 id 必填，可 title/content/labels 更新且不接受 attachments，G `.../mcp/tools.ex:516` fetch 后直接 update，无客户端 expected_revision。A `crates/note-mcp/src/server.rs:356` replace 所有 writable fields + positive expected_revision 必填；`:407` patch positive revision 必填，省略保留、[]清空、显式 null 拒绝、content string 或 {apply_patch}；`:864` 原子 mutation、no-op 不涨 revision。A delete/附件 put/delete 也带 revision（`:469`, `:588`, `:738`）。这不能靠 aliases 达到一致。
3. **P0 upstream：Backplane 1.6.3 不支持目标现代协议。** G `apps/gsmlg_gao_note/mix.exs:36` 依赖 `~> 1.6`，`mix.lock:7` 锁 1.6.3；包源码 `deps/backplane_mcp_protocol/mix.exs:4` 版本和 `:5` @source_url 明确是 https://github.com/gsmlg-opt/backplane，`:97` package GitHub link。Registry 最高 2025-11-25；server/discover 未支持；tool serializer 无 resultType。A `crates/note-mcp/Cargo.toml:11` rmcp3.4；A `crates/note-mcp/tests/org_transports_test.rs:704` 明确要求2026-07-28 discover/cache/list，无 initialize，无 session header。只能将协议任务按用户上游规则提交 Feature blocker，禁止本地 silent workaround；上游 issue #56 已创建，调用处已添加 TODO。
4. **P1：结果 DTO 和 errors 不一致。** G `.../mcp/tools.ex:459` get 返回 structuredContent `{note: ...}`；`:492` create 返回完整 note，而 A get 是 note 本体、save 是 `{id,revision}`。G `.../presenter.ex:8` timestamps ISO8601，A `crates/note-mcp/src/server.rs:176` 使用 Unix i64、revision。G `.../presenter.ex:22` summary 等于完整 detail（包含 content/attachments），A summary 不含这两个。G `.../presenter.ex:38` label 多 status/errors，`:60` attachment 多 content_url；A closed outputSchemas 不包含这些。G `.../mcp/tools.ex:751` domain errors 只有 text+isError；A `.../server.rs:1052` mutation failure structured `{code,message,details,retryable:false}`，revision_conflict 包 expected/current revision。注意两边 schema validation 都可以是 JSON-RPC -32602；差异集中 domain error mapping，不能概括成 GaoNote 所有错误都是 tool error。
5. **P1：附件操作不同。** G `.../mcp/tools.ex:398` 明确 put 只替换已有 globally-unique attachment；G `.../attachments.ex:122` 先 fetch owned active attachment，不能创建。A `.../server.rs:938` add or replace、id 是 note 内唯一；请求不带 update_content，有 expected_revision，description 默认为空。G get `.../mcp/tools.ex:466` 总在 attachment 对象内返回 content_base64；A `.../server.rs:669` 元数据 attachment 与 content/content_base64 平级，UTF8 使用 content、binary使用base64且严格只输出其中之一（`:721`）。G delete 返回 attachment 对象，A `{deleted,revision}`，不存在返回false/null。**细节：A put 输入允许同时提供 content 和 content_base64，只要解码字节相同**（A `crates/note-core/src/types.rs:411`）；replace/patch aggregate 附件却要求 XOR（A `.../server.rs:296`）。G put true要求XOR、false禁止内容，不能误写目标统一XOR。
6. **P1：list、selector、semantic search 不能被旧 search 冒充。** G `.../mcp/tools.ex:112` query可选 + offset，G `.../gao_note.ex:836` ILIKE title/content，没有 score/embedder/minimum_score；A `.../server.rs:516` semantic query/limit 必填、无offset，返回 results+scores，A `crates/note-pipelines/src/search_notes.rs:50` embed+title/dense+RRF+saved minimum_score。G labels只字符串 key=value，A save/replace/patch是 `[key,value]` tuple数组。G selector `.../gao_note.ex:879` 仅 split第一个 `=`，A `.../server.rs:491` AND、presence、比较、前后缀/regex、percentencoded精确 `==`；畸形 selector应返回invalid_params。G default/max limit为50/200（`.../gao_note.ex:25`），且0钳制为1（`:923`）；A list为10/1000并支持0（A `crates/note-pipelines/src/list_notes.rs:4`）。

## 12 工具逐项映射

完整 required/optional/source/DTO 在 `docs/reviews/fixtures/gaonote-agent-note-20261008/mcp-inventory.json`。这是源码字段 inventory，不声称是运行时生成的全量 JSON Schema dump。

| A tool | G 最近能力 | 兼容差异 |
|---|---|---|
| save_note | gao_note.create_note | 名称；labels tuple vs string；A不接initial attachments；A返回id/revision，G完整note |
| get_note | gao_note.get | 顶层note对象 vs {note}；revision/timestamp/closed output字段 |
| list_notes | gao_note.search query空 | G未注册独立tool；不同limit/selector/summary |
| semantic_search | gao_note.search | G是ILIKE文本搜索，无scores、embedding、saved minimum_score |
| read_note_lines | 无 | id/revision/tag/1-indexed lines须新增 |
| replace_note | 无 | 完整title/content/attachments/labels+expected_revision、原子、no-op须新增 |
| patch_note | gao_note.update_note | revision、attachments、strict apply_patch、null/empty语义与errors须实现 |
| delete_note | gao_note.delete | A带expected_revision，返回deleted；G无revision且返回完整note |
| bulk_update_note_labels | gao_note.set_labels | G只一条id全量set；Aselector批量原子set/remove、matched/updated/unchanged |
| put_note_attachment | gao_note.put_attachment | A upsert/revision/note-scoped id；Gupdate-only/global id/update_content |
| get_note_attachment_content | gao_note.get_attachment_with_content | A UTF8/binary互斥representation与metadata平级；G总base64嵌套 |
| delete_note_attachment | gao_note.delete_attachment | expected_revision、absent semantics、返回deleted/revision |

## HTTP、authentication、resources 和 Org 边界

G 两个 server 模块存在，但只有 AdminServer 在 `apps/gsmlg_admin_web/lib/gsmlg/admin_web/application.ex:15` 启动并挂router；未发现 ReadOnlyPlug 的 router/start使用，不能声称公开readonly MCP已部署。G Auth `.../plugs/gao_note_mcp_auth.ex:14` 支持 Guardian bearer 或 x-gaonote-mcp-key/x-api-key，写操作 actor 必需（G `.../mcp/authorization.ex:7`）；A `crates/note-mcp/src/http.rs:6` 应用不处理 auth、前代理负责 access/TLS。建议保留本项目现有 auth，这是部署策略差异，不能照参考移除以求一致。

G Origin `.../plugs/verify_mcp_origin.ex:23` 无/空 Origin允许，配置+localhost4111 allowlist；A `.../http.rs:36` 所有 present Origin拒绝。应把此项作为部署策略决策，保证不能绕过现有安全边界。

G resources 是 note markdown、metadata、label-setting URI templates（G `.../mcp/resources.ex:58`）；A notes_only ServerCapabilities只tools（A `.../server.rs:1045`）。如果需要精确12工具兼容endpoint，应将既有扩展保持在旧endpoint，避免兼容工具inventory混入扩展。

A `/org/mcp` 40工具的清单可见 `crates/note-mcp/tests/org_inventory_test.rs:19`，是 workspace/document/work-items、assign/schedule、claim/heartbeat/release、progress/result、state transition、review/dependencies/note-links/events 等独立orchestration领域；`.../server.rs:784` separate registry。G没有此endpoint/registry。**是否本次包含Org API必须由用户/主计划明确**，不能把40工具当12 Note MCP的小修。这个范围问题不阻塞Note契约准备。

## Backplane upstream blocker：可复制最小证据

在 G执行（无需mix compile、application boot、DB或HTTP服务）：

```sh
elixir -pa _build/dev/lib/backplane_mcp_protocol/ebin -e 'alias Backplane.McpProtocol.Protocol.Registry; alias Backplane.McpProtocol.Server.Response; IO.inspect(Registry.supported_versions(), label: "supported_versions"); IO.inspect(Registry.negotiate("2026-07-28"), label: "negotiate_modern"); IO.inspect(Response.tool() |> Response.structured(%{"ok" => true}) |> Response.to_protocol(), label: "tool_wire_result")'
```

实际 exit0：supported_versions `["2025-11-25","2025-06-18","2025-03-26","2024-11-05"]`；negotiate_modern `{:error,:unsupported_version,[...]}`；tool_wire_result含 `content,isError,structuredContent`，无 `resultType`。源码 `deps/backplane_mcp_protocol/lib/backplane/mcp_protocol/protocol/registry.ex:20`、`.../server/response.ex:656`。

```sh
elixir -pa _build/dev/lib/backplane_mcp_protocol/ebin -e 'alias Backplane.McpProtocol.Server.Handlers; alias Backplane.McpProtocol.MCP.Error; case Handlers.handle(%{"jsonrpc" => "2.0", "id" => 1, "method" => "server/discover", "params" => %{}}, nil, nil) do {:error, error, _frame} -> IO.inspect(Error.build_json_rpc(error, 1), label: "discover_wire_error") end'
```

实际 exit0：`error.code=-32601`, `message="Method not found"`, `data.method="server/discover"`。源码 `.../server/handlers.ex:47` generic fallback。HTTP transport `.../server/transport/streamable_http.ex:85` declares2025-03-26/2025-06-18；Plug `.../streamable_http/plug.ex:336` 仍为每个无session请求auto-initialize session，`:236` 响应加session-id。这里不把“不能不发initialize调用旧tools”当bug，因为库确实auto-initialize，差异是仍创建session并且不实现2026合同。

参考 acceptance的确凿要求：A `crates/note-mcp/tests/org_transports_test.rs:630` request _meta；`:653` headers；`:704` discover、no session、resultType、ttlMs/cacheScope；`:759` header/name/version mismatch返回HTTP400 JSONRPC -32020、present Origin403。

## 准备修复的文件与 scoped gates

应用契约: `apps/gsmlg_gao_note/lib/gsmlg/gao_note/mcp/{tools,admin_server,readonly_server}.ex`，建议专门Agent Note兼容DTO，避免共用Presenter变化破坏现有UI。Domain: `.../note.ex`, `.../gao_note.ex`, `.../attachments.ex`，plus新revision migration、selector/parser/read-lines/strictpatch模块（由主计划收敛实际文件）。Endpoint: `apps/gsmlg_admin_web/lib/gsmlg/admin_web/router.ex`, `application.ex`, mcp plugs；依赖版本在apps mix.exs+mix.lock，只能等upstream修复发布后更新。

现有合同tests固化11工具：G `apps/gsmlg_gao_note/test/gsmlg/gao_note/mcp_test.exs:252`、`.../mcp/aggregate_contract_test.exs:31`、admin controller test`:76`。修复应补/更新兼容契约，并在保留legacy端点时继续维持旧tests。

已尝试 scoped Mix baseline，结果与障碍见本文前部；未运行参考 Cargo tests。实施修复时使用以下 scoped gates：

- `mix test apps/gsmlg_gao_note/test/gsmlg/gao_note/mcp_test.exs apps/gsmlg_gao_note/test/gsmlg/gao_note/mcp/ apps/gsmlg_gao_note/test/gsmlg/gao_note/mcp_label_filter_test.exs apps/gsmlg_gao_note/test/gsmlg/gao_note_test.exs`，新mutation/selector/patch tests加入同scope。
- `mix test apps/gsmlg_admin_web/test/gsmlg/admin_web/controllers/gao_note_mcp_controller_test.exs`，针对新兼容endpoint追加12工具snapshot和HTTP modern/legacy tests。
- Revision race测试要用相同expected_revision两个写者，最多一个成功；stale失败全量rollback；no-op revision unchanged；null/omitted/[]；CRLF/mixed endings/EOF字节保持；strict patch ambiguous/fuzzy/overlap/unanchored/file-level拒绝。
- 附件upsert新建、重复id异note、path-collision/change、binary/text、both内容同/不同、absent-delete、revision/refetch及旧附件UI回归。
- selectors AND/types/operators/exact encoded raw/invalid；list default10/max1000/zero；bulk matched/updated/unchanged+rollback+no-op；semantic_search scores/minimum_score通过真实共享检索路径，不可为ILIKE伪造score。
- Upstream修复后按A `org_transports_test.rs:704/:759` 验证modern discover/list/call metadata/headers/results/cache/no-session，legacy2025-06-18同时通过。无需在本次准备阶段执行Org40工具实现。
