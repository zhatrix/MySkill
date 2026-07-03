# agents.md — 外部 agent 调用参考

## 安装 / 登录（Step 0 一个都没探测到时给用户）

这些是第三方 CLI，本 skill 不代装。按需安装并登录（各家以官方文档为准）：
- **codex**（OpenAI）：装后 `codex login`，或设 `$OPENAI_API_KEY` / `$CODEX_API_KEY`。
- **gemini**（Google）：装后首次交互登录，或设 `$GEMINI_API_KEY`。
- **reasonix**（DeepSeek）：`reasonix setup` 配 API key。
- **qodercli / codebuddy**：各自账号交互登录。
- **opencode**：`opencode auth` 配置 providers。
- **timeout**：macOS 无原生 `timeout`，`brew install coreutils` 装 `gtimeout`。

---

每个 agent 背后是不同的大模型。调用前先 Step 0 探测；只用 `command -v` 命中的。
所有命令都以**只读**为目标运行，用 timeout 包裹、`< /dev/null` 喂空 stdin 防挂起、
分别收集 stdout/stderr（用于逐字呈现与读 token/成本）。

**timeout 前缀（空值安全）**——不要把可能为空的 `$TO` 直接拼进命令（`$TO 240 …` 会退化成
把 `240` 当命令执行）。Step 0 探测后按下式生成前缀：
```bash
TO=$(command -v timeout || command -v gtimeout || true)
TP="${TO:+$TO 240}"        # $TO 非空 → "…/timeout 240"；为空 → 空串，命令裸跑
TP300="${TO:+$TO 300}"     # codex review 用 300s
```
命令里统一写 `$TP <cmd> …`（review 用 `$TP300`）。`$TO` 为空则整段安全展开为空。

> ⚠️ **变量不跨 Bash 调用**：并行 fan-out 时每个 agent 是**独立的 Bash 工具调用 = 独立 shell**，
> Step 0 里的 `$TO/$TP/$TP300/$PROMPT/$TMPOUT/$TMPERR` **不会**带到后续调用。mktemp 生成的**文件**
> 在磁盘上持久，但**变量**不持久。所以每个并行 Bash 调用内要么重新定义这些变量、要么直接写**字面
> 路径**（如 `/tmp/codev-prompt-xxxx.txt`）。下文命令用 `$VAR` 只是示意，落地时按此规则展开。

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

非原生只读 agent（reasonix / qodercli / opencode / codebuddy）调用前后**强制**快照核对。
核对只**检测并如实上报**，**绝不自动 `git checkout`/`reset`**——review 模式下工作区正是用户待评审
的未提交改动，自动回滚会连用户自己的工作一起抹掉（未跟踪文件 checkout 也删不掉）。
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
  SANDBOX=$(mktemp -d -t codev-sbox); ( cd "$SANDBOX" && $TP reasonix run "$(cat "$PROMPT")" \
    --effort high < /dev/null > "$TMPOUT" 2>"$TMPERR" ); rm -rf "$SANDBOX"
  ```
  这样 agent 的 cwd 是空目录，够不到真实仓库，从根本上免掉快照/污染问题。
- **快照盲区**：`git status --porcelain` 检测不到**已存在的未跟踪文件的内容**被改（前后都是 `??` 同名）。
  这也是"隔离空目录 + 只喂文本"优先于"在仓库里跑再快照"的原因；确需在仓库跑时，可额外记录
  `git ls-files --others --exclude-standard -z | xargs -0 shasum` 的前后 hash。
- 原生只读的 codex/gemini 可放心并行（`-s read-only` / `--approval-mode plan` 是沙盒级保证）。

---

## codex — OpenAI GPT

- **咨询 / 头脑风暴 / 挑战 / 通用提问**（默认纯文本，便于逐字呈现）：
  ```bash
  $TP codex exec "$(cat "$PROMPT")" \
    -C "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" \
    -s read-only \
    -c 'model_reasoning_effort="high"' \
    < /dev/null > "$TMPOUT" 2>"$TMPERR"
  ```
  默认**不加 `--json`**——JSONL（推理轨迹/工具调用事件流）不适合"逐字呈现"给用户；仅当明确要
  解析 token/事件时才加 `--json`。若 `-C` 目录非受信 git 仓库会报 "Not inside a trusted directory"，
  加 `--skip-git-repo-check`。
- **代码评审（原生）**：
  ```bash
  $TP300 codex review "$(cat "$PROMPT")" \
    -C "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" \
    -s read-only --base "$BASE" \
    -c 'model_reasoning_effort="high"' < /dev/null > "$TMPOUT" 2>"$TMPERR"
  ```
- **只读保证**：`-s read-only` 为**原生只读沙盒**，最可靠——**exec 和 review 都必须带上**
  （漏了 review 就不再是只读，与下方只读表不符）。
- **推理强度**：默认 `high`；`--xhigh` 时 `-c 'model_reasoning_effort="xhigh"'`；consult 可降 `medium` 提速。
- **鉴权**：需 `codex login`，或环境变量 `$CODEX_API_KEY` / `$OPENAI_API_KEY`，或
  `~/.codex/auth.json` 存在。缺失时提示：`codex login`。
- **成本**：`grep -i "tokens used" "$TMPERR"`（大小写不敏感）。
- **角色**：严谨、对抗式挑刺、深度代码审查（"200 IQ 直男工程师"式第二意见）。

## gemini — Google Gemini

- **调用**：
  ```bash
  GEMINI_CLI_TRUST_WORKSPACE=true $TP gemini -p "$(cat "$PROMPT")" \
    --approval-mode plan < /dev/null > "$TMPOUT" 2>"$TMPERR"
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
  $TP reasonix run "$(cat "$PROMPT")" --effort high < /dev/null > "$TMPOUT" 2>"$TMPERR"
  ```
  可选 `--budget <usd>` 设美元上限、`-m <id>` 指定模型（如 deepseek-v4-flash）。
- **只读保证**：**无原生只读旗标** → 必须在提示词里强约束"禁止修改任何文件，只输出文本"，
  且不给它 auto-approve。调用前后可 `git status` 核对无改动。
- **推理强度**：`--effort low|medium|high|max`；默认 `high`，`--xhigh` 用 `max`。
- **鉴权**：`reasonix setup` 配置 API key。
- **角色**：低成本、高性价比推理，适合快速多方案头脑风暴。

## qodercli — Qoder

- **调用**：
  ```bash
  $TP qodercli -p "$(cat "$PROMPT")" --reasoning-effort high \
    --tools "" < /dev/null > "$TMPOUT" 2>"$TMPERR"
  ```
  `--tools ""` 禁用全部内置工具（纯问答，硬保证不动文件）——非原生只读 agent 建议默认带上；
  可选 `-m <model>`。
- **只读保证**：`-p` 非交互 + 提示词强约束；如需更硬，加 `--tools ""` 禁工具。
  不要用 `--dangerously-skip-permissions` / `--permission-mode bypass_permissions`。
- **推理强度**：`--reasoning-effort`；`--xhigh` 用 `max`。
- **鉴权**：Qoder 账号登录。`--list-models` 可查可用模型。
- **角色**：代码理解、评审。

## opencode — 多供应商

- **调用**：
  ```bash
  $TP opencode run "$(cat "$PROMPT")" < /dev/null > "$TMPOUT" 2>"$TMPERR"
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
  $TP codebuddy -p "$(cat "$PROMPT")" < /dev/null > "$TMPOUT" 2>"$TMPERR"
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

- **超时**（timeout 返回 124）：告知"<agent> 超过超时上限（多数 240s、codex review 300s）未返回，
  已跳过。可能是模型 API 卡顿或提示过长；可重试或缩短输入。"
- **鉴权失败**：给出对应登录命令，跳过该 agent，继续其余。
- **空输出**：跳过并说明（见 codebuddy 条）。
- **任一 agent 失败都不阻塞其它**；最终综合时注明"本轮实际参与的 agent：X、Y（Z 已跳过）"。

## 只读风险总结

| agent | 原生只读 | 依赖提示词约束 |
|---|---|---|
| codex | ✅ `-s read-only` | — |
| gemini | ✅ `--approval-mode plan` | — |
| reasonix | ❌ | ✅ 必须 |
| qodercli | 半（`--tools ""`） | ✅ |
| opencode | 半（`--agent`） | ✅ |
| codebuddy | ❌ | ✅ 必须 |

对"依赖提示词约束"的 agent（表中非 ✅ 的四个），提示词里的**文件系统边界**段落是第一道防线；
但铁律"只读"不能只靠请求——**必须**按本文件顶部的快照片段在调用前后 `git status --porcelain`
核对，发现改动即**停下、逐字上报差异交用户处置（`exit 1`，绝不自动回滚**，以免误删用户未提交
的工作）。这一步对非原生只读 agent 是强制的，不是"有顾虑时"可选；首选让它们只处理提示词文本、
不接触真实工作区（见顶部片段）。
