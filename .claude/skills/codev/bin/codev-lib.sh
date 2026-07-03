# codev-lib.sh — codev skill 的共享 shell 函数库
#
# 用法：本文件由 SKILL.md 的各 Bash 调用【source】，不直接执行。
#   Step 0 先把它暂存到确定性字面路径：
#     cp <SKILL_DIR>/bin/codev-lib.sh /tmp/codev-lib.sh
#   此后每个（含后台）Bash 调用开头：
#     source /tmp/codev-lib.sh
#   —— 因为后台是独立 shell，变量/函数都不继承，靠每次 source 重新拿到这些函数。
#
# 卫生规则（务必遵守，否则 source 进调用方 shell 会污染/中断它）：
#   - 不要 set -e / set -u / trap / 改 IFS / 改 PATH。
#   - source 时【不执行任何命令】，只做函数定义 + 一个 CODEV_TO 赋值。
#   - 所有函数前缀 codev_、所有全局变量前缀 CODEV_。
#   - POSIX-ish：bash 与 zsh 都要能跑（用 local/[ ]/"$@"，不用 bash 数组下标）。

# timeout 二进制探测（macOS 原生无 timeout，装 coreutils 才有 gtimeout）。
CODEV_TO=$(command -v timeout || command -v gtimeout || true)

# codev_run <cmd...> — 超时封装。取代 `$TP <cmd>` 变量前缀：
# zsh 不对无引号变量做词拆分，`$TP cmd`（TP="/path/timeout 600"）会被当成名为
# 「timeout 600」的单个文件执行而失败；用函数 + "$@" 传参，bash/zsh 都对。
# 600s 只兜底真正卡死的进程——慢模型靠【后台执行】跑完，不受此约束。
codev_run() {
  if [ -n "$CODEV_TO" ]; then "$CODEV_TO" 600 "$@"; else "$@"; fi
}

# codev_report <agent> <rc> <errfile> — 打印完成行 + 【非零退出显式上报】。
# 关键：让调用方（Claude）不会把"无输出"误判成模型卡死；超时(124)/报错都清楚标注。
codev_report() {
  local agent="$1" rc="$2" err="$3"
  if [ "$rc" = "124" ]; then
    echo "⏭ $agent 跳过（超时 124，撞 600s 安全网）→ 可降强度/精简提示词后重试"
  elif [ "$rc" != "0" ]; then
    echo "⚠️ $agent 非零退出 exit=$rc：$(head -1 "$err" 2>/dev/null || echo '(无 stderr)')"
    head -5 "$err" 2>/dev/null | sed 's/^/  /' || true
  else
    echo "✔ $agent 完成 exit=0"
  fi
}

# codev_bg_sandboxed <agent> <cmd...> — 非原生只读 agent
# （reasonix / qoderclicn / opencode / codebuddy）：在【隔离空目录】里跑，只喂提示词文本，
# cwd 够不到真实仓库 → 从根本上免掉快照/污染问题。输出走确定性字面路径 /tmp/codev-out-<agent>.txt。
# 用法：codev_bg_sandboxed reasonix reasonix run "$(cat "$PROMPT")" --effort medium
#       （首个参数是 agent 标签，其后是要执行的完整命令 argv；"$(cat)" 由调用方先展开成单个 arg。）
codev_bg_sandboxed() {
  local agent="$1"; shift
  local out="/tmp/codev-out-$agent.txt" err="/tmp/codev-err-$agent.txt"
  umask 077                       # 输出含 diff/可能密钥 → 仅本人可读，别 644
  echo "▶ $agent 启动（medium, 隔离空目录）"
  if [ -z "$CODEV_TO" ]; then     # 无 timeout：后台裸跑会永久挂起 → 跳过，不阻塞其它
    echo "⏭ $agent 跳过（无 timeout，后台无兜底）→ 改前台串行或先 brew install coreutils"
    return 0
  fi
  local sbox rc
  sbox=$(mktemp -d -t codev-sbox.XXXXXX)
  ( cd "$sbox" && codev_run "$@" < /dev/null > "$out" 2>"$err" ); rc=$?
  [ -n "$sbox" ] && rm -rf "$sbox"   # 空值守卫，防 mktemp 失败时 rm -rf ""
  codev_report "$agent" "$rc" "$err" # 捕【agent】退出码，不是 rm 的
}

# codev_bg_native <agent> <cmd...> — 原生只读 agent（codex `-s read-only` / gemini `--approval-mode plan`）：
# 无需沙盒（沙盒级只读保证），在【当前 cwd（应为仓库根）】跑。输出同样走字面路径。
# 用法：codev_bg_native codex codex review "$(cat "$PROMPT")" -c 'model_reasoning_effort="medium"'
codev_bg_native() {
  local agent="$1"; shift
  local out="/tmp/codev-out-$agent.txt" err="/tmp/codev-err-$agent.txt"
  umask 077
  echo "▶ $agent 启动（medium, 原生只读）"
  if [ -z "$CODEV_TO" ]; then
    echo "⏭ $agent 跳过（无 timeout，后台无兜底）→ 改前台串行或先 brew install coreutils"
    return 0
  fi
  local rc
  codev_run "$@" < /dev/null > "$out" 2>"$err"; rc=$?
  codev_report "$agent" "$rc" "$err"
}

# codev_auth_codex — codex 多信号鉴权检查（env 或 auth.json）。输出 AUTH_OK / AUTH_FAILED。
# 避免只查文件对 env-auth 用户（CI/平台）误报。
codev_auth_codex() {
  local home="${CODEX_HOME:-$HOME/.codex}" k1 k2
  k1=$(printf '%s' "${CODEX_API_KEY:-}" | tr -d '[:space:]')
  k2=$(printf '%s' "${OPENAI_API_KEY:-}" | tr -d '[:space:]')
  if [ -n "$k1" ] || [ -n "$k2" ] || [ -f "$home/auth.json" ]; then
    echo "AUTH_OK"; return 0
  fi
  echo "AUTH_FAILED"; return 1
}

# codev_probe — Step 0 探测：列出 OK/MISS 的 agent CLI + timeout 状态。
codev_probe() {
  local c
  for c in codex gemini reasonix qoderclicn opencode codebuddy; do
    if command -v "$c" >/dev/null 2>&1; then echo "OK   $c"; else echo "MISS $c"; fi
  done
  echo "timeout -> ${CODEV_TO:-MISSING}"
}
