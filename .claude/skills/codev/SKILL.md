---
name: codev
description: >
  多 agent 协作开发编排器。在开发全流程中调用外部 agent CLI（codex / gemini /
  reasonix / qodercli / opencode / codebuddy，各自背后是不同大模型）做方案头脑风暴、
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
---

# codev — 多 agent 协作开发

你正在运行 `/codev` skill。它把 Claude Code 变成一个**编排器**：Claude 负责理解需求、
主导编码；在关键节点把方案或代码交给**其它 agent CLI**（每个背后是不同的大模型）做
独立的头脑风暴、评审、对抗挑战，再由 Claude 做**跨模型综合**。核心信念：不同模型的
盲区不同，交叉验证能显著减少 bug 与遗漏。

**铁律**
- Claude 是**唯一改文件的人**。外部 agent 一律**只读**运行，只输出方案 / 评审 / 质疑，
  绝不让它们改仓库文件。**只读靠双重保障**：能用原生只读旗标的用旗标（codex `-s read-only`、
  gemini `--approval-mode plan`）；无原生只读的（reasonix / codebuddy / qodercli / opencode）
  除提示词强约束外，**必须**在调用前后用 `git status --porcelain` 快照核对，发现新增/改动即
  停下、把差异逐字上报用户由其处置（**不自动回滚**，以免误删用户未提交的工作；见 `agents.md`
  只读风险总结）。
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
for c in codex gemini reasonix qodercli opencode codebuddy; do
  if command -v "$c" >/dev/null 2>&1; then echo "OK   $c"; else echo "MISS $c"; fi
done
# 探测 timeout 二进制（macOS 原生无 timeout，只有装了 coreutils 才有 gtimeout）
TO=$(command -v timeout || command -v gtimeout || true)
TP="${TO:+$TO 240}"; TP300="${TO:+$TO 300}"      # 空值安全：$TO 为空 → 前缀为空串
echo "timeout -> ${TO:-MISSING}"
```

- 只把标 `OK` 的 agent 列入后续可选项。
- 后续所有 agent 命令统一用 `$TP <cmd>`（codex review 用 `$TP300`）。**切勿**写成 `$TO 240 <cmd>`：
  `$TO` 为空时会退化成把 `240` 当命令执行。用 `$TP`（为空时整段安全展开为空）。
- 若 `timeout -> MISSING`（stock macOS 常见）：提示用户 `brew install coreutils`；未装时 `$TP` 为空、
  命令裸跑，靠 Bash 工具自身 timeout 兜底。**注意**：裸跑时非原生只读 agent 卡死会导致后置快照
  核对跑不到，因此 `$TP` 缺失时优先只让非原生 agent 处理提示词文本、不接触工作区。
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

**推理强度覆盖**：若用户输入含 `--xhigh`，从提示词里剔除该词，并对**支持推理强度旗标的 agent**
用最高档（codex `xhigh`、reasonix/qodercli `max`）。gemini/opencode/codebuddy 无此旗标，静默忽略
即可。否则用各模式默认强度（见 agents.md）。

---

## 通用机制（所有 fan-out 模式共用）

### A. 选 agent（AskUserQuestion）
在任何要并行调用外部 agent 的节点，先给**推荐组合**让用户确认：

- brainstorm 默认推荐：`gemini`（大上下文发散）+ `reasonix`（低成本快速）+ `codex`（严谨挑刺）
- review 默认推荐：`codex`（深度审查）+ `qodercli`（代码评审，稳定）。想要中文语境可再加
  `codebuddy`，但它常出现空输出（见 agents.md），不作默认第二意见。
- challenge 默认推荐：`codex` + `gemini`
- consult 默认推荐：用户指定的那个；未指定则给 2 个推荐

选项里明确写出"将调用 N 个外部 agent（消耗各自额度）"。只列 Step 0 中 `OK` 的 agent。
用户可增减。

### B. 文件系统边界
发给**每个**外部 agent 的提示词都必须前置 `references/prompts.md` 里的"文件系统边界"段落
（禁止读取**用户主目录下**的私有配置 `~/.claude/`、`~/.agents/`、`~/agents/` 等——注意是绝对路径，
**不**笼统禁止仓库内同名目录，业务代码若在 `agents/` 属正常评审对象；只看仓库代码；**禁止修改任何
文件，只输出评审/建议**）。

### C. 并行调用
把选中 agent 的调用命令放在**同一条消息里的多个 Bash 工具调用**中并行发出。每条命令：
- 用 `references/agents.md` 里对应 agent 的**精确命令 + 只读参数**；
- **提示词写入临时文件**，命令用 `"$(cat "$PROMPT")"` 引用——绝不把 diff/需求原文内联进命令行
  （防 shell 注入 + 防超 `ARG_MAX`）；发送前先 `wc -c "$PROMPT"`，过大时先按文件筛选或让用户确认范围；
- 用 `$TP …`（Step 0 生成的空值安全前缀；review 用 `$TP300`）包裹；**Bash 工具的 `timeout` 参数
  恒设为内层的 1.1 倍以上**：内层 240s → Bash 工具传 `"timeout": 264000`；codex review 内层 300s →
  `"timeout": 330000`。避免外层先杀导致拿不到内层的 124 退出码；
- stdout→`$TMPOUT`（逐字呈现）、stderr→`$TMPERR`（读 token/诊断），每 agent 独立文件；stdin `< /dev/null`。
- **只读隔离**：原生只读的 codex/gemini 可放心并行；非原生只读的 reasonix/qodercli/opencode/codebuddy
  在并行下快照无法归因、且会互相污染工作区 → 让它们**只处理提示词文本、不接触真实仓库目录**
  （首选），否则改为串行并各自前后快照核对（见 agents.md）。

- **变量不跨调用**：每个并行 Bash 调用是独立 shell，Step 0/前置步骤里的 `$TP/$TP300/$PROMPT/$TMPOUT/
  $TMPERR/$BASE` 等**不会**带过来；每个调用内需重新定义这些变量，或直接用**字面值**（mktemp 生成的
  文件路径、解析好的 base commit SHA）。文件在磁盘持久，变量不持久。

某个 agent 超时 / 报错 / 无输出：不阻塞其它，按 agents.md 的话术跳过并如实告知用户。

### D. 忠实呈现
每个 agent 的原始输出用分隔框逐字呈现：

```
━━━ <AGENT>（模型：<model>）━━━━━━━━━━━━━━━━━━━━━━━━
<原始输出，逐字，不删改>
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ tokens: <n> ｜ 用时: <s>s
```

（逐字呈现的正文取自各 agent 的 `$TMPOUT`。`tokens` 仅 codex 可靠取到——`grep -i "tokens used" "$TMPERR"`；
其余 agent 取不到就**省略该字段**，不要编造。`用时` 可用 shell 计时或省略。）

### E. 跨模型综合
所有 agent 返回后，按 `references/synthesis.md`：
- 一致性矩阵：哪些结论"都发现 / 多数发现 / 仅某 agent 发现"；
- Claude 给最终判断（哪些采纳、哪些存疑、为什么）；
- review 模式额外给 **PASS / FAIL 门禁**（出现 P1/critical 即 FAIL）。

---

## Step 2A — brainstorm（头脑风暴 / 方案设计）

1. Claude 先基于需求与代码库快速产出 **v0 方案**（要解决什么、初步思路、关键取舍）。
2. 选 agent（通用机制 A）。
3. 并行发出（通用机制 B/C），用 prompts.md 的 **brainstorm 模板**：把需求 + Claude 的 v0
   方案发给每个 agent，要求它**独立给出自己的方案，并指出 v0 的风险/更好的替代**。
4. 忠实呈现（D）→ 跨模型综合（E）：合并成一份带**取舍表 + 风险清单 + 推荐方案**的方案文档。
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
   （`exit 1` 后必须停下询问用户，别静默继续。）确认 `git diff "$BASE"` 或未跟踪文件非空；两者皆空则
   告知"无改动可评审"并退出。**未跟踪新文件**也要纳入，用 NUL 分隔安全枚举（防文件名含空格/换行/前导 `-`）：
   ```bash
   git ls-files --others --exclude-standard -z | while IFS= read -r -d '' f; do
     git diff --no-index -- /dev/null "$f"      # 或直接附文件内容，提示词里标注"新增未跟踪文件"
   done
   ```
2. 选 agent（A）。
3. **发送前 secret 扫描**——扫的是**实际将发送的完整 payload**（tracked diff **+ 上面纳入的未跟踪
   文件内容**），不能只扫 `git diff`，否则未跟踪文件里的密钥会绕过：
   ```bash
   { git diff "$BASE"; git ls-files --others --exclude-standard -z | xargs -0 cat 2>/dev/null; } \
     | grep -inE '(api[_-]?key|secret|password|passwd|token|credential|BEGIN [A-Z ]*PRIVATE KEY|AKIA[0-9A-Z]{16})'
   ```
   命中 → 停下，AskUserQuestion 让用户确认是否继续发送 / 先脱敏 / 缩小范围；未命中再继续。
4. 并行发出（B/C）：
   - `codex` 用原生 `codex review … -s read-only --base "$BASE"`（见 agents.md）；
   - 其它 agent 用 prompts.md 的 **review 模板** + `git diff "$BASE"` 内容（经上面扫描后）。
5. 忠实呈现（D）→ 综合（E）+ **PASS/FAIL 门禁**。
6. 若此前对话里已跑过 Claude 自己的 `/code-review`，加一段"Claude vs 外部 agent"对比与
   一致率。
7. 询问用户是否让 Claude 修复被确认的问题（修复由 Claude 做）。

## Step 2C — challenge（对抗式挑战）

1. 确定对象（当前 diff / 指定文件 / 某个方案）。
2. 选 agent（A）。
3. 并行发出（B/C），用 prompts.md 的 **challenge 模板**：指令 agent "扮演对手，尽力找出会
   让它崩的输入、边界条件、并发/竞态、错误处理缺失、隐含假设"。
4. 忠实呈现（D）→ 综合（E）：汇成"攻击面清单"，标注哪些是真问题、哪些已被现有代码处理。
5. 询问是否让 Claude 针对确认的漏洞补测试/加固。

## Step 2D — consult（咨询汇总）

1. 若用户点名了 agent 就用它；否则选 agent（A，默认 2 个）。
2. 并行发出（B/C），用 prompts.md 的 **consult 模板**：转述用户问题。
3. 忠实呈现（D）→ 综合（E）：给出各 agent 观点 + Claude 的收敛结论。

## Step 2E — 全流程（默认）

串联执行，每个阶段之间**停下等用户确认**（不要一口气冲到底）：
1. **brainstorm**（Step 2A）→ 用户拍板方案。
2. **编码**：Claude 按方案与 CLAUDE.md 规范实现（Flutter 记得 build_runner / dart-define；
   新增引用立即查 import）。
3. **review**（Step 2B）→ 若 FAIL，Claude 修复后可再跑一轮。
4. **synthesize**：输出最终小结（做了什么、外部 agent 的关键贡献、遗留项）。

---

## 完成后

简短小结：跑了哪些模式、调用了哪些 agent、跨模型综合的关键结论、门禁结果、遗留项。
不要复述外部 agent 的原文（上面已逐字呈现过）。
