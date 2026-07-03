# codev — 使用文档

多 agent 协作开发编排器。让 Claude Code 在开发关键节点，把方案或代码交给**其它 agent CLI**
（codex / gemini / reasonix / qoderclicn / opencode / codebuddy，各自背后是不同大模型）做独立的
头脑风暴、代码评审、对抗挑战，再由 Claude 做**跨模型综合**。核心信念：不同模型的盲区不同，
交叉验证能显著减少 bug 与遗漏。

> 本文件面向**使用者**。`SKILL.md` 是给 Claude 执行的规范，`references/` 是调用细节，日常无需翻。

---

## 1. 它能帮你做什么

| 你想要 | 用法 |
|---|---|
| 让多个模型给同一需求出方案，交叉取优 | `/codev brainstorm <需求>` |
| 让多个模型评审你的代码改动 | `/codev review [关注点]` |
| 让模型扮演攻击者，尽力打破你的代码/方案 | `/codev challenge [焦点]` |
| 把一个技术问题问多个模型，汇总观点 | `/codev consult <问题>` |
| 从设计到编码到评审走完整流程 | `/codev <一段需求描述>` |
| 不带参数，让它看你当前改动、问你要干嘛 | `/codev` |

**铁律（安全保障，始终生效）**
- Claude 是**唯一改文件的人**。外部 agent 一律**只读**运行，只输出方案/评审/质疑。
- 发给外部模型前会做 **secret 扫描**，命中疑似密钥会停下让你确认或脱敏。
- 每次 fan-out（并行调多个 agent）前会用弹窗让你**确认调用哪些**（消耗各自账号额度）。
- 外部 agent 的输出**逐字呈现**，不总结、不裁剪，清楚标注来源与模型。

---

## 2. 前置准备

### 2.1 装 / 登录外部 agent CLI（按需，装几个用几个）
这些是第三方 CLI，skill 不代装。至少装 1 个才有意义，**建议 3 个以上**才有交叉验证价值。

| agent | 背后模型 | 安装后 |
|---|---|---|
| `codex` | OpenAI GPT | `codex login` 或设 `$OPENAI_API_KEY`/`$CODEX_API_KEY` |
| `gemini` | Google Gemini | 首次交互登录 或 `$GEMINI_API_KEY` |
| `reasonix` | DeepSeek | `reasonix setup` 配 key |
| `qoderclicn` | Qoder | 账号交互登录 |
| `opencode` | 多供应商 | `opencode auth` 配 providers |
| `codebuddy` | 腾讯（Claude Code 分支） | 交互登录 |

### 2.2 装 `timeout`（强烈建议）
macOS 原生没有 `timeout`。**不装后台慢模型无兜底会永久挂起**，skill 会自动跳过它们。
```bash
brew install coreutils      # 提供 gtimeout
```
装完 `/codev` 的探测会显示 `timeout -> /opt/homebrew/bin/timeout`。

### 2.3 shell 说明
skill 已对 **zsh** 做过兼容（用 `run()` 函数封装超时，而非 `$TP` 变量前缀——后者在 zsh 下会失败）。
bash/zsh 都能正常跑。

---

## 3. 五种模式详解

### brainstorm — 头脑风暴 / 方案设计
```
/codev brainstorm 给订单模块加一个幂等的支付回调
```
流程：Claude 先出 v0 方案 → 各 agent 独立出自己的方案并挑 v0 的刺 → 综合成
**取舍表 + 风险清单 + 推荐方案**，可选写入 `docs/方案-<主题>.md`。

### review — 多 agent 代码评审
```
/codev review                 # 评审当前全部改动
/codev review 并发安全和错误处理   # 带关注点
```
流程：自动定 base（`@{u}` → `origin/HEAD` → `main`… 回退链，会验证 commit 存在）→ **secret 扫描**
→ 各 agent 评审 → 综合出**一致性矩阵 + PASS/FAIL 门禁**（出现 P1/critical 即 FAIL）→ 问你要不要
让 Claude 修复确认的问题。

- codex 用原生 `codex review --base <base>`（只读，从仓库根跑）。
- 其余 agent 收到脱敏后的 diff 文本，在隔离空目录里跑。

### challenge — 对抗式挑战
```
/codev challenge lib/auth/token.dart
```
让 agent 扮演攻击者，专找会让代码崩的输入、边界、并发/竞态、错误处理缺失、隐含假设。
产出**攻击面清单**，标注哪些是真问题、哪些已被现有代码处理。

### consult — 咨询汇总
```
/codev consult Riverpod 的 ref.watch 和 ref.read 在什么场景会踩坑
```
把问题转述给多个模型，给出各家观点 + Claude 的收敛结论。

### 全流程（默认）
```
/codev 实现一个带重试和退避的 HTTP 客户端封装
```
brainstorm → 编码 → review → 小结，**每个阶段之间会停下等你确认**，不会一口气冲到底。

---

## 4. 两种分工模式（每次 fan-out 前会问你）

| 模式 | 说明 | 何时用 |
|---|---|---|
| **全量模式**（默认） | 每个 agent 都看**全部内容**，重叠覆盖最能暴露盲区；综合出一致性矩阵（都发现/多数/仅 1） | 想要最强交叉验证、内容不大时 |
| **分工模式** | 每个 agent 只看**自己那一面**（如 codex→架构/数据库、reasonix→UI/交互、opencode→其余）；省额度、快，但无交叉验证 | 改动大、想省 token、每块只需一个模型看时 |

> 参与 agent **< 3 个时分工收益不大**，会直接建议全量。

---

## 5. 运行时你会看到什么

1. **启动状态板**：每个 agent 一行 `▶ codex（模型 GPT）｜ 范围：全量 ｜ 强度 medium ｜ 运行中…`
2. **完成翻牌**：`✔ codex 完成` / `⏭ reasonix 跳过（超时）`
3. **逐字呈现**：每个 agent 的原始输出用分隔框原样展示，不删改：
   ```
   ━━━ CODEX（模型：GPT）━━━━━━━━━━━━━━━
   <原始输出>
   ━━━━━━━━━━━━━━━━━ tokens: … ｜ 用时: …s
   ```
4. **跨模型综合**：一致性矩阵 + Claude 裁决（采纳/存疑/驳回）+（review 模式）PASS/FAIL。

慢模型默认**后台执行**（不受前台超时限制），跑完通知，所以你不会看到它"卡住"。

---

## 6. 推理强度

默认一律 `medium`（**高强度 + 大提示词是超时主因**）。仅复杂任务或你要更深时升 `high`。
输入里带 `--xhigh` 才对支持的 agent 用最高档（codex `xhigh`、reasonix/qoderclicn `max`）——会更慢、更易超时。

---

## 7. 常见问题

| 现象 | 原因 / 处理 |
|---|---|
| 提示"未检测到任何外部 agent CLI" | 一个都没装，按第 2.1 节装并登录 |
| `timeout -> MISSING` | 没装 coreutils，`brew install coreutils`；不装则慢 agent 会被跳过 |
| 某 agent 超时被跳过 | 已默认后台+medium；仍超时可降强度/精简范围重试。不阻塞其它 agent |
| codebuddy 常无输出/超时 | 已知问题（退出码 0 但 stdout 空）；默认推荐里已注明，会自动跳过 |
| gemini 报网络错误 | 本机 gemini 偶发 503/fetch failed，属它自身网络问题，重试或换 agent |
| review 说 base 无效 | 初始提交/浅克隆时会停下，让你指定 base 或确认用 `git diff --root HEAD` |
| 命中 secret 扫描 | 会停下让你确认继续/脱敏/缩小范围——**不要**把真实 token/密钥发给外部模型 |

---

## 8. 文件结构

```
codev/
├── README.md              # 本文件：使用文档
├── SKILL.md               # 给 Claude 执行的主规范（流程 / 铁律 / 通用机制 A–F）
├── bin/
│   └── codev-lib.sh       # 共享 shell 函数库：timeout 封装 / 沙盒 / 输出捕获 / RC 上报 / 探测
└── references/
    ├── agents.md          # 每个 agent 的精确调用命令、鉴权、只读策略、失败处理
    ├── prompts.md         # 发给外部 agent 的提示词模板（含文件系统边界）
    └── synthesis.md       # 跨模型综合、一致性矩阵、PASS/FAIL 门禁规则
```

> **`bin/codev-lib.sh`**：调用外部 agent 的公共底座。Step 0 会建一个**本次会话专属目录**
> （`mktemp -d`）并把它拷进去，之后每个后台调用 `CODEV_DIR=<会话目录>; source "$CODEV_DIR/codev-lib.sh"`
> 一行即可拿到 `codev_bg_native` / `codev_bg_sandboxed` 等函数——超时封装、隔离空目录、退出码/超时的
> 显式上报都集中在这一处，改一次全局生效。输出走会话目录（而非固定 `/tmp/codev-*`），避免并发的两个
> `/codev` run 互相覆盖、清理误删。参考 gstack 的 `bin/gstack-codex-probe` 做法。
