---
name: codev
description: >
  Use when 用户要多个外部模型（codex / gemini / reasonix / qoderclicn / opencode / codebuddy）
  对方案、代码改动、spec 或实施计划文档做独立评审、头脑风暴、对抗挑战或咨询，并由 Claude 做跨模型综合。
  触发词："多 agent 评审 / 第二意见 / 头脑风暴 / 跨模型 / 让 codex 挑刺 / 评审我的改动 / 外审 /
  评审这份 spec·计划 / 第 N 轮评审 / codev / codev review / codev brainstorm / codev challenge / codev consult"。
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
  - Agent
---

# codev — 多 agent 协作开发

你正在运行 `/codev` skill。它把 Claude Code 变成一个**编排器**：Claude 负责理解需求、
主导编码；在关键节点把方案或代码交给**其它 agent CLI**（每个背后是不同的大模型）做
独立的头脑风暴、评审、对抗挑战，再由 Claude 做**跨模型综合**。核心信念：不同模型的
盲区不同，交叉验证能显著减少 bug 与遗漏。

**铁律**
- Claude 是**唯一改文件的人**。外部 agent 一律**只读**运行，只输出方案 / 评审 / 质疑，
  绝不让它们改仓库文件。**只读靠分级保障**：
  - **沙盒级只读的两个**（codex `-s read-only`、gemini `--approval-mode plan`）→ `codev_bg_native`，
    在**真实仓库根**跑，自己读文件、跑 `git diff`。
  - **其余四个**（reasonix / qoderclicn / opencode / codebuddy）→ `codev_bg_sandboxed`，在
    **隔离沙盒**里跑：cwd 是 `mktemp -d` 出来的沙盒，真实仓库**不在**里面，但沙盒内铺了一份
    `./repo` —— 工作区（含未提交改动）的**只读副本**。它们既能读全部代码，写入默认只落到副本上、
    随沙盒删掉。再叠加各自的只读/禁工具旗标（见 `agents.md` 表格）+ 提示词边界，共三层。
    **这是 cwd 隔离 + 副本/母本 `a-w`，不是 OS 级沙盒**：防的是误写；同用户进程刻意枚举 `$TMPDIR`
    仍能找到并改回权限，防不了恶意 agent。仓库敏感就用 `CODEV_SANDBOX_MODE=text`。
  - **别把第二组挪进真实仓库**，除非确认其旗标是**沙盒级**而非"框架答应不调用写工具"
    （opencode `--agent plan` 就是反例：`edit` 禁了但 `bash` 没禁）。确需如此则必须逐 agent
    前后 `git status --porcelain` 快照核对 + 串行，发现改动即停下、逐字上报用户由其处置
    （**不自动回滚**，以免误删用户未提交的工作；见 `agents.md` 只读风险总结）。
- **沙盒 agent 的提示词必须带「工作副本」段落**（prompts.md），告诉它 `./repo` 可读——
  否则它不知道自己有代码视野，会退化成只能对着内联文本猜，产出"无法验证前提"式的假阳性。
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
# 建【本次会话专属目录】并把共享函数库拷进去：后台是独立 shell、不继承变量/函数，靠字面路径 source
# 拿到它。per-session 目录（而非固定 /tmp/codev-*）避免并发的两个 /codev run 互相覆盖输出、以及
# 收尾清理误删对方文件。<SKILL_DIR> 用本 skill 头部给出的 "Base directory" 字面替换。
CODEV_DIR=$(mktemp -d -t codev.XXXXXX) || { echo "FATAL: 无法建会话目录"; exit 1; }
export CODEV_DIR
cp "<SKILL_DIR>/bin/codev-lib.sh" "$CODEV_DIR/codev-lib.sh" \
  || { echo "FATAL: codev-lib.sh 未找到——检查 <SKILL_DIR> 是否已替换成头部 Base directory 字面值"; exit 1; }
chmod 600 "$CODEV_DIR/codev-lib.sh"
source "$CODEV_DIR/codev-lib.sh" || { echo "FATAL: source 库失败"; exit 1; }
echo "会话目录：$CODEV_DIR"   # ← 记住这个字面路径：后续每个后台调用都用它 source 库、读输出
codev_probe        # 列出 OK/MISS 的 agent（codex 附鉴权 AUTH_OK/AUTH_FAILED）+ 每个 agent 的【近期 3 次结果】
                   # （跨会话账本，类别 ok/quota/auth/turns/timeout/empty/error）+ timeout 与 CODEV_TIMEOUT
                   # 顺带 codev_sbox_gc：回收上一轮进程被杀时漏下的沙盒（里面有仓库副本，会堆磁盘）
```

- **近期结果账本**（`~/.local/state/codev/ledger.tsv`，库自动记）是选 agent 的第一依据：某 agent 最近
  两次都是 `quota`/`auth` → 默认不放进推荐组合，只在用户点名时才用并提前说明"上次是额度耗尽"；
  最近是 `timeout`/`turns` → 提示"上次超时，这次收窄范围/提高 CODEV_TIMEOUT"。
- **发现台账**（`~/.local/state/codev/findings.tsv`，Claude 在综合后用 `codev_finding_add` 逐条记）：
  `codev_stats` 给每个 agent/模型的"声称 P1 里亲验成立的比例"和"独家且成立"数。样本少于 20 条时只当参考，
  不据此改推荐组合；累积够了在 A1 的选项描述里附一句"近 N 条 P1 成立率 x/y"。
- **超时**：`CODEV_TIMEOUT` 默认 600s，只是兜底卡死进程的安全网。**核实型任务（要求 agent 进仓库逐条核实、
  或文档 > 20KB）在发起后台调用前 `export CODEV_TIMEOUT=1200`**（每个后台调用自包含，须在各自命令里设）。

- 只把标 `OK` 的 agent 列入后续可选项。
- 后续所有 agent 调用统一走库函数 `codev_bg_sandboxed` / `codev_bg_native`（内部用 `codev_run` 封装
  timeout）。`CODEV_TIMEOUT` 只是**兜底真正卡死的进程**的安全网，不是常规上限——常规靠**后台执行**（通用机制 C）
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
| `/codev review [关注点]` | **多 agent 代码评审**（评审 diff） | Step 2B |
| `/codev review <文档路径> [关注点]` | **文档评审**（spec / 实施计划 / 方案，无 diff） | Step 2F |
| `/codev challenge [焦点]` | **对抗式挑战** | Step 2C |
| `/codev consult [问题]` | **咨询汇总** | Step 2D |
| `/codev <一段需求描述>` | **全流程**（默认） | Step 2E |
| `/codev`（无参数） | **自动检测** | 见下 |

**参数里的两个可选开关**（各模式通用，解析后从提示词里剔除）：
- `--agents codex,reasonix`：用户已点名 agent 组合 → **跳过 A1 的 AskUserQuestion**，直接用（仍只取 Step 0 为 OK 的）。
  用户在本对话里明说过"就用 X+Y，别再问"也同样生效，直到用户改口。
- `--round N`：多轮评审的轮次（默认 1）。N ≥ 2 时按 synthesis.md §6「多轮回流协议」走：提示词标题带轮次、
  附上一轮发现清单（含已驳回项）要求回归核对、内联两版文档的 `git diff`、外审前先做 fresh-subagent 自审。
- `--auto [--max-rounds K]`（默认 K=3，上限 5）：自动连跑多轮直到收敛，**只在开始时问一次**（agent 组合 +
  轮次上限 + 预算），之后每轮自审 → 外审 → 综合 → 回流 → `codev_commit_round` 提交，不再逐轮询问。
  停止条件与流程见 synthesis.md §6.3。没有 `--auto` 时每轮结束仍停下问用户是否开下一轮。
- `review` 的首个非开关参数若是**存在的文件路径**（`.md`/`.txt`/`.rst`），就是文档评审（Step 2F），不是关注点。

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

**A1. 调用哪些 agent**（给推荐组合；**先看 Step 0 账本的近期结果，再套下面的默认**）：
- review / 文档评审默认推荐：`codex`（真仓库、最稳）+ `reasonix`（沙盒副本、提示词 ≤45KB 时稳）；
  第三席按账本挑：`codebuddy`（中文、核实型须 `--max-turns 64` + 收窄 3-5 条）或 `qoderclicn`——
  二者近期若是 `quota`/`auth` 就别推荐。
- brainstorm 默认推荐：`codex` + `reasonix` + `gemini`（大上下文发散；免费档常限流，账本会显示）
- challenge 默认推荐：`codex` + `reasonix`
- consult 默认推荐：用户指定的那个；未指定则给 2 个推荐
- `opencode` 极慢，只在用户点名时用。
选项里明确写出"将调用 N 个外部 agent（消耗各自额度）"，账本里近期失败的 agent 在选项描述里注明类别与时间。
只列 Step 0 中 `OK` 的 agent。用户可增减。**用户已用 `--agents` 或在对话里点名 → 不弹问，直接用。**

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

### B. 文件系统边界 + 工作副本
发给**每个**外部 agent 的提示词都必须前置 `references/prompts.md` 里的"文件系统边界"段落
（禁止读取**用户主目录下**的私有配置 `~/.claude/`、`~/.agents/`、`~/agents/` 等——注意是绝对路径，
**不**笼统禁止仓库内同名目录，业务代码若在 `agents/` 属正常评审对象；只看仓库代码；**禁止修改任何
文件，只输出评审/建议**）。

**沙盒 agent 额外前置「工作副本」段落**（同文件）：告诉它 cwd 下的 `./repo` 是工作区只读副本、
可以自由 grep/读文件去核实，且 `./repo` 无 `.git`（git 命令跑不了，diff 已内联）。
漏掉这段 = 副本白铺。

**评审/挑战/文档评审模板还要带「两档结论」**：强制 agent 把结论分成【已查证】和【需进一步核实的假设】
两栏，别因为看不到某处代码就给整体 FAIL。第二栏由 F 之前的事实核查环节收口（见 synthesis.md 0.5）。

**发送前 secret 扫描——所有 fan-out 模式都做，不只 review。** `codev_bg_sandboxed` 铺 `./repo` 副本
**不分模式**：brainstorm / challenge / consult 同样把整个工作区发给沙盒 agent。副本模式（默认）下先跑
Step 2B 第 3 步的整仓扫描；`CODEV_SANDBOX_MODE=text` 下扫将发送的提示词文件。命中就停下问用户。
README 对用户的承诺是"发给外部模型前会做 secret 扫描"，这一条让它在每个模式都成立。

### C. 并行调用（后台执行，避免超时）
> 经验：慢模型（reasonix/codebuddy 等）在**前台被 `timeout 240` 卡死**——用户直接手调这些 CLI 从不
> 超时，是本 skill 自己的短超时 + 高推理强度 + 超大提示词共同造成的。因此**默认后台执行**。

**启动**：每个选中 agent 用**独立的 Bash 工具调用**、设 `run_in_background: true` 发出（同一条消息发多个
即并行）。后台任务**不受前台 300s 工具超时上限**约束，慢模型能跑完；完成时你会收到通知，再读其输出。

**关键：每个后台调用必须自包含**——后台是独立 shell，**不继承任何变量/函数**。因此每个调用开头先
`CODEV_DIR=<会话目录>`（用 Step 0 打印的**字面路径**替换，如 `/tmp/codev.AbC123`）再
`source "$CODEV_DIR/codev-lib.sh"` 拿回全部库函数；输出也走会话目录内的**字面路径**
`$CODEV_DIR/codev-out-<agent>.txt`（收到完成通知时你按此读；不能用随机 `mktemp`）。骨架「设 CODEV_DIR + source + 一行」：
```bash
# —— 非原生只读 agent（reasonix/qoderclicn/opencode/codebuddy）：隔离沙盒 + ./repo 只读副本 ——
CODEV_DIR=<会话目录>; source "$CODEV_DIR/codev-lib.sh"    # <会话目录> = Step 0 打印的字面路径
cd "$(git rev-parse --show-toplevel)"   # 【必须】铺母本靠 cwd 定位仓库：后台 shell 的 cwd 不保证在仓库内，
                                        # 漏了这行会静默退回空目录模式（agent 重新变瞎，且 ▶ 行才看得出来）
PROMPT="$CODEV_DIR/codev-prompt-reasonix.txt"            # 提示词文件（前一步已写好，含「工作副本」段）
export CODEV_TIMEOUT=1200               # 核实型/大文档任务才加；普通 diff 评审用默认 600
codev_bg_sandboxed reasonix reasonix run "$(cat "$PROMPT")" --effort high --metrics "$CODEV_DIR/codev-metrics-reasonix.json" -p
# 首参是 agent 标签，其后是该 agent 的完整命令 argv（换成 agents.md 里目标 agent 的精确命令即可）。
# ⚠️ 各 agent 的必备旗标不同，务必照 agents.md 抄，别省：
#   reasonix   --effort high --metrics <json> -p （medium 会直接报错退出，它是"默认 medium"的例外；metrics 给 token）
#   qoderclicn --tools "Read,Glob,Grep" -p "…"   （只读工具白名单；别用 --tools ""，那会连读也禁掉）
#   codebuddy  --effort minimal --max-turns 64 --tools "Read,Glob,Grep" -p "…"（核实型 64；纯咨询 12）
#   opencode   run --agent plan          （很慢，务必后台）
# 库函数自动：▶启动行 / 无-timeout 跳过并清空旧输出 / mktemp 沙盒 + ./repo 只读副本 /
#            umask 077(子shell内) / 捕 agent 退出码 / 收尾删沙盒 / ✔或⚠️上报。
# 副本超体积闸门（默认 100MB）或非 git 仓库时自动退回空目录模式，▶ 行会标出；
# 想强制旧的"空目录只喂文本"：调用前 export CODEV_SANDBOX_MODE=text。

# —— 原生只读 agent（codex/gemini）：无需沙盒，在仓库根跑 ——
CODEV_DIR=<会话目录>; source "$CODEV_DIR/codev-lib.sh"
cd "$(git rev-parse --show-toplevel)"
PROMPT="$CODEV_DIR/codev-prompt-codex.txt"
codev_bg_native codex codex review "$(cat "$PROMPT")" -c 'model_reasoning_effort="medium"'
```
- **推理强度默认 `medium`**（防慢）；**例外：reasonix 必须 `high`/`max`**（DeepSeek thinking 模型
  拒绝 medium，实测直接 exit=1）；
- **提示词体积**（实测阈值，超了就停下精简，不是"建议"）：发送前 `wc -c "$PROMPT"`——
  通用 **≤ 50KB**；reasonix **≤ 45KB**（超过会 `context canceled` 零输出）；codebuddy **≤ 25KB 且核实范围
  收窄到 3-5 条**。精简的第一手段是**路径引用代替内联**：文档/代码在工作区里的，codex/gemini 在真仓库直接读、
  沙盒 agent 去 `./repo/<路径>` 读，提示词只给路径 + 章节目录 + 核实清单（prompts.md「文档评审模板」）。
  实测同一份 52KB 计划：内联版 reasonix 600s 超时零输出，4KB 路径版 codex 顺利出稿。
  **只在文档不在工作区（或被 .gitignore、进不了副本）时才内联**；
- **开放式"逐条核对"必超时**（codex / qoderclicn / reasonix 都实测过 600s 双杀）：核实型提示词一律
  **点名 3-8 个最关键论断**（文件/函数/表名）让它核实，其余凭文本判断；这条对所有 agent 通用，不只 codebuddy；
- **reasonix 加 `--metrics "$CODEV_DIR/codev-metrics-reasonix.json"`**（实测可用），E 呈现时才有 token/成本；
- **模型名进账本**：每个后台调用里 `export CODEV_MODEL_<agent>=<模型>`（值取自你传的 `-m/--model`，或该 CLI 的
  默认模型；codex 不用设，库从 stderr banner 取）。没设就记 `unknown`，commit trailer 与统计都会失真；
- **无 timeout 时**：`codev_bg_*` 会自动跳过该 agent（后台裸跑=永久挂起）并清空其旧输出文件；确要它参与就改前台串行或装 coreutils；
- **只读隔离**：codex/gemini 用 `codev_bg_native`（沙盒级只读，在真实仓库根跑，可并行）；
  reasonix/qoderclicn/opencode/codebuddy 用 `codev_bg_sandboxed`（隔离沙盒 + `./repo` 只读副本，
  见 agents.md (a)/(a')/(b)）；
- **库缺失即中止**：Step 0 的 `cp`/`source` 已带 `|| exit 1`，库拷贝失败会直接停下报错（不再"手抄内联"——
  98 行库靠人肉内联极易出错）。若真遇到，检查 `<SKILL_DIR>` 是否替换成头部 Base directory 字面值后重跑 Step 0。

**收集**：收到完成通知 → **先看任务 stdout 里 `codev_report` 的翻牌行，再读输出文件**。翻牌分七类：
`✔ 完成` / `⏭ 超时` / `⛔ 额度/限流` / `⛔ 鉴权失败` / `⚠️ turn 预算耗尽` / `⚠️ 空输出` / `⚠️ 非零退出`，
非 ✔ 的一律**本轮无效**：不呈现其输出文件内容（额度错误串常被打到 stdout，exit 还是 0——qoderclicn 实测），
不计入矩阵，如实告知类别与 stderr 错误行（含 429 的重置时间），不阻塞其它 agent。
`✔` 但附"stderr 含错误行"→ 正文可能被截断，呈现前核对是否有完整结论段。实时盯用 `Monitor` 跟踪输出路径（见 D）。
全部 agent 结束后跑一次 `codev_session_summary`（用时/tokens/成本一览）并原样打印。

### D. 运行时显示
两部分：**你在发起/收到通知时打印状态板** + 后台任务 stdout 的 `▶/✔/⏭/⛔/⚠️` 行（库函数打印）。
1. 启动即报，每 agent 一行：`▶ codex（模型 gpt-5.6-sol）｜ 范围：全量 ｜ 强度 medium ｜ 运行中…`（分工模式"范围"写关注面）。
2. 想盯某个慢 agent：`Monitor` 跟踪 `$CODEV_DIR/codev-out-<agent>.txt`；**不要**后台 `tail -f`（悬挂进程）；不为监控给 codex 加 `--json`。
3. 完成即翻牌：照抄 `codev_report` 的翻牌行（类别 + 用时/tokens/成本，取不到就不写）。
4. 全部结束后打印 `codev_session_summary`，再进 E。

### E. 忠实呈现
每个 agent 的原始输出用分隔框逐字呈现：

```
━━━ <AGENT>（模型：<model>）━━━━━━━━━━━━━━━━━━━━━━━━
<原始输出，逐字，不删改>
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ tokens: <n> ｜ 用时: <s>s
```

（逐字呈现的正文取自各 agent 的**字面输出路径** `$CODEV_DIR/codev-out-<agent>.txt`。`tokens`/`用时` 直接抄
`codev_report` 翻牌行括号里的值（codex 取自 stderr "tokens used"、reasonix 取自 `--metrics` JSON、用时由库计时）；
取不到就**省略该字段**，不要编造。）

### F. 跨模型综合
所有 agent 返回后，按 `references/synthesis.md`：
- **先做事实核查回填**（synthesis.md 0.5，**不可跳过**）：把各 agent「需进一步核实的假设」栏合并成
  一张清单，逐条由 Claude 自己读代码核实、或交给 codex（有真实仓库权限）核实，回填
  成立/不成立/待定后再进矩阵。**agent 因看不到代码给的整体 FAIL 不直接采纳**；
- **全量模式**：一致性矩阵（都发现 / 多数发现 / 仅某 agent 发现）+ Claude 裁决（采纳/存疑/驳回）；
- **分工模式**：按**关注面拼合**各 agent 结论（不做一致性矩阵，因无重叠），某块只有一个模型看过要
  标注"置信有限、无交叉验证"；
- **先给每条发现编号** `r<轮次>-<agent>-<两位序号>`（如 `r2-codex-03`），矩阵、裁决、回归核对、已驳回清单全部引用编号
  （synthesis.md 0.4）；综合完成后逐条 `codev_finding_add` 记入发现台账；
- **P1 采纳前必须 Claude 亲验前提**（synthesis.md 0.6，**不分 A/B 栏**）：agent 标"已查证"的也翻过车
  （枚举存在≠路径可达、"同构"未看触发时序、grep 失败被说成"不存在"）；agent 之间矛盾**以代码为准**；
- review 模式额外给 **PASS / FAIL 门禁**（出现**已亲验成立**的 P1/critical 即 FAIL）；
- 多轮评审（`--round N`）按 synthesis.md §6：回归核对上一轮 + 轮间自审 + 收敛判据。

---

## Step 2A — brainstorm（头脑风暴 / 方案设计）

1. Claude 先基于需求与代码库快速产出 **v0 方案**（要解决什么、初步思路、关键取舍）。
2. 选 agent（通用机制 A）。secret 扫描（通用机制 B：副本模式扫整仓，text 模式扫提示词）。
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
     git diff --no-index -- /dev/null "$f" || true   # 或直接附文件内容，提示词里标注"新增未跟踪文件"
   done
   ```
   `git diff --no-index` **有差异就退出 1**，即每个非空的未跟踪文件都会让它返回 1——这是正常输出，
   不是上一段说的"base 无效"。`|| true` 吞掉它，否则把这段和 base 检查放进同一次 Bash 调用时，
   最后的 rc=1 会被误读成 base 无效而停下问用户；用 `&&` 串到后面的命令上则后面的全不执行。
2. 选 agent（A）。
3. **发送前 secret 扫描**——扫的是**实际将发送的完整 payload**。⚠️ **`./repo` 副本模式下 payload 是
   整个工作区，不是 diff**：沙盒 agent 能读副本里任何文件并发给它自己的模型，所以只扫 diff 等于漏掉
   绝大部分实际外发内容。按模式选范围：
   ```bash
   # 只有 text 模式的范围依赖 BASE（副本模式扫整仓、2F 文档评审根本没有 BASE），守卫只在那条分支前做，
   # 而且必须放在管道【外面】：写进管道左段的子 shell 里，exit 1 只退出那个子 shell，grep 照样收到空输入
   # 返回 1，"拒绝扫描"就和"扫过了没命中"分不清。
   [ "${CODEV_SANDBOX_MODE:-repo}" = repo ] || [ -n "$BASE" ] \
     || { echo "text 模式需要 BASE（否则 git diff 会误把范围当成 working-vs-index），先回第 1 步"; exit 1; }
   # 先确认枚举本身成功：管道里 git ls-files 失败被 2>/dev/null 吞掉后 grep 收到空输入会返回 1，
   # 那会被下面当成"干净"。非 git 目录 / 仓库损坏必须在这里就停。
   git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "SCAN: 不在 git 仓库内，按命中处理"; exit 1; }
   n=$({ git ls-files; git ls-files --others --exclude-standard; } 2>/dev/null | wc -l | tr -d ' ')
   [ "${n:-0}" -gt 0 ] || { echo "SCAN: 枚举为空（tracked 与未忽略 untracked 都没有），按命中处理"; exit 1; }
   # 空输入用 `|| true` 吞退出码（macOS 的 BSD xargs 其实接受 -r 且空输入本就不执行，这里不依赖它只是少一个假设）；
   # `cat --` 防 `-` 开头文件名被当选项。
   if [ "${CODEV_SANDBOX_MODE:-repo}" = repo ]; then
     # 副本模式：扫【将进副本的全部文件】（= tracked + 未忽略 untracked，与 codev_repo_master 同源）。
     # 密钥【文件】已被副本过滤挡掉，所以这一轮真正要抓的是【硬编码在源码里】的密钥。
     # 【路径名也进扫描流】：过滤按扩展名放行的 credentials.sql / credentials.tf 这类，内容里未必有关键词，
     # 靠文件名才抓得到——扫描集合必须与实际发送的集合（路径 + 内容）一致。
     { git ls-files; git ls-files --others --exclude-standard
       { git ls-files -z; git ls-files --others --exclude-standard -z; } | { xargs -0 cat -- 2>/dev/null || true; }; }
   else
     # text 模式：外发的只有提示词，即 diff + 纳入的未跟踪文件（路径清单也会进 codex 提示词，所以文件名同样要扫）。
     { git diff "$BASE"
       git ls-files --others --exclude-standard
       git ls-files --others --exclude-standard -z | { xargs -0 cat -- 2>/dev/null || true; } }
   fi | grep -ainE '(api[_-]?key|secret|password|passwd|token|credential|-----BEGIN [A-Z ]*PRIVATE KEY-----|A(KIA|SIA)[0-9A-Z]{16})'
   case $? in 0) echo "SCAN: 命中";; 1) echo "SCAN: 干净";; *) echo "SCAN: 扫描本身出错，按命中处理";; esac
   # -a：二进制内容也按文本扫；ASIA：AWS STS 临时凭证前缀（AKIA 只覆盖长期密钥）。
   # grep 的退出码：0 命中 / 1 干净 / 2 出错——别把"干净"的 1 当失败，也别把 2 当干净。
   ```
   命中 → 停下，AskUserQuestion 让用户确认是否继续发送 / 先脱敏 / 缩小范围 / 改用 `CODEV_SANDBOX_MODE=text`；
   未命中再继续。
   > 副本模式下整仓扫描**命中率天然高得多**（测试固件、示例配置、变量名里带 `token`/`secret` 的正常代码
   > 都会命中）。**别因为噪音多就跳过或删条件**——按文件聚合命中、区分"真密钥"与"仅命名相似"后再问用户，
   > 拿不准就当真密钥处理。

   > ⚠️ **`./repo` 只读副本让"发送范围"变大了**：沙盒 agent 能读整个工作区并把内容发给它自己的模型，
   > 不再只有 diff。母本构建（`codev_repo_master`）时已按**文件名**过滤掉常见密钥文件（`.env*`、`*.pem`、`*.key`、
   > `id_rsa*`、`.netrc`、`.npmrc` 等）且不含 `.git`，但**挡不住硬编码在源码里的密钥**。
   > 所以上面这轮 secret 扫描照做不误。若仓库整体敏感（含客户数据、私有密钥、合规限制），
   > 用 `CODEV_SANDBOX_MODE=text` 退回"只喂提示词文本"，并告知用户此时沙盒 agent 会看不到
   > diff 之外的代码、结论置信度下降。**首次在一个新仓库启用副本模式时，向用户说明这一点。**
4. 并行发出（B/C）：
   - `codex` 走 `codev_bg_native codex codex review "<prompt>"`——**gstack 式**：prompt 里含文件系统边界 +
     "请自己跑 `git diff <BASE>` 只评审这些改动 + 关注点" + **未跟踪新文件清单**（`git diff` 不含 untracked，
     codex 在真仓库里跑却不知道哪些文件是新增的：把第 1 步枚举出的路径逐个列进 prompt，写明"这些是新增
     未跟踪文件，整个文件都是改动，请打开评审"；一个都没有就写"无未跟踪新文件"）（**写 `git diff <BASE>`，不是 `<BASE>...HEAD`**：
     后者只含已提交范围，未提交改动在 main 上跑时 BASE 就是 HEAD、范围为空，codex 会说"没有改动"或随手评审别的
     代码，而其它 agent 拿的是 `git diff "$BASE"` 的工作树内容，一致性矩阵在比两份不同的东西），从而**不带 `--base`/`--commit`**（避开
     `[PROMPT]` 与它们的 argv 互斥）、也**不带 `-s`/`-C`**（review 不认这俩），须从仓库根跑。这样保住了
     自定义关注点（详见 agents.md）；
   - 其它 agent 用 prompts.md 的 **review 模板**（含「工作副本」+「两档结论」段）+ `git diff "$BASE"`
     内容（经上面扫描后），走 `codev_bg_sandboxed`。**只内联 diff**，diff 之外的既有代码不必再手工摘录——
     让它们自己去沙盒里的 `./repo` 读。
5. 运行时显示（D）→ 忠实呈现（E）→ **事实核查回填 + P1 亲验** → 综合（F）+ **PASS/FAIL 门禁**。
6. 若此前对话里已跑过 Claude 自己的 `/code-review`，加一段"Claude vs 外部 agent"对比与
   一致率。
7. 综合后 `codev_finding_add` 逐条记发现台账；询问用户是否让 Claude 修复被确认的问题（修复由 Claude 做）。
   修复后的 commit 同样走 `codev_commit_round <文件列表> …`：首参是【空格分隔的具体文件路径】，多文件就都列出来。
   **不要给目录**——工作树里常有用户自己未提交的改动，给目录会把它们一起提交，函数为此直接拒收目录并返回 1。
   两个限制：① 按**整文件**提交（不是 hunk），目标文件里用户自己的未提交改动会一起进去，文件有部分暂存时函数拒收；
   ② 路径**不能含空格/制表符**（首参按空白拆分），这种文件先重命名或手动 `git add`/`git commit`。

## Step 2F — 文档评审（spec / 实施计划 / 方案文档，无 diff）

实际使用中出现最多的模式：一份 spec 或计划要过 3-5 轮外审才收敛。与 2B 的区别：没有 diff、不需要 base、
评审对象是一份文档 + 它对仓库现状的断言。

1. 定位文档：`DOC=<路径>`，`git ls-files --error-unmatch "$DOC"` 或未被忽略的 untracked → **在工作区内**，
   走路径引用；否则（仓库外 / 被 ignore）才内联全文。`wc -c "$DOC"` 与 `grep -n '^#' "$DOC"` 拿体积与章节目录。
   **例外：沙盒没有 `./repo` 时必须内联**——`CODEV_SANDBOX_MODE=text`、仓库超体积闸门、非 git 仓库都会让
   `codev_bg_sandboxed` 自动退回空目录模式（▶ 行标"隔离空目录"），此时路径引用等于什么都没给，agent 只能
   输出"无法验证"。发起前先判（母本是发起时才懒铺的，不能只看目录在不在，要真的铺一次）：
   `[ "${CODEV_SANDBOX_MODE:-repo}" = repo ] && ( cd "$(git rev-parse --show-toplevel)" && codev_repo_master )`
   返回非 0（非 git / 超闸门 / 铺失败）、或首个 ▶ 行显示空目录，就对沙盒 agent 改用 DOC_START/DOC_END 内联
   （codex/gemini 在真仓库，仍路径引用）。铺好的母本随后被各 agent 直接复用，不多花时间。
2. 选 agent（A）。`--round N ≥ 2` 时：`PREV=$(codev_prev_round_commit "$DOC" N)` 找到上一轮回流 commit（找不到就
   让用户给），`git diff "$PREV" -- "$DOC"` 就是"本轮改动"；先做 synthesis.md §6.1 的 **fresh-subagent 自审**
   （Agent 工具起一个不带本对话上下文的 subagent，只给它文档路径 + 该 diff + prompts.md「自审模板」），
   自审发现由 Claude 亲验后直接改进文档，再进外审。
3. secret 扫描：扫**文档正文**（内联/路径引用都要，agent 会读它）；副本模式下按 2B 第 3 步扫整仓。
4. 组提示词（prompts.md「文档评审模板」）：路径引用 + 章节目录 + 关注点 + **点名 3-8 条核实项**
   （文档里最关键、最可能与代码脱节的 `文件:行号` / 表名 / 函数 / 迁移号断言）+ 两档结论；
   `--round ≥ 2` 附「回归核对」段（上一轮发现编号清单：已采纳的逐条判 已修 / 未修 / 修出新问题；**已驳回的列出驳回依据，
   要求除非有新证据否则不要重提**）+ **必带**内联 `git diff "$PREV" -- "$DOC"`（≤15KB 直接放；超了放 `--stat` + 改动章节；
   diff 不是文档全文，路径引用规则不适用——副本无 `.git`，agent 自己跑不出两版差异）。
   codex 用 `codex exec`（不是 `review`——没有 diff 可评），`-c 'model_reasoning_effort="medium"'`；
   复杂文档 `export CODEV_TIMEOUT=1200`。
5. 并行发出（C）→ 运行时显示（D）→ 忠实呈现（E）→ 事实核查回填 + **P1 亲验** → 综合（F）：
   产出「与代码脱节清单（逐条 成立/不成立 + 依据）+ 方案风险 + 遗漏项 + 可否进入下一步」；
   记录本轮 **已核实 P1 数**，写进综合结尾（供 §6 收敛判据用）。
6. 回流：Claude 把采纳项改进文档（受伤段落整段重写，不做补丁式 string-replace 堆叠），**对每个改过的概念
   全文 grep 同步**，版本号 +0.1；然后 `codev_archive <文档 slug> N`（原文归档到 gitignored 的
   `.superpowers/codev/`，不进 git）+ `codev_commit_round "$DOC" N "<agent>(<模型>), …" <本轮已核实 P1> <上轮 P1> "<摘要>"
   "Co-Authored-By: …"`（**只提交显式列出的文件**、按整文件提交，工作树里用户的其它改动不碰；路径不能含空格；trailer 由库写）。
   非 `--auto` → 问用户是否开下一轮；`--auto` → 按 synthesis.md §6.3 判停/续。

## Step 2C — challenge（对抗式挑战）

1. 确定对象（当前 diff / 指定文件 / 某个方案）。
2. 选 agent（A）。secret 扫描（B：副本模式扫整仓，text 模式扫提示词）。
3. 并行发出（B/C），用 prompts.md 的 **challenge 模板**：指令 agent "扮演对手，尽力找出会
   让它崩的输入、边界条件、并发/竞态、错误处理缺失、隐含假设"。
4. 运行时显示（D）→ 忠实呈现（E）→ 综合（F）：汇成"攻击面清单"，标注哪些是真问题、哪些已被现有代码处理。
5. 询问是否让 Claude 针对确认的漏洞补测试/加固。

## Step 2D — consult（咨询汇总）

1. 若用户点名了 agent 就用它；否则选 agent（A，默认 2 个）。secret 扫描（B）。
2. 并行发出（B/C），用 prompts.md 的 **consult 模板**：转述用户问题。
3. 运行时显示（D）→ 忠实呈现（E）→ 综合（F）：给出各 agent 观点 + Claude 的收敛结论。

## Step 2E — 全流程（默认）

brainstorm（2A）→ 用户拍板 → Claude 按方案与 CLAUDE.md 规范编码 → review（2B，FAIL 则修复后可再跑）→ 最终小结
（做了什么、外部 agent 的关键贡献、遗留项）。**每个阶段之间停下等用户确认**，不一口气冲到底。

---

## 完成后

简短小结：跑了哪些模式、调用了哪些 agent（含被判无效的类别）、跨模型综合的关键结论、门禁结果、
本轮已核实 P1 数（多轮时给趋势）、遗留项。不要复述外部 agent 的原文（上面已逐字呈现过）。
本 skill 的库有回归测试：改 `bin/codev-lib.sh` 后跑 `bash tests/test-lib.sh`。
