# codev-lib.sh — codev skill 的共享 shell 函数库
#
# 用法：本文件由 SKILL.md 的各 Bash 调用【source】，不直接执行。
#   Step 0 先建【会话专属目录】并把它拷进去：
#     CODEV_DIR=$(mktemp -d -t codev.XXXXXX); cp <SKILL_DIR>/bin/codev-lib.sh "$CODEV_DIR/codev-lib.sh"
#   此后每个（含后台）Bash 调用开头（<会话目录> = Step 0 打印的字面路径）：
#     CODEV_DIR=<会话目录>; source "$CODEV_DIR/codev-lib.sh"
#   —— 因为后台是独立 shell，变量/函数都不继承，靠每次 source 重新拿到这些函数；
#      CODEV_DIR 也必须每次用字面值重设（否则退回默认 /tmp）。
#
# 卫生规则（务必遵守，否则 source 进调用方 shell 会污染/中断它）：
#   - 不要 set -e / set -u / trap / 改 IFS / 改 PATH（umask 已收进各函数的子 shell，不外泄）。
#   - source 时【不执行任何命令】，只做函数定义 + CODEV_TO / CODEV_DIR 两个赋值。
#   - 所有函数前缀 codev_、所有全局变量前缀 CODEV_。
#   - bash/zsh 通用：用 local/[ ]/"$@"，不用 bash 数组下标（注意 local 非 POSIX，仅保证 bash/zsh）。

# timeout 二进制探测（macOS 原生无 timeout，装 coreutils 才有 gtimeout）。
CODEV_TO=$(command -v timeout || command -v gtimeout || true)

# 输出/库文件的基目录。默认 /tmp（向后兼容）；Step 0 会把它设成【本次会话专属目录】
# （mktemp -d 建的 /tmp/codev.XXXX），每个后台调用开头用字面值 `CODEV_DIR=<会话目录>` 前置。
# 好处：并发的两个 /codev run 不再互相覆盖 out/err，收尾 `rm -rf "$CODEV_DIR"` 也不会误删对方文件。
CODEV_DIR="${CODEV_DIR:-/tmp}"

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
    # 用 printf %s 传 $rc（不要写 "exit=$rc："——UTF-8 locale 下 bash 会把紧跟的全角字符与
    # 变量展开一起误扫，吞掉退出码；ASCII 冒号 + printf 稳）。stderr 只印一次头 5 行，空文件显式提示。
    printf '⚠️ %s 非零退出 exit=%s（stderr 头 5 行）:\n' "$agent" "$rc"
    if [ -s "$err" ]; then head -n 5 "$err" 2>/dev/null | sed 's/^/  /'; else echo "  (无 stderr)"; fi
  else
    echo "✔ $agent 完成 exit=0"
  fi
}

# codev_bg_sandboxed <agent> <cmd...> — 非原生只读 agent
# （reasonix / qoderclicn / opencode / codebuddy）：在【隔离空目录】里跑，只喂提示词文本，
# cwd 够不到真实仓库 → 从根本上免掉快照/污染问题。输出走会话目录字面路径 $CODEV_DIR/codev-out-<agent>.txt。
# 用法：codev_bg_sandboxed reasonix reasonix run "$(cat "$PROMPT")" --effort medium
#       （首个参数是 agent 标签，其后是要执行的完整命令 argv；"$(cat)" 由调用方先展开成单个 arg。）
codev_bg_sandboxed() {
  local agent="$1"; shift
  local out="$CODEV_DIR/codev-out-$agent.txt" err="$CODEV_DIR/codev-err-$agent.txt"
  echo "▶ $agent 启动（medium, 隔离空目录）"
  if [ -z "$CODEV_TO" ]; then     # 无 timeout：后台裸跑会永久挂起 → 跳过，不阻塞其它
    : > "$out"; : > "$err"        # 清空旧输出：防跳过后 Claude 按字面路径读到上一轮陈旧评审
    echo "⏭ $agent 跳过（无 timeout，后台无兜底）→ 改前台串行或先 brew install coreutils"
    return 0
  fi
  local sbox rc
  sbox=$(mktemp -d -t codev-sbox.XXXXXX) || { echo "⚠️ $agent mktemp 失败"; return 1; }
  # umask 077 放进子 shell：输出含 diff/可能密钥仅本人可读，且【不把 umask 泄漏给调用方 shell】。
  ( umask 077; cd "$sbox" && codev_run "$@" < /dev/null > "$out" 2>"$err" ); rc=$?
  [ -n "$sbox" ] && rm -rf "$sbox"   # 空值守卫，防 mktemp 失败时 rm -rf ""
  codev_report "$agent" "$rc" "$err" # 捕【agent】退出码，不是 rm 的
}

# codev_bg_native <agent> <cmd...> — 原生只读 agent（codex `-s read-only` / gemini `--approval-mode plan`）：
# 无需沙盒（沙盒级只读保证），在【当前 cwd（应为仓库根）】跑。输出同样走字面路径。
# 用法：codev_bg_native codex codex review "$(cat "$PROMPT")" -c 'model_reasoning_effort="medium"'
codev_bg_native() {
  local agent="$1"; shift
  local out="$CODEV_DIR/codev-out-$agent.txt" err="$CODEV_DIR/codev-err-$agent.txt"
  echo "▶ $agent 启动（medium, 原生只读）"
  if [ -z "$CODEV_TO" ]; then
    : > "$out"; : > "$err"        # 清空旧输出：同 sandboxed，防读到上一轮陈旧评审
    echo "⏭ $agent 跳过（无 timeout，后台无兜底）→ 改前台串行或先 brew install coreutils"
    return 0
  fi
  local rc
  # umask 077 放进子 shell：不把 umask 泄漏给调用方 shell（前台/内联退化场景会残留 0600）。
  ( umask 077; codev_run "$@" < /dev/null > "$out" 2>"$err" ); rc=$?
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
# codex 命中时顺带跑 codev_auth_codex 附上鉴权结论（AUTH_OK/AUTH_FAILED），
# 便于 Claude 把未鉴权的 codex 提前剔出可选项，不浪费一轮后台任务。
codev_probe() {
  local c
  for c in codex gemini reasonix qoderclicn opencode codebuddy; do
    if command -v "$c" >/dev/null 2>&1; then
      if [ "$c" = codex ]; then echo "OK   codex ($(codev_auth_codex))"; else echo "OK   $c"; fi
    else
      echo "MISS $c"
    fi
  done
  echo "timeout -> ${CODEV_TO:-MISSING}"
}
