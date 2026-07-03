---
name: codev
description: >
  多 agent 协作开发编排器。在开发全流程中调用外部 agent CLI（codex / gemini /
  reasonix / qoderclicn / opencode / codebuddy，各自背后是不同大模型）做方案头脑风暴、
  代码评审、对抗式挑战与跨模型综合，用不同模型的多样性提升产出质量、减少 bug 与遗漏。
  Claude 始终是唯一的编码执行者，外部 agent 一律以只读"顾问团"身份被调用。
  触发场景：用户说"多 agent 评审 / 第二意见 / 头脑风暴 / 跨模型 / 让 codex 挑刺 /
  评审我的改动 / codev / codev review / codev brainstorm / codev challenge / codev consult"。
allowed-tools:
  - Bash
  - Read
  - Edit
  - MultiEdit
  - Write
  - Glob
  - Grep
  - AskUserQuestion
  - Monitor
---

# codev — 多 agent 协作开发

你正在运行 `/codev` skill。它把 Claude Code 变成一个**编排器**：Claude 负责理解需求、
主导编码；在关键节点把方案或代码交给**其它 agent CLI**（每个背后是不同的大模型）做
独立的头脑风暴、评审、对抗挑战，再由 Claude 做**跨模型综合**。核心信念：不同模型的
盲区不同，交叉验证能显著减少 bug 与遗漏。

**铁律**
- Claude 是**唯一改文件的人**。外部 agent 一律**只读**运行，只输出方案 / 评审 / 质疑，
  绝不让它们改仓库文件。**只读靠双重保障**：能用原生只读旗标的用旗标（codex `-s read-only`、
  gemini `--approval-mode plan`）；无完整原生只读的（reasonix / codebuddy 完全无；qoderclicn `--tools ""`、
  opencode `--agent` 为半原生）按运行位置二选一：**(a) 首选——隔离空目录只喂提示词文本**（cwd 是空目录，够不到仓库，从根本上
  免风险；此时只需 fan-out **整体**前后各做一次全局 `git status --porcelain` 兜底核对，不必逐 agent 快照）；
  **(b) 确需在真实仓库 cwd 跑——则必须逐 agent 前后快照核对 + 串行**。发现改动即停下、逐字上报用户由其
  处置（**不自动回滚**，以免误删用户未提交的工作；见 `agents.md` 只读风险总结）。
- 外部 agent 的输出**逐字呈现**给用户，不总结、不裁剪、不美化。清楚标注来源与模型。
- 每个要 fan-out（并行调多个外部 agent）的节点，先用 AskUserQuestion 让用户确认调用哪些
  agent（给推荐组合），因为这会消耗各自账号的额度。
- 遵守本机 `~/.claude/CLAUDE.md` 的项目规范（如 Flutter 的 build_runner、`--dart-define`；
  "读后再改 / 最小改动 / 表单错误用 errorText / 删除就彻底删"）。

参考文件（按需 Read，不要一次性全读）：
- `references/agents.md` — 每个 agent 的精确调用命令、探测/鉴权、超时、只读策略、失败处理。
- `references/prompts.md` — 发给外部 agent 的提示词模板（含文件系统边界）。
- `references/synthesis.md` — 跨模型综合、一致性矩阵、PASS/FAIL 门禁规则。

---

## Step 0 — 探测可用 agent

```bash
# 暂存【共享函数库】到确定性字面路径：后台是独立 shell、不继承变量/函数，靠字面路径 source 拿到它。
# <SKILL_DIR> 用本 skill 头部给出的 "Base directory" 字面替换（如 /Users/…/.claude/skills/codev）。
cp "<SKILL_DIR>/bin/codev-lib.sh" /tmp/codev-lib.sh
source /tmp/codev-lib.sh
codev_probe        # 列出 OK/MISS 的 agent + timeout 状态（库函数说明见 references/agents.md）
```

- 只把标 `OK` 的 agent 列入后续可选项。
- 后续所有 agent 调用统一走库函数 `codev_bg_sandboxed` / `codev_bg_native`（内部用 `codev_run` 封装
  timeout）。600s 只是**兜底真正卡死的进程**的安全网，不是常规上限——常规靠**后台执行**（通用机制 C）
  让慢模型跑完。**切勿**用 `$TP <cmd>` 变量前缀：zsh 不做词拆分会把整串当一个命令名（本机 shell 就是
  zsh，实测每个调用都 exit 127）；库里的 `codev_run` 用 `"$@"` 传参，bash/zsh 都对。
- 若 `timeout -> MISSING`（stock macOS 常见）：提示用户 `brew install coreutils`；未装时库函数会
  **自动跳过该 agent**（后台无兜底 = 永久挂起）并提示改前台串行。**注意**：`$TO` 缺失时优先只让非原生
  只读 agent 处理提示词文本、不接触工作区。
- 若一个都没有：停下，告诉用户"未检测到任何外部 agent CLI"，并给出安装指引
  （见 `references/agents.md` 顶部），然后退出。
- 若只有 1 个可用：跳过 AskUserQuestion 的选择步骤，直接用它，但提示用户
  "当前只有 X 可用，跨模型交叉验证的价值有限"。

---

## Step 1 — 识别模式

解析用户输入：

| 输入 | 模式 | 见 |
|---|---|---|
| `/codev brainstorm [需求]` | **头脑风暴 / 方案设计** | Step 2A |
| `/codev review [关注点]` | **多 agent 代码评审** | Step 2B |
| `/codev challenge [焦点]` | **对抗式挑战** | Step 2C |
| `/codev consult [问题]` | **咨询汇总** | Step 2D |
| `/codev <一段需求描述>` | **全流程**（默认） | Step 2E |
| `/codev`（无参数） | **自动检测** | 见下 |

**自动检测（无参数）**：
1. 查有无改动（覆盖 staged + unstaged + untracked，别只用 `git diff --stat`，它漏掉已 `git add`
   的和未跟踪的）：`git status --porcelain --untracked-files=all 2>/dev/null`。
2. 有改动 → AskUserQuestion：A) 评审这些改动 B) 对抗式挑战 C) 我自己描述需求。
3. 无改动 → 问用户："想让 codev 做什么？（头脑风暴新需求 / 评审 / 咨询）"

**推理强度（默认 medium，防超时）**：**高推理强度 + 大提示词是超时的主因**，默认一律用 `medium`
（有旗标的 codex/reasonix/qoderclicn 才生效；gemini/opencode/codebuddy 无推理强度旗标，用其默认，D 的
状态行"强度"字段留空或写"默认"）。仅当任务确实复杂或用户要更深时升 `high`；用户输入含 `--xhigh` 才对
支持的 agent 用最高档（codex `xhigh`、reasonix/qoderclicn `max`），并从提示词剔除该词。
**升强度前提醒用户会更慢、更易触发超时**。

---

## 通用机制（所有 fan-out 模式共用）

### A. 选 agent + 选分工模式（AskUserQuestion）
在任何要并行调用外部 agent 的节点，先用 AskUserQuestion 让用户确认**两件事**：

**A1. 调用哪些 agent**（给推荐组合）：
- brainstorm 默认推荐：`gemini`（大上下文发散）+ `reasonix`（低成本快速）+ `codex`（严谨挑刺）
- review 默认推荐：`codex`（深度审查）+ `qoderclicn`（代码评审，稳定）+ `codebuddy`
  （中文评审；但**本机常空输出/超时**，见 agents.md——选它要有被自动跳过的预期，可用 `reasonix` 替补）。
- challenge 默认推荐：`codex` + `gemini`
- consult 默认推荐：用户指定的那个；未指定则给 2 个推荐
选项里明确写出"将调用 N 个外部 agent（消耗各自额度）"。只列 Step 0 中 `OK` 的 agent。用户可增减。

**A2. 分工模式**（两选一）：
- **全量模式（默认，交叉验证强）**：每个 agent 都评审/处理**全部内容**。多模型重叠覆盖，最能暴露
  盲区；综合时出一致性矩阵（都发现/多数/仅 1）。代价：更多 token、更慢。
- **分工模式（省额度、快）**：给每个 agent 分配**各自的关注面**，只看自己那块。例如 review 时
  `codex`→架构/数据库/测试、`reasonix`→UI/交互/逻辑、`opencode`→其余（错误处理/依赖/构建等）。范围由 Claude
  按 agent 特长和改动内容划分并在提示词里写明（见 prompts.md 的"评审范围"段）。代价：无重叠交叉
  验证，综合时按**范围拼合**而非一致性矩阵，某块只有一个模型看过要标注置信度有限。

分工划分示例（可按实际内容调整）：
- **review**：codex=架构/数据库/并发；reasonix=UI/交互/文案；gemini=跨模块影响/大局；
  qoderclicn=错误处理/边界；opencode=依赖/构建/配置。
- **challenge**：按攻击面分（输入/边界、并发/竞态、错误处理/回滚、资源/性能）。
- **brainstorm / consult**：无天然代码切面，按**视角**分——codex=技术选型/实现；gemini=整体架构/取舍；
  reasonix=风险与失败模式；（产品/UX 视角可派给 gemini）。

- **默认与少 agent**：AskUserQuestion 里**全量为预选项**，用户跳过/超时按全量走。**参与 agent < 3 时分工
  收益不大**（每面只 1 个模型看、又无交叉），直接建议全量；N=2 若坚持分工，就二分（如 codex=架构/数据库/
  并发/错误处理，qoderclicn=UI/交互/依赖/构建）。

### B. 文件系统边界
发给**每个**外部 agent 的提示词都必须前置 `references/prompts.md` 里的"文件系统边界"段落
（禁止读取**用户主目录下**的私有配置 `~/.claude/`、`~/.agents/`、`~/agents/` 等——注意是绝对路径，
**不**笼统禁止仓库内同名目录，业务代码若在 `agents/` 属正常评审对象；只看仓库代码；**禁止修改任何
文件，只输出评审/建议**）。

### C. 并行调用（后台执行，避免超时）
> 经验：慢模型（reasonix/codebuddy 等）在**前台被 `timeout 240` 卡死**——用户直接手调这些 CLI 从不
> 超时，是本 skill 自己的短超时 + 高推理强度 + 超大提示词共同造成的。因此**默认后台执行**。

**启动**：每个选中 agent 用**独立的 Bash 工具调用**、设 `run_in_background: true` 发出（同一条消息发多个
即并行）。后台任务**不受前台 300s 工具超时上限**约束，慢模型能跑完；完成时你会收到通知，再读其输出。

**关键：每个后台调用必须自包含**——后台是独立 shell，**不继承任何变量/函数**。因此每个调用开头
`source /tmp/codev-lib.sh`（Step 0 已暂存到该字面路径）拿回全部库函数，输出也走**确定性字面路径**
`/tmp/codev-out-<agent>.txt`（收到完成通知时你按此读；不能用随机 `mktemp`）。骨架简化为「source + 一行」：
```bash
# —— 非原生只读 agent（reasonix/qoderclicn/opencode/codebuddy）：隔离空目录只喂文本 ——
source /tmp/codev-lib.sh
PROMPT=/tmp/codev-prompt-reasonix.txt                          # 提示词文件（前一步已写好，字面路径）
codev_bg_sandboxed reasonix reasonix run "$(cat "$PROMPT")" --effort medium
# 首参是 agent 标签，其后是该 agent 的完整命令 argv（换成 agents.md 里目标 agent 的精确命令即可）。
# 库函数自动：umask 077 / ▶启动行 / 无-timeout 跳过 / mktemp 空目录 / 捕 agent 退出码(非 rm) / ✔或⚠️上报。

# —— 原生只读 agent（codex/gemini）：无需沙盒，在仓库根跑 ——
source /tmp/codev-lib.sh
cd "$(git rev-parse --show-toplevel)"
PROMPT=/tmp/codev-prompt-codex.txt
codev_bg_native codex codex review "$(cat "$PROMPT")" -c 'model_reasoning_effort="medium"'
```
- **推理强度默认 `medium`**（防慢）；发送前 `wc -c "$PROMPT"`，**超大（> 100KB）就精简**（只发相关 diff/
  文件，别把无关内容全塞进去——越大越慢越易超时）；
- **无 timeout 时**：`codev_bg_*` 会自动跳过该 agent（后台裸跑=永久挂起）；确要它参与就改前台串行或装 coreutils；
- **只读隔离**：codex/gemini 用 `codev_bg_native`（原生只读，可并行）；reasonix/qoderclicn/opencode/codebuddy
  用 `codev_bg_sandboxed`（空目录只喂文本，见 agents.md (a)/(b)）；
- **兜底**：若 `/tmp/codev-lib.sh` 不存在（Step 0 未暂存成功），退回把库函数体内联进调用（见 `bin/codev-lib.sh`）。

**收集**：收到完成通知 → 读该 agent 的**字面输出路径** `/tmp/codev-out-<agent>.txt`；`codev_report`
已在任务 stdout 里把结果翻成 `✔ 完成` / `⏭ 超时跳过` / `⚠️ 非零退出 exit=N`（含 stderr 头几行），据此
判断是否有效，超时/报错/空输出 → 不阻塞其它、如实告知。实时盯用 `Monitor` 跟踪该字面路径（见 D）。

### D. 运行时显示（当前 agent / 模型 / 交互内容）
让用户始终知道"现在谁在跑、用什么模型、在聊什么"：
运行时显示由两部分实现：**你（Claude）在发起/收到通知时打印状态板** + 后台任务自身 stdout 的
`▶/✔/⏭/⚠️` 行（由库函数 `codev_bg_*` / `codev_report` 打印）。二者结合让用户看到进度。
1. **启动即报**：发出这批后台调用的同时，你打印一次状态清单，每 agent 一行：
   `▶ codex（模型 GPT）｜ 范围：全量 ｜ 强度 medium ｜ 运行中…`（分工模式把"范围"写成该 agent 关注面）。
2. **实时交互内容**（可选）：想盯某个慢 agent，用 `Monitor`（已在 allowed-tools）跟踪它的**字面输出
   路径** `/tmp/codev-out-<agent>.txt`，它随文件新增行推事件、随进程结束自动停。**不要**用 `tail -f` 起
   后台任务（不自然结束、制造悬挂进程）；只想瞄一眼就用有界的 `tail -n 20 /tmp/codev-out-<agent>.txt`。
   （不为监控给 codex 加 `--json`——那样正文变 JSONL、E 的逐字呈现会展示机器码；监控只看纯文本流水。）
3. **完成即翻牌**：收到某 agent 完成通知后，把它那行更新为 `✔ codex 完成` / `⏭ reasonix 跳过（超时）` /
   `⚠️ opencode 非零退出`（与 `codev_report` 打印的一致）；**token/用时能取到才加** `（tokens N｜用时 Ss）`
   （仅 codex 可靠取 token，取不到就省略括号，别编造）。
4. 全部结束后进入 E 的**逐字呈现**。运行时显示只给"过程感"，不替代最终逐字原文。

### E. 忠实呈现
每个 agent 的原始输出用分隔框逐字呈现：

```
━━━ <AGENT>（模型：<model>）━━━━━━━━━━━━━━━━━━━━━━━━
<原始输出，逐字，不删改>
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ tokens: <n> ｜ 用时: <s>s
```

（逐字呈现的正文取自各 agent 的**字面输出路径** `/tmp/codev-out-<agent>.txt`（库函数写入的确定性路径）。
`tokens` 仅 codex 可靠取到——`grep -i "tokens used" /tmp/codev-err-<agent>.txt`；其余 agent 取不到就**省略
该字段**，不要编造。`用时` 可用 shell 计时或省略。）

### F. 跨模型综合
所有 agent 返回后，按 `references/synthesis.md`：
- **全量模式**：一致性矩阵（都发现 / 多数发现 / 仅某 agent 发现）+ Claude 裁决（采纳/存疑/驳回）；
- **分工模式**：按**关注面拼合**各 agent 结论（不做一致性矩阵，因无重叠），某块只有一个模型看过要
  标注"置信有限、无交叉验证"；
- review 模式额外给 **PASS / FAIL 门禁**（出现 P1/critical 即 FAIL）。

---

## Step 2A — brainstorm（头脑风暴 / 方案设计）

1. Claude 先基于需求与代码库快速产出 **v0 方案**（要解决什么、初步思路、关键取舍）。
2. 选 agent（通用机制 A）。
3. 并行发出（通用机制 B/C），用 prompts.md 的 **brainstorm 模板**：把需求 + Claude 的 v0
   方案发给每个 agent，要求它**独立给出自己的方案，并指出 v0 的风险/更好的替代**。
4. 运行时显示（D）→ 忠实呈现（E）→ 跨模型综合（F）：合并成一份带**取舍表 + 风险清单 + 推荐方案**的方案文档。
5. 问用户是否把方案写入文件（如 `docs/方案-<主题>.md`）。写文件由 Claude 执行：先 `mkdir -p docs`，
   并对 `<主题>` 做 sanitize（空格→`-`，去掉 `/ : *` 等非法字符）再拼文件名。

## Step 2B — review（多 agent 代码评审）

1. 确定 base（用户指定优先，否则按回退链取第一个成功的，并**验证该 commit 存在**）：
   ```bash
   BASE=$(git merge-base HEAD @{u} 2>/dev/null \
       || git merge-base HEAD origin/HEAD 2>/dev/null \
       || git merge-base HEAD origin/main 2>/dev/null \
       || git merge-base HEAD origin/master 2>/dev/null \
       || git merge-base HEAD main 2>/dev/null \
       || git merge-base HEAD master 2>/dev/null \
       || echo HEAD~1)
   git rev-parse --verify "$BASE^{commit}" >/dev/null 2>&1 \
     || { echo "base 无效（初始提交/浅克隆？）"; exit 1; }   # 停下：让用户指定 base，或改用 git diff --root HEAD
   ```
   **`exit 1`（base 无效）时你必须停下、用 AskUserQuestion 让用户指定 base 或确认改用 `git diff --root HEAD`，
   不得把非零退出当普通错误静默继续、在错误 base 上评审。** 确认 `git diff "$BASE"` 或未跟踪文件非空；
   两者皆空则告知"无改动可评审"并退出。**未跟踪新文件**也要纳入，用 NUL 分隔安全枚举（防文件名含空格/换行/前导 `-`）：
   ```bash
   git ls-files --others --exclude-standard -z | while IFS= read -r -d '' f; do
     git diff --no-index -- /dev/null "$f"      # 或直接附文件内容，提示词里标注"新增未跟踪文件"
   done
   ```
2. 选 agent（A）。
3. **发送前 secret 扫描**——扫的是**实际将发送的完整 payload**（tracked diff **+ 上面纳入的未跟踪
   文件内容**），不能只扫 `git diff`，否则未跟踪文件里的密钥会绕过：
   ```bash
   [ -z "$BASE" ] && { echo "BASE 未定义，拒绝扫描（会误把范围当成 working-vs-index）"; exit 1; }
   { git diff "$BASE"
     # BSD/macOS xargs 无 GNU 的 -r/--no-run-if-empty（`xargs -0 -r` 会 illegal option 直接失败、
     # 未跟踪文件整段不参与扫描）；用 `|| true` 吞空输入，`cat --` 防 `-` 开头文件名被当选项。
     git ls-files --others --exclude-standard -z | { xargs -0 cat -- 2>/dev/null || true; }
   } | grep -ainE '(api[_-]?key|secret|password|passwd|token|credential|-----BEGIN [A-Z ]*PRIVATE KEY-----|A(KIA|SIA)[0-9A-Z]{16})'
   # -a：二进制内容也按文本扫；ASIA：AWS STS 临时凭证前缀（AKIA 只覆盖长期密钥）。
   ```
   命中 → 停下，AskUserQuestion 让用户确认是否继续发送 / 先脱敏 / 缩小范围；未命中再继续。
4. 并行发出（B/C）：
   - `codex` 走 `codev_bg_native codex codex review "<prompt>"`——**gstack 式**：prompt 里含文件系统边界 +
     "请自己跑 `git diff <BASE>...HEAD` 只评审这些改动 + 关注点"，从而**不带 `--base`/`--commit`**（避开
     `[PROMPT]` 与它们的 argv 互斥）、也**不带 `-s`/`-C`**（review 不认这俩），须从仓库根跑。这样保住了
     自定义关注点（详见 agents.md）；
   - 其它 agent 用 prompts.md 的 **review 模板** + `git diff "$BASE"` 内容（经上面扫描后），走 `codev_bg_sandboxed`。
5. 运行时显示（D）→ 忠实呈现（E）→ 综合（F）+ **PASS/FAIL 门禁**。
6. 若此前对话里已跑过 Claude 自己的 `/code-review`，加一段"Claude vs 外部 agent"对比与
   一致率。
7. 询问用户是否让 Claude 修复被确认的问题（修复由 Claude 做）。

## Step 2C — challenge（对抗式挑战）

1. 确定对象（当前 diff / 指定文件 / 某个方案）。
2. 选 agent（A）。
3. 并行发出（B/C），用 prompts.md 的 **challenge 模板**：指令 agent "扮演对手，尽力找出会
   让它崩的输入、边界条件、并发/竞态、错误处理缺失、隐含假设"。
4. 运行时显示（D）→ 忠实呈现（E）→ 综合（F）：汇成"攻击面清单"，标注哪些是真问题、哪些已被现有代码处理。
5. 询问是否让 Claude 针对确认的漏洞补测试/加固。

## Step 2D — consult（咨询汇总）

1. 若用户点名了 agent 就用它；否则选 agent（A，默认 2 个）。
2. 并行发出（B/C），用 prompts.md 的 **consult 模板**：转述用户问题。
3. 运行时显示（D）→ 忠实呈现（E）→ 综合（F）：给出各 agent 观点 + Claude 的收敛结论。

## Step 2E — 全流程（默认）

串联执行，每个阶段之间**停下等用户确认**（不要一口气冲到底）：
1. **brainstorm**（Step 2A）→ 用户拍板方案。
2. **编码**：Claude 按方案与 CLAUDE.md 规范实现（Flutter 记得 build_runner / dart-define；
   新增引用立即查 import）。
3. **review**（Step 2B）→ 若 FAIL，Claude 修复后可再跑一轮。
4. **最终小结**（wrap-up，区别于 F 的"跨模型综合"）：输出做了什么、外部 agent 的关键贡献、遗留项。

---

## 完成后

简短小结：跑了哪些模式、调用了哪些 agent、跨模型综合的关键结论、门禁结果、遗留项。
不要复述外部 agent 的原文（上面已逐字呈现过）。
