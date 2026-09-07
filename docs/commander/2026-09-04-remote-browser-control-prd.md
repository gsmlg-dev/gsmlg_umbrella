# GSMLG Remote Browser Control Service PRD

- **Status:** Draft
- **Date:** 2026-09-04
- **Owner:** GSMLG Service
- **Target repository:** `gsmlg-dev/gsmlg_umbrella`
- **Product:** Remote Browser Control Service
- **Initial backend:** CloakBrowser Manager
- **Initial target:** Gemini Web

## 1. Product Overview

Remote Browser Control Service 为 GSMLG 提供一套可通过 API 和 Admin UI 操作的远程持久化浏览器能力。

浏览器运行在远端 NixOS 主机，远端 Commander 主动连接中央 Admin 服务。Browser Agent 在远端本地连接 CloakBrowser Manager 和 CDP，中央通过 Commander Capability RPC 管理 Browser Node、Profile、Session、Action、Workflow、Job、Event 和 Artifact。

产品支持两种使用方式：

1. **Generic Browser Control**：调用方逐步创建 Session、观察页面和执行受限 Action；
2. **Remote Workflow**：在远端持续执行可恢复的长任务，例如 Gemini Deep Research 和 YouTube 内容分析。

```text
Caller
  → Browser Control API
  → Commander Capability RPC
  → Remote Browser Agent
  → CloakBrowser Manager
  → Target Web Application
```

---

## 2. Problem Statement

当前 GSMLG Commander 可以远程控制 PTY，但不能作为可靠的 Browser Worker：

1. Commander Feature 和 Channel 仍然以 PTY 为中心；
2. 没有 Browser Capability 发现和版本协商；
3. 没有远程 Profile、Session、Lease 和 Action 模型；
4. 没有 Request ID、ACK、Event Sequence 和断线恢复；
5. 不能保证非幂等 Browser Action 不被重复执行；
6. 中心直接连接远端 CDP 会暴露 Profile 和控制接口；
7. 长时间 Research 会因中央或网络重启而中断；
8. 缺少人工登录、2FA、CAPTCHA 和未知页面接管流程；
9. 缺少通用 Result/Artifact 输出；
10. 生产 Admin Endpoint 升级后，Commander 还需要支持可配置 mTLS Client Certificate。

---

## 3. Product Vision

将 Commander 从“远程 Shell 客户端”演进为“远程 Capability Host”，并以 Browser Control 作为第一项长任务 Capability：

```text
Commander
  ├── PTY Capability
  ├── Browser Control Capability
  └── future capabilities
```

调用方只面对稳定的 Browser API，不需要知道 Browser Host 的网络、Manager Token、CDP URL、Profile 目录或浏览器内部实现。

---

## 4. Goals

### G-001: Remote browser nodes

系统能够发现、查询和选择带 Browser Capability 的 Commander 节点。

### G-002: Persistent profile control

系统能够安全管理远端持久化 Browser Profile 的状态和独占使用权。

### G-003: Generic session control

调用方能够打开 Browser Session、取得语义 Observation、执行结构化 Action 并关闭 Session。

### G-004: Durable workflows

系统能够在远端执行长时间 Workflow，Commander 或中心短暂断线不会终止任务。

### G-005: Gemini automation

第一阶段支持 Gemini Deep Research 和 YouTube 内容分析。

### G-006: Human intervention

登录、2FA、Passkey、CAPTCHA 和未知 UI 能暂停并交给人工处理，然后恢复任务。

### G-007: Reliable results

系统以通用 Job Result 和 Artifact 形式提供 Markdown、JSON、HTML、来源、截图和下载文件。

### G-008: Secure control surface

系统不暴露 Raw CDP、任意 JavaScript、Cookie、Local Storage、Manager Token 或 Profile 文件。

### G-009: Production transport security

Commander 支持使用 WSS 和可配置 mTLS Client Certificate 连接中央服务，同时保留 Commander 应用认证和 Capability 授权。

### G-010: Operational visibility

管理员可以查看 Node、Manager、Profile、Session、Job、Intervention、Artifact 和 Transport 状态。

---

## 5. Non-goals

- 通用桌面控制；
- 无限制的 Computer Use Agent；
- CAPTCHA 自动破解；
- 自动输入密码、Passkey、2FA 或恢复码；
- Cookie/Storage 导出；
- Raw CDP 或任意 JavaScript API；
- 第一版转发 KasmVNC 视频流；
- 第一版支持账号池和代理轮换；
- 第一版大规模并发 Browser Farm；
- 在本产品内定义结果的外部业务消费流程；
- 替代官方 Gemini API 的所有场景。

---

## 6. Target Users

### 6.1 AI/Automation caller

通过 API 创建 Session 或 Workflow，读取 Observation、Event 和 Artifact。

### 6.2 GSMLG operator

通过 Admin UI 管理 Browser Node、Profile、任务和人工接管。

### 6.3 Infrastructure administrator

部署 Commander、Browser Agent、CloakBrowser Manager、Runtime Secret 和 mTLS Credential。

### 6.4 GSMLG developer

扩展 Browser Backend、Action、Workflow 和 Commander Capability。

---

## 7. Primary Use Cases

### UC-001: Inspect a remote browser profile

管理员查看远端 CloakBrowser Manager 是否在线、Profile 是否运行以及是否可用于自动化。

### UC-002: Generic observe/action session

调用方创建 Session，导航到允许的页面，读取语义页面状态，点击控件、输入文本并提取内容。

### UC-003: Run Gemini Deep Research

调用方提交 Research Prompt，远端 Workflow 完成计划批准、研究等待、报告提取和 Artifact 生成。

### UC-004: Analyze a YouTube video

调用方提交公开视频 URL 和分析配置，Workflow 生成摘要、时间线、论点、证据、行动项和不确定内容。

### UC-005: Handle human-only authentication

任务检测到登录或验证页面，进入 Waiting Human；管理员处理后恢复任务。

### UC-006: Recover after disconnection

Commander 与中心断线期间，远端 Workflow 继续执行；重连后续传 Event 和 Result。

### UC-007: Rotate Commander client certificate

基础设施更新 mTLS Client Certificate，Commander 重连，但正在运行的 Browser Workflow 不被终止。

---

## 8. User Stories

### Browser node and profile

**US-001** 作为 Operator，我可以看到哪些 Commander 提供 Browser Control Capability。

**US-002** 作为 Operator，我可以查看 Node 的 Backend、版本、并发、健康和最近错误。

**US-003** 作为 Operator，我可以同步远端 Profile，但看不到 Cookie、Proxy Password、CDP URL 或 Profile Path。

**US-004** 作为 Operator，我可以启动或停止一个未被租用的 Profile。

### Session control

**US-005** 作为调用方，我可以创建绑定某个 Profile 的 Browser Session。

**US-006** 作为调用方，我可以获得包含 URL、Title、Controls 和 Accessibility Tree 的 Observation。

**US-007** 作为调用方，我可以使用 Observation 返回的 Node ID 或语义 Locator 执行 Action。

**US-008** 作为调用方，当页面已经变化时，我希望旧 Revision 的 Action 被拒绝，而不是错误点击。

**US-009** 作为调用方，我可以安全关闭 Session 并释放 Profile Lease。

### Workflow

**US-010** 作为调用方，我可以启动版本化的 Deep Research Workflow。

**US-011** 作为调用方，我可以持续读取 Workflow Phase 和 Event。

**US-012** 作为调用方，我可以取消、重试、恢复或主动 Reconcile Job。

**US-013** 作为调用方，我希望重复提交相同 Idempotency Key 时返回原 Job，而不是执行两次。

### Human intervention

**US-014** 作为 Operator，我可以看到任务需要人工处理的明确原因。

**US-015** 作为 Operator，我可以取得 Profile 的 Manual Lease，处理页面后释放并恢复 Workflow。

### Results and artifacts

**US-016** 作为调用方，我可以取得 Result Manifest 和 Artifact 列表。

**US-017** 作为调用方，我可以校验 Artifact 的 Size 和 SHA-256。

**US-018** 作为调用方，我可以下载 Markdown、JSON、Sources、Screenshot 或其他文件。

### Transport

**US-019** 作为基础设施管理员，我可以为 Commander 配置 mTLS Client Certificate 和 Private Key。

**US-020** 作为 Operator，我可以看到脱敏后的 Commander TLS 状态和证书剩余有效期。

---

## 9. Functional Requirements

### 9.1 Commander capability foundation

**FR-001** 系统必须定义版本化的 Commander Capability Descriptor。

**FR-002** Commander 必须通过通用 Control Channel 注册、发送心跳和上报 Capability。

**FR-003** Browser Agent 必须注册 `browser.control/v1`。

**FR-004** Capability Descriptor 必须包含 Backend、Operations、Limits 和 Supported Workflows。

**FR-005** 中央必须拒绝不兼容的 Protocol 或 Capability Version。

**FR-006** 每个 RPC Request 必须包含唯一 Request ID。

**FR-007** 长操作必须返回 Accepted 和 Remote Execution ID。

**FR-008** Request、Cancel、Resume 和 Reconcile 必须是幂等的。

**FR-009** Job Event 必须包含单调递增 Sequence。

**FR-010** 中央必须对 Event 去重并发送 ACK。

### 9.2 Browser node management

**FR-011** 系统必须列出具备 Browser Capability 的在线和已配置 Node。

**FR-012** Node 状态必须至少包含 Online、Degraded、Offline 和 Disabled。

**FR-013** Node 必须报告 Browser Agent、Backend 和 Browser Binary Version。

**FR-014** Node 必须报告最大 Profile、Session 和 Workflow 并发。

**FR-015** 中央必须支持设置 Default Browser Node。

**FR-016** 中央不得将实时在线状态仅依赖数据库；Commander Registry 是实时来源。

### 9.3 Profile management

**FR-017** Browser Agent 必须从 Backend 列出 Profile。

**FR-018** 中央必须只保存脱敏 Profile Metadata。

**FR-019** 中央必须支持 Profile Sync。

**FR-020** 系统必须支持 Profile Status、Launch 和 Stop。

**FR-021** 被有效 Lease 占用的 Profile 不得被直接 Stop。

**FR-022** Profile 必须支持 Enabled、Default 和 Origin Policy。

**FR-023** 同一 Profile 同时最多持有一个 Active Lease。

**FR-024** Automation Lease 和 Manual Lease 必须互斥。

### 9.4 Browser sessions

**FR-025** 调用方必须能够创建 Browser Session。

**FR-026** Session 创建必须选择 Node、Profile、Mode 和 Origin Policy。

**FR-027** Session 必须有 Central ID、Remote ID、Lease ID 和 Revision。

**FR-028** Session 状态至少包括 Opening、Ready、Acting、Waiting Human、Closing、Closed、Orphaned 和 Failed。

**FR-029** Session 必须支持显式关闭。

**FR-030** Session 超时必须触发 Reconcile，不能直接假设远端已关闭。

### 9.5 Observation

**FR-031** 系统必须提供结构化页面 Observation。

**FR-032** Observation 必须至少包含 URL、Origin、Title、Loading State、Page Kind、Alerts 和 Visible Controls。

**FR-033** Observation 必须支持受限 Accessibility/Semantic Tree。

**FR-034** Observation 必须有单调递增 Revision。

**FR-035** Password 和其他敏感输入值必须始终 Redact。

**FR-036** Observation 必须限制节点数、深度和总字节数。

**FR-037** 调用方可以请求 Screenshot，但必须受权限和大小限制。

### 9.6 Structured actions

**FR-038** 第一版必须支持 Navigate、Click、Focus、Fill、Insert Text、Press Key、Select、Scroll、Wait、Extract、Screenshot 和 Download。

**FR-039** Action 必须包含唯一 Action ID。

**FR-040** Action 可以指定 Expected Revision。

**FR-041** Revision 不匹配时必须返回 `stale_observation`。

**FR-042** Action 必须支持语义 Locator 和 Observation Node ID。

**FR-043** Raw CDP Method 不得成为公共 API。

**FR-044** 任意 JavaScript Evaluation 不得成为公共 API。

**FR-045** Action 执行前必须验证 Profile Lease。

**FR-046** 非幂等 Action 必须在执行前写入 Pending Action Journal。

**FR-047** Action 完成必须通过 Postcondition 或重新 Observation 确认。

**FR-048** 无法判断执行结果时必须返回 `action_outcome_unknown`，不能自动重复。

### 9.7 Origin and navigation policy

**FR-049** 每个 Profile 或 Session 必须有 Allowed Origin Policy。

**FR-050** Navigate 必须拒绝未允许的 Scheme 和 Origin。

**FR-051** Redirect 后必须重新检查 Origin。

**FR-052** `javascript:`、`data:`、`file:` 和本地网络地址默认禁止。

**FR-053** 未知 Origin 必须暂停或失败，不能静默继续。

### 9.8 Durable workflows

**FR-054** 系统必须支持版本化 Workflow。

**FR-055** Workflow 必须在 Browser Agent 远端运行。

**FR-056** Workflow 每个状态转换后必须写 Checkpoint。

**FR-057** Commander 断线时 Workflow 必须继续运行。

**FR-058** 重连后 Browser Agent 必须续传未确认 Event。

**FR-059** 中央重启后必须能够 Reconcile Running Workflow。

**FR-060** Workflow 必须支持 Cancel、Resume 和 Deadline。

**FR-061** 相同 Idempotency Key 不得创建重复 Active Execution。

### 9.9 Gemini Deep Research

**FR-062** 系统必须提供 `gemini.deep_research/v1`。

**FR-063** Workflow 必须支持 Prompt、Output Locale、Required Sections 和 Auto Approve Plan。

**FR-064** Workflow 必须识别 Login、Plan、Researching、Report、Quota 和 Error 状态。

**FR-065** Prompt Submit 必须使用 Pending Action 和 Postcondition 防止重复提交。

**FR-066** Report 必须在正文 Hash 稳定后才可提取。

**FR-067** Workflow 必须输出 Markdown、Structured JSON 和 Sources Artifact。

### 9.10 YouTube analysis

**FR-068** 系统必须提供 `gemini.youtube_analysis/v1`。

**FR-069** Workflow 必须支持 Summary、Technical Review、Timeline、Fact Check 和 Action Items Profile。

**FR-070** Workflow 必须识别视频不可用、年龄限制、地区限制和 Gemini 无法访问视频。

**FR-071** 如果结果明显只基于标题或描述，Workflow 不得标记为完整成功。

**FR-072** 输出必须可包含时间戳、核心论点、证据、行动项和不确定内容。

### 9.11 Human intervention

**FR-073** 系统必须支持 `waiting_human` 状态。

**FR-074** Intervention 必须包含稳定 Reason Code 和操作说明。

**FR-075** 人工接管前必须将 Automation Lease 转换为 Manual Lease。

**FR-076** Manual Lease 生效期间自动化 Action 必须被拒绝。

**FR-077** Resume 后必须重新获取 Observation，不能直接执行旧 Action。

**FR-078** 第一版可以通过 SSH Tunnel + Backend WebVNC 完成人工接管。

### 9.12 Job events and artifacts

**FR-079** 中央必须持久化 Browser Job 和 Event。

**FR-080** Job 状态至少包括 Queued、Dispatching、Accepted、Running、Waiting Human、Collecting Artifacts、Completed、Failed 和 Cancelled。

**FR-081** 系统必须返回通用 Result Manifest。

**FR-082** Artifact 必须包含 Kind、MIME、Filename、Size 和 SHA-256。

**FR-083** 小型 Artifact 可以 Inline 传输。

**FR-084** 大型 Artifact 必须使用独立上传流程。

**FR-085** 中央确认 Artifact 前，远端不得删除 Result Outbox。

**FR-086** 调用方必须可以查询和下载 Job Artifact。

### 9.13 Admin Web

**FR-087** Admin Web 必须提供 Browser Dashboard。

**FR-088** Admin Web 必须提供 Node、Profile、Session、Job 和 Artifact 页面。

**FR-089** Commander 详情页在支持 Browser Capability 时必须显示 Browser Tab。

**FR-090** Job Detail 必须显示 Event Timeline、当前 Phase、Intervention 和 Artifact。

**FR-091** Admin UI 必须支持 Cancel、Retry、Resume 和 Reconcile。

### 9.14 Commander mTLS transport

**FR-092** Commander 必须支持配置 Client Certificate Chain 和 Private Key。

**FR-093** mTLS 启用时连接 URL 必须为 `wss://`。

**FR-094** Commander 必须验证服务端证书和主机名。

**FR-095** Certificate 和 Key 必须在连接前验证有效性和匹配关系。

**FR-096** mTLS 失败时不得回退到无证书连接或 `ws://`。

**FR-097** mTLS 不能替代 Commander 应用身份和 Capability 授权。

**FR-098** Certificate Rotation 可以重建 Commander Connection，但不得终止 Browser Workflow。

### 9.15 Configuration and secrets

**FR-099** Central Browser 和 Remote Browser Agent 必须通过统一 TOML Schema 配置。

**FR-100** Manager Token、Commander Credential、Client Private Key 不得写入 Git 或 TOML 正文。

**FR-101** Runtime Secret 必须通过文件、Environment 或 Systemd Credential 注入。

**FR-102** 无效配置必须 Fail Closed。

---

## 10. Non-functional Requirements

### Reliability

**NFR-001** Browser Workflow 在 Commander 连接中断 30 分钟内仍应继续本地执行。

**NFR-002** Event 和 Final Result 必须采用至少一次投递与去重。

**NFR-003** Central、Commander、Browser Agent 或 Manager 重启后必须存在明确 Reconcile 路径。

**NFR-004** 非幂等 Action 不得因自动 Retry 被重复执行。

### Performance

**NFR-005** 在线 Node/Profile 状态查询目标 P95 小于 2 秒。

**NFR-006** Session Observe 目标 P95 小于 3 秒，不包含页面自身加载时间。

**NFR-007** 普通 Action Dispatch 目标 P95 小于 2 秒，不包含 Postcondition 等待时间。

**NFR-008** Observation 默认最大 1 MiB。

### Security

**NFR-009** 中央数据库不得包含 Browser Cookie、Local Storage、Manager Token、Proxy Password、CDP URL 或 Profile Path。

**NFR-010** 公共 API 不得提供 Raw CDP、任意 JavaScript 或 Cookie/Storage Read。

**NFR-011** Prompt、页面正文和 Artifact 内容不得进入普通日志。

**NFR-012** 所有 Navigation 必须经过 Origin Policy。

**NFR-013** 生产 Commander Connection 必须支持 mTLS，并始终验证服务端证书。

### Maintainability

**NFR-014** Browser Backend 必须通过 Behaviour 隔离。

**NFR-015** Site UI Contract 和 Workflow 必须独立版本化。

**NFR-016** Workflow Transition 必须尽量保持纯函数并可使用 Fixture 测试。

**NFR-017** Commander Protocol 必须有向后兼容和版本拒绝测试。

### Observability

**NFR-018** 每个 Job、Session、Action 和 RPC 都必须有 Correlation ID。

**NFR-019** 系统必须提供 Phase Duration、Failure Code、Intervention 和 Reconcile 指标。

**NFR-020** TLS、Manager、CDP 和 UI Contract 错误必须使用稳定错误码。

---

## 11. API Requirements

### 11.1 Create generic session

```text
POST /api/browser/sessions
```

输入概念：

```text
node
profile
mode
authorized_origins
ttl
```

返回：

```text
session_id
status
revision
expires_at
```

### 11.2 Observe session

```text
POST /api/browser/sessions/:id/observe
```

返回：

```text
revision
url
title
page_kind
visible_controls
semantic_tree
alerts
```

### 11.3 Execute action

```text
POST /api/browser/sessions/:id/actions
```

输入：

```text
action_id
expected_revision
type
locator
input
postcondition
timeout_ms
```

### 11.4 Start workflow

```text
POST /api/browser/jobs
```

输入：

```text
workflow
workflow_version
node optional
profile optional
input
idempotency_key
output_formats
```

### 11.5 Query workflow

```text
GET /api/browser/jobs/:id
GET /api/browser/jobs/:id/events
GET /api/browser/jobs/:id/artifacts
```

### 11.6 Control workflow

```text
POST /api/browser/jobs/:id/cancel
POST /api/browser/jobs/:id/retry
POST /api/browser/jobs/:id/resume
POST /api/browser/jobs/:id/reconcile
```

---

## 12. State Models

### 12.1 Session

```text
opening
→ ready
→ acting / waiting
→ waiting_human
→ ready
→ closing
→ closed
```

异常：

```text
orphaned
failed
```

### 12.2 Job

```text
queued
→ dispatching
→ accepted
→ running
→ collecting_artifacts
→ completed
```

分支：

```text
running → waiting_human → running
running → failed
running → cancelled
accepted/running → reconcile
```

### 12.3 Remote action

```text
received
→ journaled
→ validating
→ executing
→ verifying
→ completed
```

异常：

```text
rejected
failed
outcome_unknown
```

---

## 13. Data Requirements

### Central durable entities

```text
BrowserNode
BrowserProfile
BrowserSession
BrowserJob
BrowserJobEvent
BrowserArtifact
```

### Remote durable entities

```text
ProfileLease
SessionJournal
JobCheckpoint
PendingAction
RequestDedupEntry
UnackedEvent
ArtifactOutboxEntry
```

### Data minimization

中央只保存控制和结果元数据。Profile 身份和浏览器凭证只存于远端 Backend Volume。

---

## 14. UX Requirements

### Browser dashboard

必须显示：

- Node Online/Offline/Degraded；
-Backend 和 Manager 状态；
-Profile Available/Busy/Manual；
-Active Session；
-Running/Waiting Human/Failed Job；
-最近错误；
-Commander Transport/TLS 摘要。

### Job detail

必须显示：

- Workflow 与版本；
-Node 与 Profile；
-当前 Phase；
-Event Timeline；
-Intervention；
-Result Summary；
-Artifact；
-Cancel、Retry、Resume、Reconcile。

### Manual intervention

必须显示：

-Reason Code；
-当前 Profile；
-操作说明；
-SSH Tunnel 模板；
-Manual Lease 状态；
-Resume 按钮。

---

## 15. Security Requirements

**SR-001** Browser Profile Credential 必须只存在远端。

**SR-002** Browser Manager 只能绑定远端 Loopback 或受控容器网络。

**SR-003** Profile 必须有独占 Lease。

**SR-004** Origin Policy 默认拒绝。

**SR-005** 不允许 Raw CDP 和任意 JavaScript 公共接口。

**SR-006** 不允许 Cookie、Storage 和 Password Field Read。

**SR-007** 人工认证信息不得由 Workflow 记录或回传。

**SR-008** Commander RPC 必须经过应用身份和 Capability 授权。

**SR-009** 生产 Commander 应支持 mTLS Client Certificate。

**SR-010** TLS 和 RPC Credential 不得进入 Telemetry。

**SR-011** Artifact Upload 必须短期有效、绑定 Job 且校验 SHA-256。

**SR-012** Admin UI 的 Raw Chat URL、Screenshot 和 Artifact 必须遵循现有授权边界。

---

## 16. Success Metrics

上线后评估：

- Browser Node 日可用率 ≥ 99%；
- Generic Action 已知结果率 ≥ 99%，`outcome_unknown` < 1%；
- Deep Research 无人工干预成功率 ≥ 90%；
- Commander 短暂断线后的 Workflow 恢复率 ≥ 99%；
- Central Restart 后 Running Job Reconcile 成功率 ≥ 99%；
-重复 Prompt Submit 事件为 0；
-重复 Job Result 为 0；
-Artifact 完整性校验失败率 < 0.1%；
-敏感数据日志泄漏测试 100% 通过。

这些指标是第一阶段工程目标，不构成第三方 Web 服务可用性保证。

---

## 17. Milestones

### M0: Commander Capability RPC and transport

交付：

- 通用 Control Channel；
-Capability Registry；
-Protocol Application；
-Request/Accepted/Response/Event/ACK；
-Idempotency 和 Reconnect；
-mTLS Client Transport；
-日志脱敏。

### M1: Browser Agent and profile management

交付：

- Browser Agent Application；
-CloakBrowser Adapter；
-Manager Health；
-Profile Sync/Status/Launch/Stop；
-Local Journal；
-Profile Lease。

### M2: Generic browser sessions

交付：

-Session Open/Observe/Act/Close；
-CDP Safe Layer；
-Semantic Observation；
-Structured Action；
-Revision/Postcondition；
-Origin Policy。

### M3: Central jobs, events, artifacts and UI

交付：

- Browser Ecto Models；
-Oban Scheduler/Reconciler；
-Event Store；
-Artifact Transfer；
-REST API；
-Admin UI。

### M4: Gemini workflows

交付：

-Deep Research；
-YouTube Analysis；
-UI Contract；
-Result Extraction；
-Human Intervention；
-真实 E2E。

### M5: Small-model policy and hardening

交付：

-受约束模型决策；
-故障注入；
-证书轮换连续性；
-安全审计；
-性能和容量验证。

---

## 18. Acceptance Scenarios

### AS-001: Node discovery

远端 Browser Agent 连接后，中央在 10 秒内显示 `browser.control/v1`、Backend 和 Limits。

### AS-002: Profile confidentiality

Profile Sync 响应和数据库中不存在 Cookie、Proxy Password、Fingerprint Seed、CDP URL 或 User Data Path。

### AS-003: Generic action

调用方打开 Session，Observe 页面，通过返回的 Node ID 点击按钮，并获得 Revision 增长后的 Observation。

### AS-004: Stale action prevention

页面发生变化后，旧 Revision Action 返回 `stale_observation`，不执行点击。

### AS-005: Exclusive lease

两个调用方同时申请同一 Profile，只有一个成功，另一个返回 `profile_busy`。

### AS-006: Deep Research continuity

Researching 期间断开 Commander Connection，Browser Agent 继续执行；重连后中央收到缺失 Event 和 Final Result。

### AS-007: Duplicate request

同一 Idempotency Key 重发 `workflow.start`，返回相同 Remote Execution，不创建第二次 Research。

### AS-008: Crash after submit

Prompt Submit 后 Browser Agent Runner 崩溃，恢复时根据 Pending Action 和页面状态确认已提交，不重复发送。

### AS-009: Human login

检测到 Login/2FA/CAPTCHA 后进入 Waiting Human，自动化停止；Manual Lease 释放后 Resume 成功。

### AS-010: Artifact integrity

中央取得 Markdown 和 Sources Artifact，Size 与 SHA-256 校验通过。

### AS-011: mTLS connection

Commander 使用受信任 Client Certificate 建立 WSS；无证书或不受信任证书在 TLS Handshake 阶段失败。

### AS-012: Certificate rotation

替换 Commander Certificate 后连接重建，远端 Running Workflow 不被终止。

### AS-013: Sensitive log protection

完整测试日志中不存在 Prompt 正文、Cookie、Manager Token、Private Key、Certificate PEM 和完整 RPC Payload。

---

## 19. Dependencies

- Commander Control Channel 重构；
- `phoenix_socket_client` SSL Options 和安全 Telemetry；
- PostgreSQL / Ecto；
- Oban；
- Phoenix PubSub；
-通用 Storage 或签名上传能力；
-CloakBrowser Manager；
-Erlang/OTP SSL；
-NixOS Runtime Secret；
-Caddy mTLS Endpoint。

---

## 20. Risks and Mitigations

| Risk | Mitigation |
|---|---|
| Gemini UI 频繁变化 | Versioned UI Contract、Fixtures、Waiting Human |
| Commander 断线 | Remote Workflow、Journal、Event Outbox |
| 非幂等 Action 重复 | Action ID、Pending Action、Postcondition、Reconcile |
| Profile 同时操作 | Remote authoritative Lease |
| Manager API 变化 | Backend Adapter 与 Capability Probe |
| 大 Artifact 压垮 Channel | Signed Upload，Control/Artifact 分离 |
| 小模型误操作 | Allowed Actions、Revision、Origin Policy、No Raw JS |
| TLS 证书轮换中断 | Connection 与 Job Supervisor 隔离 |
| 敏感数据进入日志 | Metadata Allowlist、Payload Redaction、Leak Tests |
| 第三方账号风控 | 低并发、固定 Profile、Human Intervention、无自动绕过 |

---

## 21. Definition of Done

产品第一版完成必须满足：

1. Commander Capability RPC 可稳定承载 Browser Control；
2. Remote Browser Agent 可连接 CloakBrowser Manager；
3. Node、Profile、Session、Job、Event、Artifact API 完整；
4. Generic Observe/Act Session 可用；
5. Profile Lease 和 Action Revision 生效；
6. Deep Research 和 YouTube Analysis 可运行；
7. Commander/Central 断线恢复通过；
8. Human Intervention 和 Resume 可用；
9. Artifact 可校验和下载；
10. Commander mTLS Client Connection 可配置；
11. Admin UI 提供完整运行视图；
12. 安全和敏感日志测试通过；
13. 真实 NixOS + Podman + CloakBrowser E2E 通过；
14. 设计、配置、部署和故障处理文档完成。

---

## 22. Recommended Repository Documents

```text
docs/superpowers/specs/2026-09-04-remote-browser-control-design.md
docs/superpowers/specs/2026-09-04-remote-browser-control-prd.md
```

Remote Browser Control 是主产品范围；Commander mTLS 作为 Transport Security 子能力在同一项目中实现。
