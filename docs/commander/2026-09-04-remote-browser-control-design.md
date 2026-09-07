# GSMLG Remote Browser Control Service Design

- **Status:** Proposed
- **Date:** 2026-09-04
- **Target repository:** `gsmlg-dev/gsmlg_umbrella`
- **Primary applications:** `gsmlg_commander`, `gsmlg_browser`, `gsmlg_browser_agent`, `gsmlg_admin_web`
- **Initial browser backend:** CloakBrowser Manager
- **Initial workflows:** Gemini Deep Research、YouTube 内容分析

## 1. Executive Summary

本项目在 `gsmlg_umbrella` 中增加一套通过 Commander 远程调度的 Browser Control Service。

系统不把 CloakBrowser Manager 或 CDP 直接暴露给中心服务，而是在浏览器宿主机上运行 `gsmlg_browser_agent`。中心的 `gsmlg_browser` 通过 Commander 的反向 WebSocket 连接发现 Browser Capability、创建远程浏览器 Session、执行结构化浏览器动作、启动长时间 Workflow，并取得结果与 Artifact。

```text
External Consumer / Admin UI
              │
              ▼
       GSMLG.Browser API
              │
              ▼
      Commander Capability RPC
              │  WSS（生产环境支持 mTLS）
              ▼
      Remote Browser Agent
              │  localhost REST / CDP
              ▼
      CloakBrowser Manager
              │
              ▼
          Gemini Web
```

核心设计决策：

1. **Commander 是远程连接与 Capability Bus，不承载浏览器领域逻辑。**
2. **Browser Agent 与 CloakBrowser Manager 同机部署。** Google Profile、Cookie、Manager Token、CDP URL 均保留在远端。
3. **通用 Browser Control 与站点 Workflow 分层。** Session/Observe/Action 是基础能力，Gemini Deep Research 是其上的版本化 Workflow。
4. **长任务在远端持续执行。** Commander 或中心短暂断线不能终止 Research，也不能导致重复提交。
5. **浏览器动作结构化并受限。** 对外不提供 Raw CDP、任意 JavaScript、Cookie 导出或任意本机 Shell。
6. **Profile 使用独占 Lease。** 自动化和人工接管不能同时操作同一 Profile。
7. **mTLS 是 Commander Transport 的安全能力之一，不是 Browser Control 的主体。**
8. **服务只产生通用 Job、Event、Result 与 Artifact。** 后续消费由调用方决定。

---

## 2. Context and Current Repository Assessment

本设计基于 `gsmlg_umbrella` 当前 Commander 架构。

### 2.1 Existing strengths

仓库已经提供：

- 独立的 `gsmlg_commander` release；
- 远端主动连接中心的 Phoenix Socket Client；
- `/commander-socket/websocket`；
- Agent 注册、心跳与在线 Registry；
- PTY 的双向消息与管理 UI；
- PostgreSQL、Oban、PubSub、Finch 和统一配置系统；
- Admin Web 的统一导航与 LiveView 管理界面；
- WebSocket Client 底层 SSL Options 透传能力。

这些基础设施适合演进为通用远程 Capability 平台。

### 2.2 Existing gaps

当前 Commander 仍是 PTY-specific：

- `GSMLG.Commander` 只识别 `:pty` Feature；
- `GSMLG.Commander.Terminal` 同时承担连接、注册、心跳和 PTY 数据面；
- 注册的 Capability 固定为 `pty/shell/resize`；
- `commander:<name>` Channel 基本没有通用控制能力；
- `AgentRegistry.send_to_agent/2` 是 fire-and-forget，没有 Request ID、ACK、Timeout、Event Sequence 和恢复语义；
- 现有 Protocol 主要围绕 PTY Frame；
- 当前存在多套未完全收敛的 Commander Channel、Session 和 Registry 路径。

因此不能直接把 Browser 消息添加到 `Terminal`。应先把 Commander 抽象为 Capability RPC，再接入 Browser Control。

### 2.3 Why not direct central CDP

不采用：

```text
Central GSMLG → SSH/Port Forward → Remote CDP
```

原因：

- CDP URL 和浏览器凭证跨越远端安全边界；
- 网络断开后无法可靠判断非幂等动作是否已经执行；
- 中心升级或重启会中断长时间 Workflow；
- Profile 独占、人工接管和本地恢复更难实现；
- 需要暴露或转发远端 Loopback 服务。

### 2.4 Why not PTY scripts

不采用：

```text
Central GSMLG → Commander PTY → curl/node/python script → Browser
```

PTY 只适合诊断和人工运维，不具备稳定的类型、幂等、事件、恢复和授权模型。Browser Control 必须是 Commander 的一等 Capability。

---

## 3. Goals

### 3.1 Product goals

- 将多台远端 Commander 作为 Browser Worker 节点管理；
- 发现每个节点的 Browser Backend、Profile、版本、并发和健康状态；
- 提供远程 Browser Session 生命周期；
- 提供结构化 Observe/Action API；
- 支持可恢复的长时间 Browser Workflow；
- 第一阶段实现 Gemini Deep Research 与 YouTube 内容分析；
- 支持人工登录、2FA、CAPTCHA 和未知页面接管；
- 提供结果、来源、结构化数据、截图和下载文件等 Artifact；
- 支持中心、Commander 和 Browser Agent 断线后的自动 Reconcile；
- 提供 Admin UI、REST API、Telemetry 和审计事件。

### 3.2 Architecture goals

- Functional Core / Imperative Shell；
- Commander、Browser Service、Browser Agent、Browser Backend 边界清晰；
- Browser Workflow 与具体 Manager/CDP 实现解耦；
- 所有非幂等 Action 有 Action ID、Expected Revision 和执行确认；
- Profile Lease 在远端权威执行，中心保留镜像状态；
- Artifact Transport 与 Commander Control Message 分离；
- Browser Profile 中的敏感状态永不进入中央数据库。

### 3.3 Security goals

- 不暴露 Raw CDP、Cookie、Local Storage、Profile 目录和任意 JavaScript；
- 每个 Profile 配置允许访问的 Origin Policy；
- 自动化、人工控制和 Workflow 共享统一的独占 Lease；
- Commander 连接保持应用认证，并在生产环境支持 mTLS Client Certificate；
- Prompt、页面正文和 Artifact 不进入普通日志；
- Browser Manager Token 只存在远端 Runtime Secret；
- 对所有输入 URL、Locator、Action 和 Artifact 做限制与验证。

---

## 4. Non-goals

第一版不包括：

- 通用桌面自动化；
- 任意站点的全自主 Computer Use；
- 对外暴露原始 CDP WebSocket；
- 任意 JavaScript Evaluation；
- Cookie、IndexedDB、Local Storage 或密码导出；
- CAPTCHA 自动破解；
- 自动输入 Google 密码、Passkey、2FA 或恢复码；
- 通过 Commander 转发完整 KasmVNC 视频流；
- 大规模账号池、代理轮换或规避服务使用限制；
- Browser Profile 文件的中央备份；
- 在本项目中定义 Artifact 的外部业务消费流程；
- 第一版支持多个 Profile 并发运行。

---

## 5. Terminology

| Term | Definition |
|---|---|
| **Browser Node** | 上报 `browser.control` Capability 的 Commander 节点 |
| **Backend** | 实际浏览器运行时实现；第一版为 CloakBrowser Manager |
| **Profile** | 远端持久化浏览器身份、Cookie、指纹和历史记录 |
| **Lease** | Profile 的独占控制权，类型为 automation 或 manual |
| **Session** | 绑定 Node、Profile 和 Lease 的一次可控浏览器会话 |
| **Observation** | 对页面状态的结构化、只读语义快照 |
| **Action** | 一个受限且可确认的浏览器副作用 |
| **Workflow** | 在远端连续执行的一组 Observation/Decision/Action 状态转换 |
| **Job** | 中心持久化的异步任务，可以是 Workflow 或单次控制任务 |
| **Artifact** | Job 产生的 Markdown、JSON、HTML、截图或下载文件 |
| **Intervention** | 需要人工登录、验证或处理未知 UI 的暂停状态 |

---

## 6. Top-level Architecture

```text
┌────────────────────────────────────────────────────────────────────┐
│ Central GSMLG                                                     │
│                                                                    │
│  gsmlg_admin_web                                                  │
│  ├── Browser Dashboard                                            │
│  ├── Nodes / Profiles / Sessions / Jobs                           │
│  └── Manual Intervention UI                                       │
│                                                                    │
│  gsmlg_browser                                                    │
│  ├── Public Context API                                           │
│  ├── Job Store / Scheduler                                        │
│  ├── Session Directory                                            │
│  ├── Commander Bridge                                             │
│  ├── Event Reconciler                                             │
│  ├── Artifact Registry                                            │
│  └── Policy                                                       │
│                                                                    │
│  Commander Control Plane                                          │
│  ├── Agent Registry                                               │
│  ├── Capability Directory                                         │
│  ├── RPC Dispatcher                                               │
│  └── Pending Request Registry                                     │
└───────────────────────────────┬────────────────────────────────────┘
                                │
                                │ Phoenix Channel / Commander RPC
                                │ WSS; production may require mTLS
                                ▼
┌────────────────────────────────────────────────────────────────────┐
│ Remote NixOS Browser Host                                         │
│                                                                    │
│  gsmlg_commander                                                  │
│  ├── Connection                                                    │
│  ├── Capability Registry                                          │
│  ├── RPC Router                                                    │
│  └── PTY Feature                                                   │
│                                                                    │
│  gsmlg_browser_agent                                              │
│  ├── Browser Capability                                           │
│  ├── Session Supervisor                                           │
│  ├── Job Supervisor                                               │
│  ├── Execution Journal                                            │
│  ├── Local Profile Lease                                          │
│  ├── Cloak Manager Adapter                                        │
│  ├── CDP Safe Browser                                             │
│  ├── Workflow Engine                                              │
│  └── Artifact Outbox                                              │
│                          │                                         │
│                          │ 127.0.0.1:8080                         │
│                          ▼                                         │
│  CloakBrowser Manager OCI                                         │
│  ├── Persistent Profiles                                          │
│  ├── KasmVNC / Xvnc                                               │
│  └── CDP Proxy                                                     │
└────────────────────────────────────────────────────────────────────┘
```

---

## 7. OTP Application Boundaries

### 7.1 `gsmlg_commander_protocol`

建议新增纯协议 Application：

```text
apps/gsmlg_commander_protocol
namespace: GSMLG.Commander.Protocol
```

职责：

- Capability Descriptor；
- RPC Request/Accepted/Response/Error；
- Job Event/Event ACK；
- Artifact Manifest；
- Version Negotiation；
- Payload Validation；
- 编码、解码和兼容性测试。

该 Application 不启动长期进程，不依赖 Repo、Phoenix Endpoint 或 Browser Backend。

### 7.2 `gsmlg_commander`

重新定位为远端 Capability Host：

- 唯一反向 WebSocket Connection；
- Commander 身份认证；
- Capability Registry；
- RPC Router；
- Request Deduplication；
- Response/Event 发送；
- 重连和重新注册；
- PTY 内建 Capability。

不得依赖 `gsmlg_browser_agent`。

### 7.3 `gsmlg_browser`

中央 Browser Control Service：

```text
apps/gsmlg_browser
namespace: GSMLG.Browser
```

职责：

- Node 和 Capability 发现；
- Profile 缓存与策略；
- Session 和 Job 持久化；
- 调度、超时、取消、重试；
- Commander RPC Bridge；
- Event 去重和 Reconcile；
- Artifact Registry；
- Public API；
- PubSub/Telemetry。

`gsmlg_browser` 不连接远端 Manager 或 CDP。

### 7.4 `gsmlg_browser_agent`

远端 Browser Runtime：

```text
apps/gsmlg_browser_agent
namespace: GSMLG.BrowserAgent
```

职责：

- 注册 `browser.control/v1`；
- Manager Health/Profile 操作；
- Session 和 Profile Lease；
- CDP；
- Observation/Action；
- Workflow；
- 本地 Journal；
- Artifact Outbox；
- 断线期间继续执行。

### 7.5 `gsmlg_admin_web`

只提供 Browser 管理 UI 和 API Controller，不承载执行逻辑。

---

## 8. Release Composition

### 8.1 Central release

```text
gsmlg_umbrella
├── gsmlg
├── gsmlg_commander_protocol
├── gsmlg_browser
├── gsmlg_scout_server
├── proxy_rules
├── gsmlg_admin_web
└── gsmlg_web
```

### 8.2 Remote browser release

在现有 Commander release 中加入：

```text
gsmlg_commander
├── gsmlg_commander_protocol
├── gsmlg_commander
└── gsmlg_browser_agent
```

Browser Agent 可通过配置关闭，使普通 Commander 继续只提供 PTY。

---

## 9. Commander Capability Control Plane

### 9.1 Channel split

```text
commander:<name>
  registration
  heartbeat
  capability snapshot/update
  RPC request/response
  job events
  event acknowledgement

terminal:<name>
  temporary compatibility path for PTY stream
```

注册、心跳和 Capability 必须从 `Terminal` 移入新的通用 Connection/Control Channel。

### 9.2 Capability descriptor

Browser Agent 注册：

```text
id: browser.control
version: 1
backend: cloakbrowser
operations:
  - manager.status
  - profiles.list
  - profile.status
  - profile.launch
  - profile.stop
  - session.open
  - session.observe
  - session.act
  - session.close
  - workflow.start
  - workflow.status
  - workflow.cancel
  - workflow.resume
  - workflow.reconcile
limits:
  max_profiles_running: 1
  max_sessions: 1
  max_workflows: 1
workflows:
  - gemini.deep_research/v1
  - gemini.youtube_analysis/v1
```

### 9.3 RPC envelope

每个 RPC Request 包含：

```text
protocol_version
request_id
capability
operation
idempotency_key
deadline_at
payload
```

长操作先返回：

```text
rpc.accepted
request_id
remote_execution_id
```

随后通过 `job.event` 报告状态。

### 9.4 Delivery semantics

- Request：at-least-once；远端按 `request_id` 和 `idempotency_key` 去重；
- Event：at-least-once；中心按 `remote_execution_id + sequence` 去重；
- Event ACK：累计确认；
- Final Result：在中心确认完整 Artifact 前保留在远端；
- Cancel：幂等；
- Reconcile：返回远端权威执行状态。

### 9.5 Message size

- Control Message 最大建议 `256 KiB`；
- Inline Artifact 最大建议 `512 KiB`；
- 大型 Artifact 使用签名上传或专用 Artifact Transfer，不通过 JSON Base64 长期传输。

---

## 10. Browser Backend Abstraction

定义远端 Behaviour：

```text
GSMLG.BrowserAgent.Backend
```

能力边界：

```text
manager_status
list_profiles
get_profile
launch_profile
stop_profile
open_session
close_session
connect_control_protocol
```

第一版实现：

```text
GSMLG.BrowserAgent.Backends.CloakBrowser
```

Backend Adapter 负责吸收 CloakBrowser Manager 的 API 变化。Workflow 不能直接依赖 Manager JSON 字段。

### 10.1 Profile data boundary

中央可保存：

```text
external_profile_id
name
backend
status
screen size
locale
timezone
last_seen_at
policy metadata
```

中央不得保存：

```text
fingerprint seed
proxy credential
user_data_dir
CDP URL
Cookie
Local Storage
IndexedDB
Manager Token
```

---

## 11. Browser Session Model

### 11.1 Session purpose

Session 是通用 Remote Browser Control 的核心。它绑定：

```text
central_session_id
remote_session_id
commander_id
profile_id
lease_id
mode
origin_policy
state_revision
```

### 11.2 Session modes

```text
automation
workflow
manual
```

- `automation`：外部调用方逐步 Observe/Act；
- `workflow`：远端状态机自动执行；
- `manual`：人工通过 WebVNC 控制。

同一 Profile 只能有一个 Active Lease。

### 11.3 Session state

```text
opening
ready
acting
waiting
waiting_human
closing
closed
orphaned
failed
```

### 11.4 Profile lease

Lease 权威状态位于远端 Browser Agent：

```text
profile_id
lease_id
owner_type
owner_id
mode
acquired_at
heartbeat_at
expires_at
```

中心保存镜像，不能仅依赖中心数据库防止并发。

Lease 规则：

- 一个 Profile 最多一个有效 Lease；
- Automation 和 Manual 互斥；
- Workflow Runner 只有持有 Lease 才能发送 Action；
- 断线不立即释放 Workflow Lease；
- 超时 Lease 只能由 Reconciler 在确认本地执行终止后回收。

---

## 12. Observation Model

Observation 是调用方或 Workflow 的只读输入。

建议结构：

```text
session_id
revision
url
origin
title
page_kind
loading_state
auth_state
alerts
visible_controls
semantic_tree
content_summary
focused_element
screenshots optional
observed_at
```

### 12.1 Semantic tree

默认使用 Accessibility Tree 和受限 DOM 信息，而不是传输完整 DOM：

```text
node_id
role
name
value
state
bounds optional
children
```

限制：

- 深度；
-节点总数；
-文本总字节数；
-敏感输入值不返回；
-密码字段永远返回 redacted；
-隐藏节点默认不返回。

### 12.2 Observation revision

每次稳定 Observation 生成单调递增 `revision`。

Action 可以携带：

```text
expected_revision
```

如果页面已发生明显变化，远端拒绝执行并返回 `stale_observation`，避免在错误页面点击。

---

## 13. Structured Action Model

### 13.1 Allowed actions

第一版支持：

```text
navigate
click
focus
fill
insert_text
press_key
select_option
scroll
wait_for
extract
screenshot
download
```

### 13.2 Locator algebra

优先使用语义 Locator：

```text
role + accessible_name
label
placeholder
text
node_id from observation
stable attribute
css fallback（受策略开关限制）
```

不接受：

```text
arbitrary javascript
raw CDP method
XPath generated by model
screen coordinate click as default
cookie/storage command
```

### 13.3 Action envelope

```text
action_id
session_id
expected_revision
type
locator
input
preconditions
postconditions
timeout_ms
```

### 13.4 Non-idempotent action protocol

所有非幂等 Action 按以下顺序执行：

```text
1. Journal pending_action
2. Validate lease and expected_revision
3. Execute action
4. Observe postcondition
5. Journal completed/uncertain
6. Increment session revision
7. Return result
```

当连接在执行中断开时：

- 已满足 Postcondition：返回已完成；
- 明确未执行：允许相同 `action_id` 重试；
- 无法判断：返回 `action_outcome_unknown`，进入 Reconcile 或人工处理。

### 13.5 Safe text input

优先通过浏览器输入事件或 CDP Input Domain 插入文本。不要依赖已废弃的 `document.execCommand('insertText')`。

---

## 14. Workflow Engine

### 14.1 Functional Core

Workflow 状态转换为纯函数：

```text
State + Observation → Decision
```

Decision 只能是：

```text
Action
Wait
EmitEvent
RequestHuman
Complete
Fail
```

Executor 负责副作用，并在每一步后保存 Checkpoint。

### 14.2 Why workflows run remotely

长 Workflow 必须在 Browser Agent 运行，因为：

- Browser Agent 与页面在同一故障域；
- Commander 断线时可以继续；
- 每一步不需要跨 WAN 往返；
- 非幂等 Action 可以本地 Reconcile；
- 中心升级不影响页面执行；
- 最终 Event 可以连接恢复后重发。

### 14.3 Workflow contract

```text
id
version
input_schema
output_schema
required_origins
required_profile_capabilities
initial_state
transition/2
extract_result/2
```

### 14.4 Small-model policy

Browser Service 对模型保持中立。

小模型可以：

- 作为外部调用方使用 Session Observe/Act API；
- 作为远端 Workflow 的受约束 Policy；
- 将自然语言任务规范化成 Workflow Input。

小模型不得：

- 输出任意 JavaScript 或 Raw CDP；
-读取 Cookie、密码和本地文件；
-绕过 `allowed_actions`；
-自行解决 CAPTCHA；
-绕过 Origin Policy。

---

## 15. Initial Gemini Workflows

### 15.1 `gemini.deep_research/v1`

输入：

```text
prompt
output_locale
research_scope
required_sections
auto_approve_plan
profile_id optional
```

主要阶段：

```text
acquire_profile
launch_profile
attach_browser
inspect_auth
open_chat
select_deep_research
submit_prompt
wait_plan
approve_plan
researching
stabilize_report
extract_report
produce_artifacts
complete
```

完成条件：

```text
最终报告容器存在
AND 不处于生成/研究状态
AND 正文 Hash 连续多次稳定
AND 页面无登录、限额或错误提示
```

### 15.2 `gemini.youtube_analysis/v1`

输入：

```text
youtube_url
analysis_profile
output_locale
custom_instructions
use_deep_research
```

输出至少包括：

```text
summary
timeline
key_arguments
evidence
action_items
uncertain_claims
source_video
```

Workflow 必须检测：

- 视频不可用；
-年龄限制；
-地区限制；
-Gemini 无法访问视频；
-回答仅基于标题/描述而没有分析内容；
-缺少要求的时间戳或结构。

### 15.3 Versioned Gemini UI contract

页面识别集中在：

```text
GSMLG.BrowserAgent.Sites.Gemini.UIContract
```

Selector 优先级：

```text
ARIA role/name
stable semantic attribute
structural relationship
localized text alias
CSS fallback
```

UI Contract 与 Workflow 独立版本化。发生未知页面结构时进入 `waiting_human`，不能盲目继续点击。

---

## 16. Manual Intervention

### 16.1 Triggers

```text
login_required
reauth_required
passkey_required
two_factor_required
captcha_required
account_warning
ui_contract_mismatch
action_outcome_unknown
```

### 16.2 Flow

```text
Workflow pauses
→ emits intervention.required
→ automation lease transitions to manual handoff
→ operator opens remote WebVNC through SSH tunnel
→ operator completes human-only step
→ operator calls resume
→ Browser Agent reacquires automation lease
→ fresh observation
→ Workflow continues
```

第一版不通过 Commander 转发 VNC。未来如需统一远程画面，应单独设计具备 Backpressure 的 Binary Stream Protocol。

---

## 17. Artifact Model and Transfer

### 17.1 Artifact types

```text
report.markdown
report.html
report.json
sources.json
observation.json
screenshot.png
download
failure-diagnostic.json
```

`download` 使用同一份有限 MIME/扩展名矩阵：`.bin`、`.pdf`、`.json`、`.html`、
`.md`、`.txt`、`.png`、`.jpg` 和 `.jpeg`；交叉或未知组合必须拒绝。

### 17.2 Manifest

```text
artifact_id
job_id | session_id  # exactly one owner
kind
mime
filename
size
sha256
transfer_mode
metadata
```

### 17.3 Transfer modes

```text
inline
signed_upload
remote_pending
```

- 小型 Markdown/JSON 可以 Inline；
-截图、PDF、下载文件使用签名上传；
-中心未确认前，远端保持 `remote_pending`。

### 17.4 Integrity

中心必须验证：

-声明大小；
-SHA-256；
-MIME/扩展名策略；
-Job 和 Artifact Ownership；
-上传过期时间。

---

## 18. Durable State and Recovery

### 18.1 Central persistence

中央 PostgreSQL 保存：

```text
browser_nodes
browser_profiles
browser_sessions
browser_jobs
browser_job_events
browser_artifacts
```

### 18.2 Remote persistence

远端使用 CubDB 或等价本地 KV 保存：

```text
session journal
job checkpoint
pending action
request deduplication
unacked event sequence
artifact outbox
profile lease
```

### 18.3 Recovery scenarios

#### Central restart

- 重启后查询 `accepted/running/waiting_human` Job；
- 对在线 Commander 发送 `workflow.reconcile`；
- 接收远端权威状态和未确认 Event；
- 恢复 Artifact Transfer。

#### Commander connection loss

- Browser Agent Workflow 继续运行；
- Event 写入本地 Outbox；
- 重连后从最后 ACK Sequence 续传。

#### Browser process crash

- Browser Agent 重启 Session Runner；
- 重新连接 Manager Profile；
- 使用 URL、Checkpoint、Pending Action 和 Observation Reconcile；
- 无法判断时进入 `waiting_human`。

#### Manager restart

- Profile 状态变为 unavailable；
- Workflow 不立即重复提交；
- Manager 恢复后重新 Attach；
- 根据页面状态继续或人工处理。

#### Duplicate request

相同 `idempotency_key`：

- 已运行：返回已有 Execution；
- 已完成：返回已有 Result；
- 已取消/失败：由明确 Retry Policy 决定是否创建新 Attempt。

---

## 19. Central Data Model

### 19.1 `browser_nodes`

```text
id
commander_id unique
enabled
default_backend
status
capabilities
limits
last_seen_at
last_error
metadata
timestamps
```

动态在线状态来自 Commander Registry；表用于持久配置、策略和历史。

### 19.2 `browser_profiles`

```text
id
node_id
external_id
name
backend
enabled
is_default
runtime_status
automation_status
locale
timezone
screen
policy
last_seen_at
last_error
timestamps
```

唯一索引：

```text
unique(node_id, external_id)
```

### 19.3 `browser_sessions`

```text
id
node_id
profile_id
remote_session_id
lease_id
mode
status
origin_policy
revision
owner_actor_id
last_seen_at
expires_at
error
timestamps
```

### 19.4 `browser_jobs`

```text
id
node_id
profile_id
session_id optional
remote_execution_id
workflow
workflow_version
status
phase
input
idempotency_key unique
last_remote_sequence
result
error
requested_by_actor_id
started_at
completed_at
timestamps
```

### 19.5 `browser_job_events`

```text
id
job_id
remote_execution_id
sequence
event
phase
metadata
occurred_at
inserted_at
```

唯一索引：

```text
unique(remote_execution_id, sequence)
```

### 19.6 `browser_artifacts`

```text
id
job_id | session_id  # exactly one owner
kind
mime
filename
size
sha256
storage_type
storage_ref
inline_content
metadata
inserted_at
```

---

## 20. Public API

### 20.1 Nodes and profiles

```text
GET  /api/browser/nodes
GET  /api/browser/nodes/:node_id
GET  /api/browser/nodes/:node_id/profiles
POST /api/browser/nodes/:node_id/profiles/sync
POST /api/browser/profiles/:id/launch
POST /api/browser/profiles/:id/stop
```

### 20.2 Sessions

```text
POST   /api/browser/sessions
GET    /api/browser/sessions/:id
POST   /api/browser/sessions/:id/observe
POST   /api/browser/sessions/:id/actions
POST   /api/browser/sessions/:id/manual-acquire
POST   /api/browser/sessions/:id/manual-release
DELETE /api/browser/sessions/:id
```

### 20.3 Jobs and workflows

```text
POST /api/browser/jobs
GET  /api/browser/jobs
GET  /api/browser/jobs/:id
GET  /api/browser/jobs/:id/events
POST /api/browser/jobs/:id/cancel
POST /api/browser/jobs/:id/retry
POST /api/browser/jobs/:id/resume
POST /api/browser/jobs/:id/reconcile
```

### 20.4 Artifacts

```text
GET /api/browser/jobs/:id/artifacts
GET /api/browser/artifacts/:id
GET /api/browser/artifacts/:id/content
```

### 20.5 Event streaming

管理 UI 和外部调用方可通过：

```text
Phoenix PubSub → LiveView
Server-Sent Events or WebSocket → API consumers
```

获取增量 Job Event。

---

## 21. Admin Web

### 21.1 Global pages

```text
/browser
/browser/nodes
/browser/profiles
/browser/sessions
/browser/jobs
/browser/jobs/new
/browser/jobs/:id
/browser/settings
```

### 21.2 Commander integration

Commander 详情页增加：

```text
/commander/:name/browser
```

只有节点上报 `browser.control/v1` 时显示。

### 21.3 Dashboard content

- 在线 Browser Node；
- Manager/Backend 健康；
-Profile 总数和可用 Profile；
-Active Session；
-Queued/Running/Waiting Human Job；
-最近错误；
-Artifact Transfer 状态；
-Commander TLS 状态摘要。

### 21.4 Job detail

- Workflow 和输入摘要；
-节点与 Profile；
-状态与 Phase；
-Event Timeline；
-Gemini Chat URL（仅在授权 UI 中展示）；
-Intervention 指令；
-Artifact 列表；
-Cancel、Retry、Resume、Reconcile。

---

## 22. Configuration

### 22.1 Central

```toml
[browser]
enabled = true
default_node = "gemini-browser-01"
inline_artifact_max_bytes = 524288
event_retention_days = 30

[browser.jobs]
dispatch_timeout_ms = 30000
reconcile_interval_ms = 30000
default_deadline_ms = 7200000
max_attempts = 3

[browser.security]
allowed_schemes = ["https"]
allow_css_locator = false
allow_downloads = true
max_observation_bytes = 1048576
max_artifact_bytes = 104857600
```

### 22.2 Remote Commander

```toml
[commander]
start = true
server = false
name = "gemini-browser-01"
umbrella_server_url = "https://commander.admin.gsmlg.org"
platform_key = "loaded-from-runtime-secret"
features = ["pty"]

[commander.tls]
enabled = true
client_cert_file = "/run/secrets/gsmlg-commander/client-chain.pem"
client_key_file = "/run/secrets/gsmlg-commander/client-key.pem"
reload_interval_ms = 60000
```

### 22.3 Remote Browser Agent

```toml
[browser_agent]
enabled = true
backend = "cloakbrowser"
manager_url = "http://127.0.0.1:8080"
manager_token_env = "CLOAKBROWSER_MANAGER_TOKEN"
state_dir = "/var/lib/gsmlg/browser-agent"
default_profile_id = "gemini-primary"
max_concurrent_sessions = 1
max_concurrent_workflows = 1
keep_profile_running = true

[browser_agent.security]
allowed_origins = [
  "https://gemini.google.com",
  "https://accounts.google.com",
  "https://www.youtube.com",
  "https://youtu.be"
]
allowed_upload_origins = ["https://commander.admin.gsmlg.org"]
```

Manager Token、Commander Credential、Client Key 均由 Runtime Secret 注入，不写入 TOML 正文。

---

## 23. Commander mTLS Transport

mTLS 是 Commander Connection 的可配置安全层，适用于 Browser、PTY 和后续所有 Capability。

要求：

- `wss://`；
-验证服务端证书和主机名；
-可配置 Client Certificate Chain 和 Private Key；
-启动前验证证书与私钥匹配；
-证书轮换后重建 Commander Connection；
-握手失败不得回退到无 Client Certificate 或 `ws://`；
-应用层 Commander Credential 和 Capability 授权继续保留；
-Transport 重连不能终止 Browser Agent 本地 Job。

建议使用独立 SNI Host：

```text
commander.admin.gsmlg.org
```

以便 Caddy 使用机器专用 Client CA。

这一部分属于 Commander 基础设施，不应渗透到 Browser Workflow 和 Browser Session API。

---

## 24. Security Model

### 24.1 Trust layers

```text
TLS server verification
→ optional/required production client mTLS
→ Commander application identity
→ Capability authorization
→ Browser Node policy
→ Profile origin policy
→ Session lease
→ Action validation
```

### 24.2 Origin policy

每个 Profile/Session 必须有 Allowlist：

- Navigation 检查目标 URL；
-重定向后重新检查 Origin；
-下载来源记录 Origin；
-未知 Origin 默认暂停；
-`file://`、`data:`、`javascript:` 和本地网络默认禁止。

### 24.3 Sensitive-state isolation

以下数据不得离开远端 Browser Host：

```text
Cookie
Local Storage
IndexedDB
password field value
client key
manager token
proxy credential
raw CDP URL
profile filesystem path
```

### 24.4 Logging

日志只记录：

```text
node_id
profile_id
session_id
job_id
request_id
action type
status
error code
duration
payload size
content hash
```

不得记录：

```text
完整 Prompt
报告正文
页面完整文本
表单内容
Authorization Header
TLS private material
完整 RPC payload
```

### 24.5 Production debug telemetry

生产环境不能无条件启用 `Phoenix.SocketClient.Telemetry.attach_debug_handler/0`。TLS Options 和 RPC Payload 必须经过递归脱敏。

---

## 25. Error Model

统一错误结构：

```text
class
code
message
retryable
human_action
details
```

主要类别：

```text
transport
commander
capability
manager
profile
session
lease
observation
action
workflow
intervention
artifact
policy
```

示例错误码：

```text
node_offline
capability_not_supported
manager_unavailable
profile_not_found
profile_busy
lease_conflict
session_not_ready
stale_observation
action_target_not_found
action_postcondition_failed
action_outcome_unknown
navigation_not_allowed
login_required
captcha_required
ui_contract_mismatch
workflow_deadline_exceeded
artifact_integrity_failed
tls_handshake_failed
```

---

## 26. Telemetry

建议事件：

```text
[:gsmlg, :browser, :node, :status]
[:gsmlg, :browser, :profile, :sync]
[:gsmlg, :browser, :session, :open]
[:gsmlg, :browser, :session, :close]
[:gsmlg, :browser, :lease, :transition]
[:gsmlg, :browser, :observation, :complete]
[:gsmlg, :browser, :action, :complete]
[:gsmlg, :browser, :workflow, :transition]
[:gsmlg, :browser, :artifact, :transfer]
[:gsmlg, :browser, :intervention, :required]
[:gsmlg, :commander, :rpc, :request]
```

主要指标：

- Browser Node availability；
- Manager availability；
- Session open latency；
- Action success/failure/unknown rate；
- Workflow completion rate；
- Workflow duration by phase；
- Reconcile count；
- Human intervention rate；
- UI Contract mismatch rate；
- Artifact transfer retries；
- Commander reconnect count。

---

## 27. Supervision Trees

### 27.1 Central

```text
GSMLG.Browser.Application
└── GSMLG.Browser.Supervisor
    ├── Registry
    ├── SessionDirectory
    ├── CommanderBridge
    ├── Scheduler
    ├── Reconciler
    └── DynamicSupervisor
        └── transient live session proxies
```

Oban 负责 Durable Job Activation；PostgreSQL 是中央状态权威。

### 27.2 Remote

```text
GSMLG.BrowserAgent.Application
└── GSMLG.BrowserAgent.Supervisor
    ├── Journal
    ├── Capability
    ├── ManagerMonitor
    ├── ProfileLeaseServer
    ├── SessionSupervisor
    ├── JobSupervisor
    └── ArtifactOutbox
```

`Commander.Connection` 与 Browser Agent Runner 不在同一个 restart subtree，避免 Transport Restart 终止 Workflow。

---

## 28. Implementation Plan

### Milestone 0 — Commander Capability RPC foundation

- 新建 `gsmlg_commander_protocol`；
-增加通用 Commander Connection Channel；
-将注册、心跳和 Capability 从 Terminal 移出；
-AgentRegistry 成为唯一在线节点来源；
-实现 RPC Request/Accepted/Response/Event/ACK；
-实现 Request Deduplication 和 Pending Request Registry；
-升级 Commander 应用认证；
-增加可配置 mTLS Client Certificate；
-清理敏感 Telemetry。

### Milestone 1 — Remote Browser Agent foundation

- 新建 `gsmlg_browser_agent`；
-实现 Capability Registry 集成；
-实现 CloakBrowser Manager Adapter；
-Manager Health、Profile List/Status/Launch/Stop；
-实现远端 Journal、Lease 和 Recovery；
-提供脱敏 Profile Snapshot。

### Milestone 2 — Generic Browser Session Control

- CDP Connection 和 Target 管理；
-Safe Browser Action Layer；
-Observation 和 Semantic Tree；
-Session Open/Observe/Act/Close；
-Action ID、Revision 和 Postcondition；
-Origin Policy；
-Session API 和 Admin UI。

### Milestone 3 — Durable Jobs and Artifact Service

- 新建 `gsmlg_browser`；
-Ecto Schema 和 Migration；
-Oban Dispatch/Reconcile；
-Event 去重；
-Artifact Manifest、Inline Transfer、Signed Upload；
-Node/Profile/Job Dashboard。

### Milestone 4 — Gemini Workflows

- Gemini UI Contract；
-Deep Research Workflow；
-YouTube Analysis Workflow；
-报告 Markdown/HTML/JSON/Sources 提取；
-人工接管和 Resume；
-真实 Profile E2E。

### Milestone 5 — Small-model integration and hardening

-受约束 Policy Adapter；
-Observation Compression；
-Decision Schema Validation；
-故障注入；
-Manager/Commander/Center restart tests；
-证书轮换期间 Workflow 连续性；
-安全审计和性能指标。

---

## 29. Acceptance Criteria

1. 中心可发现带 `browser.control/v1` 的 Commander。
2. 中心可同步远端 CloakBrowser Profile，且响应中不存在敏感 Profile 数据。
3. 一个 Profile 不能被两个 Session 或 Workflow 同时控制。
4. 调用方可以打开 Session、获取 Observation、执行结构化 Action 并关闭 Session。
5. 页面 Revision 变化后，使用旧 Observation 的 Action 被拒绝。
6. Raw CDP、任意 JavaScript、Cookie 和 Local Storage 不存在公共 API。
7. Commander 断线时，正在运行的 Deep Research 继续执行。
8. 连接恢复后，未确认 Event 按 Sequence 重传且中心不重复入库。
9. 中心重启后能够 Reconcile 远端 Running Job。
10. Prompt 提交后进程崩溃，不会盲目重复提交。
11. 遇到登录、2FA、CAPTCHA 或未知 UI 时进入 `waiting_human`。
12. Resume 后先重新 Observation，再继续 Workflow。
13. Markdown、JSON、Sources 和 Screenshot Artifact 可下载并通过 SHA-256 校验。
14. 生产 Commander 可使用 mTLS Client Certificate 连接，并在证书轮换后自动重连。
15. Commander Transport 重连不会终止 Browser Agent Job。
16. 日志和 Telemetry 不包含 Prompt 正文、页面正文、Cookie、Manager Token、Client Key 或完整 RPC Payload。

---

## 30. Repository Change Map

建议新增：

```text
apps/gsmlg_commander_protocol/
apps/gsmlg_browser/
apps/gsmlg_browser_agent/
```

建议重点修改：

```text
apps/gsmlg_commander/lib/gsmlg/commander.ex
apps/gsmlg_commander/lib/gsmlg/commander/terminal.ex
apps/gsmlg_admin_web/lib/gsmlg/admin_web/channels/commander_socket.ex
apps/gsmlg_admin_web/lib/gsmlg/admin_web/channels/commander_channel.ex
apps/gsmlg/lib/gsmlg/command_platform/agent_registry.ex
apps/gsmlg_config/lib/gsmlg/config/schema.ex
apps/gsmlg_config/lib/gsmlg/config/setup.ex
apps/gsmlg_admin_web/lib/gsmlg/admin_web/router.ex
apps/gsmlg_admin_web/lib/gsmlg/admin_web/admin_menu.ex
mix.exs
config/config.exs
```

数据库 Migration 继续放置：

```text
apps/gsmlg/priv/repo/migrations/
```

---

## 31. Final Decision

第一版严格限定为：

```text
1 个或少量 Browser Node
每个 Node 1 个运行 Profile
每个 Profile 1 个 Active Lease
通用 Session Observe/Act
2 个内建 Gemini Workflow
结构化 Artifact 输出
人工接管
Commander WSS；生产支持 mTLS
```

实施顺序必须是：

```text
Commander Capability RPC
→ Browser Agent + Manager Adapter
→ Generic Session Control
→ Durable Job/Artifact Service
→ Gemini Workflows
→ Small-model Policy
```

Browser Control 是主产品；Commander mTLS 只是其依赖的传输安全能力。
