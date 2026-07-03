# agents.md — 外部 agent 调用参考

## 安装 / 登录（Step 0 一个都没探测到时给用户）

这些是第三方 CLI，本 skill 不代装。按需安装并登录（各家以官方文档为准）：
- **codex**（OpenAI）：装后 `codex login`，或设 `$OPENAI_API_KEY` / `$CODEX_API_KEY`。
- **gemini**（Google）：装后首次交互登录，或设 `$GEMINI_API_KEY`。
- **reasonix**（DeepSeek）：`reasonix setup` 配 API key。
- **qoderclicn / codebuddy**：各自账号交互登录。
- **opencode**：`opencode auth` 配置 providers。
- **timeout**：macOS 无原生 `timeout`，`brew install coreutils` 装 `gtimeout`。

---

每个 agent 背后是不同的大模型。调用前先 Step 0 探测；只用 `command -v` 命中的。
所有命令都以**只读**为目标运行，用 timeout 包裹、`< /dev/null` 喂空 stdin 防挂起、
分别收集 stdout/stderr（用于逐字呈现与读 token/成本）。

**timeout 封装（用函数，别用变量前缀）**——不要写 `$TP <cmd>`（`TP="$TO 600"`）：**zsh 不对无引号变量做
词拆分**，会把整串 `"/path/timeout 600"` 当成一个命令名执行 → `no such file or directory`（本机 shell 是
zsh，实测每个 agent 调用都在此死掉、exit 127，模型根本没被触达）。改用函数，`"$@"` 传参 bash/zsh 都对：
```bash
TO=$(command -v timeout || command -v gtimeout || true)
run() { if [ -n "$TO" ]; then "$TO" 600 "$@"; else "$@"; fi; }   # $TO 为空则裸跑
```
命令里统一写 `run <cmd> …`（要传环境变量用 `run env VAR=val <cmd>`）。600s 只兜底真正卡死的进程——
**慢模型靠后台执行**（Bash `run_in_background`）跑完，不受前台工具超时约束，别再用短 timeout 前台阻塞
（那正是 reasonix/codebuddy 常被误杀的原因）。

> ⚠️ **变量/函数不跨 Bash 调用**：并行 fan-out 时每个 agent 是**独立的 Bash 工具调用 = 独立 shell**，
> Step 0 里的 `$TO/$PROMPT/$TMPOUT/$TMPERR/$BASE` 和 `run()` 函数 **都不会**带到后续调用。mktemp 生成的
> **文件**在磁盘上持久，但**变量/函数**不持久。所以每个并行 Bash 调用内都要就地重新定义 `TO`/`run()`、
> 或直接写**字面路径**（如 `/tmp/codev-prompt-reasonix.txt`）。下文命令用 `$VAR`/`run` 只是示意，落地时按此规则展开。

**提示词一律走文件，禁止内联进命令行**——把完整提示词写入临时文件，命令里用
`"$(cat "$PROMPT")"` 引用。**绝不**把 `git diff`/用户需求原文直接拼进 `"<完整提示词>"`：
diff 里的 `$(...)`、反引号会被 shell 展开（注入）。
```bash
PROMPT=$(mktemp -t codev-prompt)   # 用 cat > "$PROMPT" <<'EOF' 写入（单引号 EOF 防展开）
```
> ⚠️ **mktemp 模板**：macOS/BSD `mktemp` 只替换**结尾**的 X，`mktemp /tmp/foo-XXXXXX.txt` 会原样
> 生成 `foo-XXXXXX.txt`（非随机、并行相撞）。一律用 `mktemp -t codev-<role>` 形式。
> **注意**：`"$(cat "$PROMPT")"` 只解决注入，**不能**避免 `ARG_MAX`（内容仍作 argv）。防 ARG_MAX 要靠
> 阈值：发送前 `wc -c "$PROMPT"`，超大（如 > 100KB）就按文件筛选/缩小范围，或改用支持 stdin 的 CLI。

**每个 agent 独立临时文件**（并行时不可共享同名变量，否则互相覆盖）：
```bash
TMPOUT=$(mktemp -t codev-out-<agent>)   # 保存 stdout，供逐字呈现
TMPERR=$(mktemp -t codev-err-<agent>)   # 保存 stderr，读 token/诊断
# 收尾清理：完成呈现后 rm -f "$PROMPT" "$TMPOUT" "$TMPERR"（或告知用户保留路径）
```
失败/空输出判定要综合 **exit code + stdout + stderr** 三者，别只看 stdout 是否为空；
若 stdout 为空但 stderr 含有效正文（非鉴权/报错），也逐字呈现并标注"来源 stderr"。

非原生只读 agent（reasonix / qoderclicn / opencode / codebuddy）的只读保障按运行位置二选一：
- **(a) 首选：隔离空目录只喂文本**（见下方 SANDBOX 模板）——cwd 是空目录，够不到仓库，从根本上免风险。
  此时**不必逐 agent 快照**，只需在**整批 fan-out 前后各做一次全局** `git status --porcelain` 兜底核对。
- **(b) 确需在真实仓库 cwd 跑**：则**必须逐 agent 前后快照核对 + 串行**（并行无法归因、会互相污染）。

无论哪种，核对只**检测并如实上报**，**绝不自动 `git checkout`/`reset`**——review 模式下工作区正是用户
待评审的未提交改动，自动回滚会连用户自己的工作一起抹掉（未跟踪文件 checkout 也删不掉）。下面片段用于 (b)：
```bash
SNAP=$(git status --porcelain)          # 调用前快照（含未跟踪文件）
# … 调用 agent …
if [ "$(git status --porcelain)" != "$SNAP" ]; then
  echo "⚠️ <agent> 疑似改动了工作区，违反只读约定。变化如下："
  git status --porcelain
  echo "→ 停下，把差异逐字告知用户，由用户决定如何处置（不要自动回滚）。"
  exit 1                                 # 非零退出，强制 Claude 停下、不静默继续
fi
```
- **必须有 `exit 1`**：只 echo 不退出，Bash 调用仍返回 0，Claude 可能无视警告继续，把"停下"架空。
- **并行归因问题**：多个非原生只读 agent 同时跑时，快照交叠无法归因到某一个，且 A 的写入会污染
  B 读到的状态。因此非原生只读 agent **要么串行**（各自前后核对），**要么只喂 diff/代码片段文本、
  在隔离空目录里跑**（首选：它们只需要提示词文本，不必访问工作区）。隔离模板：
  ```bash
  OUT=/tmp/codev-out-reasonix.txt; ERR=/tmp/codev-err-reasonix.txt   # 后台执行须用【字面路径】，见 SKILL.md C
  SANDBOX=$(mktemp -d -t codev-sbox.XXXXXX)
  ( cd "$SANDBOX" && run reasonix run "$(cat "$PROMPT")" --effort medium \
    < /dev/null > "$OUT" 2>"$ERR" ); RC=$?
  [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"; echo "exit=$RC"   # 捕 agent 退出码（非 rm 的）；空值守卫防 rm -rf ""
  ```
  这样 agent 的 cwd 是空目录，够不到真实仓库，从根本上免掉快照/污染问题。**但空目录只是纵深防御的
  一层，不是硬隔离**：若 agent CLI 自身有 tool-use / shell 执行能力（如某些框架能 `cat /任意绝对路径`
  或 `cd /`），空 cwd 挡不住它读仓库外的文件。所以对有工具能力的 agent 仍要**叠加提示词约束 + 禁工具
  旗标**（qoderclicn `--tools ""`、opencode `--agent <只读>`）；纯推理 CLI（reasonix 无禁工具旗标）才靠
  空目录 + 提示词约束兜底。
- **快照盲区**：`git status --porcelain` 检测不到**已存在的未跟踪文件的内容**被改（前后都是 `??` 同名）。
  这也是"隔离空目录 + 只喂文本"优先于"在仓库里跑再快照"的原因；确需在仓库跑时，可额外记录
  `git ls-files --others --exclude-standard -z | xargs -0 shasum` 的前后 hash。
- 原生只读的 codex/gemini 可放心并行（`-s read-only` / `--approval-mode plan` 是沙盒级保证）。

---

## codex — OpenAI GPT

- **咨询 / 头脑风暴 / 挑战 / 通用提问**（默认纯文本，便于逐字呈现）：
  ```bash
  run codex exec "$(cat "$PROMPT")" \
    -C "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" \
    -s read-only \
    -c 'model_reasoning_effort="medium"' \
    < /dev/null > "$OUT" 2>"$ERR"
  ```
  （`codex exec` 接受 `-C`/`-s`；`review` 子命令**不接受**，见下条。）默认**不加 `--json`**——JSONL（推理轨迹/工具调用事件流）不适合"逐字呈现"给用户；仅当明确要
  解析 token/事件时才加 `--json`。若 `-C` 目录非受信 git 仓库会报 "Not inside a trusted directory"，
  加 `--skip-git-repo-check`。
- **代码评审（原生）**：⚠️ `codex review` 的命令接口与 `exec` **完全不同**，实测有三个坑：
  ① **不接受 `-C`**（`error: unexpected argument '-C' found`，exit 2）→ 须先 `cd` 进仓库根；
  ② **不接受 `-s`**（review 本就只读，无此旗标）；
  ③ **自定义 `[PROMPT]` 与 `--base`/`--commit` 互斥**（`error: the argument '[PROMPT]' cannot be used
     with '--commit'`，exit 2）→ 用范围选择器时**不能**再带 `"$(cat "$PROMPT")"`。
  正确用法——从仓库 cwd 内跑、不带自定义 prompt、用选择器指定范围：
  ```bash
  cd "$(git rev-parse --show-toplevel)"                # review 无 -C，须先进仓库根
  run codex review --base "$BASE" \                    # 三选一：--base <branch> / --commit <sha> / --uncommitted
    -c 'model_reasoning_effort="medium"' < /dev/null > "$OUT" 2>"$ERR"
  ```
  评审范围选择器：`--base <branch>`（对比某分支）、`--commit <sha>`（某次提交引入的改动）、
  `--uncommitted`（暂存+未暂存+未跟踪）。`$BASE` 在后台独立 shell 里为空，须就地写**字面值**（如 `--base HEAD~1`）。
- **只读保证**：`codex review` 本身就是只读评审（不写文件），**无需也不能加 `-s`**；`-s read-only` 只用于
  `codex exec`。想在评审里附加关注点时，只能靠 review 的默认指令，无法同时用 `[PROMPT]` + 范围选择器。
- **推理强度**：默认 `medium`（防慢/防超时）；复杂任务或用户要更深升 `high`；`--xhigh` 才用
  `-c 'model_reasoning_effort="xhigh"'`。升档前提醒会更慢。
- **鉴权**：需 `codex login`，或环境变量 `$CODEX_API_KEY` / `$OPENAI_API_KEY`，或
  `~/.codex/auth.json` 存在。缺失时提示：`codex login`。
- **成本**：`grep -i "tokens used" "$TMPERR"`（大小写不敏感）。
- **角色**：严谨、对抗式挑刺、深度代码审查（"200 IQ 直男工程师"式第二意见）。

## gemini — Google Gemini

- **调用**：
  ```bash
  run env GEMINI_CLI_TRUST_WORKSPACE=true gemini -p "$(cat "$PROMPT")" \
    --approval-mode plan < /dev/null > "$OUT" 2>"$ERR"
  ```
  可选 `-m <model>` 指定模型（建议显式指定以固定评审质量，如 `-m gemini-2.5-pro`）。
- **只读保证**：`--approval-mode plan` 为**原生只读模式**（不改文件）。
- **非受信目录**：非交互模式在未信任目录会报 "not running in a trusted directory" 直接失败；
  用 `GEMINI_CLI_TRUST_WORKSPACE=true`（或 `--skip-trust`）。
- **鉴权**：`gemini`（首次交互登录）或 `$GEMINI_API_KEY`。
- **角色**：超大上下文、架构/方案发散、跨领域联想。

## reasonix — DeepSeek

- **调用**：
  ```bash
  run reasonix run "$(cat "$PROMPT")" --effort medium < /dev/null > "$OUT" 2>"$ERR"
  ```
  可选 `--budget <usd>` 设美元上限、`-m <id>` 指定模型（如 deepseek-v4-flash）。
  **默认 `medium`**：`high`/`max` + 大提示词是 reasonix 最常超时的组合，需要更深再升，并配合后台执行。
- **只读保证**：**无原生只读旗标** → 必须在提示词里强约束"禁止修改任何文件，只输出文本"，
  且不给它 auto-approve。**首选隔离空目录只喂文本 (a)**；确需在真实仓库 cwd 跑则**必须**逐次前后
  `git status` 快照核对 (b)（见顶部只读保障 (a)/(b)）。
- **推理强度**：`--effort low|medium|high|max`；默认 `medium`，`--xhigh` 用 `max`。
- **鉴权**：`reasonix setup` 配置 API key。
- **角色**：低成本、高性价比推理，适合快速多方案头脑风暴。

## qoderclicn — Qoder

- **调用**：
  ```bash
  run qoderclicn -p "$(cat "$PROMPT")" --reasoning-effort medium \
    --tools "" < /dev/null > "$OUT" 2>"$ERR"
  ```
  `--tools ""` 禁用全部内置工具（纯问答，硬保证不动文件）——非原生只读 agent 建议默认带上；
  可选 `-m <model>`。
- **只读保证**：`-p` 非交互 + 提示词强约束；如需更硬，加 `--tools ""` 禁工具。
  不要用 `--dangerously-skip-permissions` / `--permission-mode bypass_permissions`。
- **推理强度**：`--reasoning-effort`；默认 `medium`，`--xhigh` 用 `max`。
- **鉴权**：Qoder 账号登录。`--list-models` 可查可用模型。
- **角色**：代码理解、评审。

## opencode — 多供应商

- **调用**：
  ```bash
  run opencode run "$(cat "$PROMPT")" < /dev/null > "$OUT" 2>"$ERR"
  ```
  默认纯文本便于逐字呈现；`--format json` 输出事件流（可读性差，仅需解析时用）。
  可选 `-m <provider/model>`（如 `openai/gpt-5.4`；避免选 Anthropic 模型，否则失去跨模型
  多样性的意义）、`--agent <只读agent名>`。
- **只读保证**：无显式只读旗标 → 提示词强约束 + 不 auto-approve；可用 `--agent` 指定一个
  只读/审阅型 agent。`--format json` 便于解析事件。
- **鉴权**：`opencode auth`（providers）。`opencode models` 查可用模型。
- **角色**：灵活切换多家模型，做交叉对比很方便。

## codebuddy — 腾讯（Claude Code 分支）

- **调用**：
  ```bash
  run codebuddy -p "$(cat "$PROMPT")" < /dev/null > "$OUT" 2>"$ERR"
  ```
- **只读保证**：`-p` 非交互 + 提示词强约束 + 顶部快照片段（非原生只读，强制核对）；
  不要用 `--dangerously-skip-permissions`。
- **⚠️ 已知问题**：本机实测 `codebuddy -p` 常**无标准输出或超时**（退出码 0 但 stdout 空，或超
  timeout 返回 124）。若空输出/超时：判定本次不可用，**跳过它**并如实告诉用户
  "codebuddy 无输出/超时（可能原因：未登录 / API 异常 / 上下文超限），已跳过；可运行
  `codebuddy` 交互登录后重试"。
- **鉴权**：`codebuddy`（交互登录）。
- **角色**：中文语境下的代码评审。

---

## 失败 / 超时 / 空输出处理（统一话术）

- **超时**（timeout 返回 124，即撞到 600s 安全网）：先确认是否**已用后台执行**——前台短超时误杀是
  最常见原因。仍超时则告知"<agent> 超过 600s 未返回，已跳过。可降推理强度到 medium/精简提示词后重试。"
- **鉴权失败**：给出对应登录命令，跳过该 agent，继续其余。
- **空输出**：跳过并说明（见 codebuddy 条）。
- **任一 agent 失败都不阻塞其它**；最终综合时注明"本轮实际参与的 agent：X、Y（Z 已跳过）"。

## 只读风险总结

| agent | 原生只读 | 依赖提示词约束 |
|---|---|---|
| codex | ✅ `-s read-only` | — |
| gemini | ✅ `--approval-mode plan` | — |
| reasonix | ❌ | ✅ 必须 |
| qoderclicn | 半（`--tools ""`） | ✅ |
| opencode | 半（`--agent`） | ✅ |
| codebuddy | ❌ | ✅ 必须 |

对"依赖提示词约束"的 agent（表中非 ✅ 的四个），提示词里的**文件系统边界**段落是第一道防线；
但铁律"只读"不能只靠请求——**必须**按本文件顶部的快照片段在调用前后 `git status --porcelain`
核对，发现改动即**停下、逐字上报差异交用户处置（`exit 1`，绝不自动回滚**，以免误删用户未提交
的工作）。这一步对非原生只读 agent 是强制的，不是"有顾虑时"可选；首选让它们只处理提示词文本、
不接触真实工作区（见顶部片段）。
