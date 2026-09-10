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
#   - source 时【不执行任何命令】，只做函数定义 + CODEV_TO / CODEV_DIR / CODEV_TIMEOUT / CODEV_LEDGER / CODEV_FINDINGS 等赋值。
#   - 所有函数前缀 codev_、所有全局变量前缀 CODEV_。
#   - bash/zsh 通用：用 local/[ ]/"$@"，不用 bash 数组下标（注意 local 非 POSIX，仅保证 bash/zsh）。

# timeout 二进制探测（macOS 原生无 timeout，装 coreutils 才有 gtimeout）。
CODEV_TO=$(command -v timeout || command -v gtimeout || true)

# 输出/库文件的基目录 = 本次会话专属目录（Step 0 用 mktemp -d 建，每个后台调用开头用字面值
# `CODEV_DIR=<会话目录>` 前置）。好处：并发的两个 /codev run 不互相覆盖 out/err，
# 收尾 `chmod -R u+w "$CODEV_DIR"; rm -rf "$CODEV_DIR"`（母本是 a-w 的）也不会误删对方文件。
# ⚠️ 【不再默认 /tmp】。原来写 `${CODEV_DIR:-/tmp}`，漏设时三个后果都很严重（均实测）：
#   1) 母本变成固定的 /tmp/codev-master-repo，而 codev_repo_master 开头是【无条件复用】——
#      在 repoA 跑完再去 repoB 跑，repoB 的 agent 看到的是 repoA 的代码（实测 repoB 的
#      agent 只看到 secret_a.js、自己的 only_in_b.js 一个都没有）。既外泄 A 的代码，
#      又让 B 的评审整个建立在错误的树上，而 ▶ 行仍显示"只读仓库副本"，完全静默。
#   2) 文档里的收尾命令 `chmod -R u+w "$CODEV_DIR"; rm -rf "$CODEV_DIR"` 展开成对 /tmp 动手（实测展开结果）。
#   3) /tmp 是 1777，任何本地用户都能预先建好 /tmp/codev-master-repo 决定所有 agent 读到什么。
# 故改为【未设置就报错退出】：宁可让调用方立刻失败，也不能静默走上以上任一条。
if [ -z "${CODEV_DIR:-}" ]; then
  echo "FATAL: codev-lib.sh 需要先设 CODEV_DIR（本次会话专属目录，见 SKILL.md Step 0）" >&2
  echo "  正确用法：CODEV_DIR=<Step 0 打印的字面路径>; source \"\$CODEV_DIR/codev-lib.sh\"" >&2
  return 1 2>/dev/null || exit 1
fi

# 沙盒模式：repo（默认，给只读仓库副本）| text（旧行为，纯空目录只喂提示词文本）。
CODEV_SANDBOX_MODE="${CODEV_SANDBOX_MODE:-repo}"
# 仓库副本体积闸门（KB）。超过就退回 text 模式，免得把巨型仓库整份拷进 /tmp。
# 必须校验成纯数字：闸门判断是 `[ "$sz" -gt "$CODEV_MAX_COPY_KB" ] 2>/dev/null`，非数字会让
# test 语法失败 → 整个 && 链为假 → 闸门【静默失效】，把任意大的仓库整份拷走（实测 abc 与空串
# 都直接放行）。故非法值一律退回默认并告警，不静默接受。
case "${CODEV_MAX_COPY_KB:-}" in
  '' ) CODEV_MAX_COPY_KB=102400 ;;
  *[!0-9]* )
    echo "⚠️ CODEV_MAX_COPY_KB='$CODEV_MAX_COPY_KB' 不是纯数字，已退回默认 102400 KB" >&2
    CODEV_MAX_COPY_KB=102400 ;;
esac
# 上限 1 GB：闸门无上限就能让母本构建拖过 codev_sbox_gc 的 60 分钟启发式（构建阶段没有 timeout 管）；
# GC 主要靠 owner pid 判活，这条只是双保险，顺带防误设成天文数字把磁盘拷满。
# 位数也要限：超过 2^63 的纯数字会让 [ -gt ] 本身报错被 2>/dev/null 吞掉，上限和后面的闸门一起静默失效
# （bash 放行一切；zsh 当浮点解析反而全挡）。18 位以内才交给 -gt。
if [ "${#CODEV_MAX_COPY_KB}" -gt 18 ] || [ "$CODEV_MAX_COPY_KB" -gt 1048576 ] 2>/dev/null; then
  echo "⚠️ CODEV_MAX_COPY_KB=$CODEV_MAX_COPY_KB 超过上限 1048576 KB（1 GB），已截到上限" >&2
  CODEV_MAX_COPY_KB=1048576
fi

# 单次 agent 调用的超时秒数。默认 600 只是"兜底真正卡死的进程"的安全网，不是能力上限——后台执行
# 本来就不受前台 300s 工具超时约束。核实型评审（要求 agent 进 ./repo 逐条核实、60+ 次工具调用）和
# 大文档任务实测经常撞 600s（codex/reasonix/codebuddy 都出过 124 零输出），这类任务在调用前
# `export CODEV_TIMEOUT=1200`。范围 60..3000：上限 3000（50 分钟）让 codev_sbox_gc 的"60 分钟"启发式对老版本
# 无 owner 标记的沙盒仍大致成立（现在主要靠 owner pid 判活）；非法值退回 600 并告警（同 CODEV_MAX_COPY_KB 的理由）。
case "${CODEV_TIMEOUT:-}" in
  '' ) CODEV_TIMEOUT=600 ;;
  *[!0-9]* )
    echo "⚠️ CODEV_TIMEOUT='$CODEV_TIMEOUT' 不是纯数字，已退回默认 600s" >&2
    CODEV_TIMEOUT=600 ;;
  * )
    # 位数守卫同 CODEV_MAX_COPY_KB：20 位数字让 bash 的 [ -lt ] 报错为假、原值穿透，timeout 收到天文数字 rc=125，agent 从未运行。
    if [ "${#CODEV_TIMEOUT}" -gt 18 ] || [ "$CODEV_TIMEOUT" -lt 60 ] || [ "$CODEV_TIMEOUT" -gt 3000 ]; then
      echo "⚠️ CODEV_TIMEOUT=$CODEV_TIMEOUT 超出 60..3000，已退回默认 600s" >&2
      CODEV_TIMEOUT=600
    fi ;;
esac

# 跨会话【近期结果账本】：每次 codev_report 追加一行 TSV（12 列：时间 会话 agent 模型 类别 rc 用时 提示词字节 输出字节 tokens 成本 备注），
# codev_probe 读它给每个 agent 标"近期 3 次结果"。解决的实测痛点：qoderclicn 额度死透、codebuddy 连续
# 429 后，下一会话仍按过期的默认组合把它们推荐上去、白跑一轮才发现。账本只记类别与字节数，不记内容。
CODEV_LEDGER="${CODEV_LEDGER:-${XDG_STATE_HOME:-$HOME/.local/state}/codev/ledger.tsv}"
# 发现台账：每条外部 agent 的发现一行（含 Claude 裁决与亲验结果），codev_stats 据此算每个 agent/模型的
# "声称 P1 里经亲验成立的比例"与"独家且成立"数——这才是选模型的依据，不是采纳条数（条数奖励产出多而泛的 agent）。
CODEV_FINDINGS="${CODEV_FINDINGS:-${XDG_STATE_HOME:-$HOME/.local/state}/codev/findings.tsv}"
# 意见与判断记录：每个 agent 对每个问题的【一条立场】一行（评审提出、判断裁决、自审复核各自成行）。
# 与发现台账的分工：findings.tsv 一条发现只有一行、只装 Claude 的最终裁决；协议 v2 允许多位判断者，
# "谁提出、谁采纳、谁存疑、各自给的级别和修法"在那里根本存不下，事后回看只剩一个合成结论。
# opinions.tsv 保留每位主体的原始立场，codev_opinions 按问题回放，并据此判断组是否真的达成一致。
CODEV_OPINIONS="${CODEV_OPINIONS:-${XDG_STATE_HOME:-$HOME/.local/state}/codev/opinions.tsv}"

# codev_run <cmd...> — 超时封装。取代 `$TP <cmd>` 变量前缀：
# zsh 不对无引号变量做词拆分，`$TP cmd`（TP="/path/timeout 600"）会被当成名为
# 「timeout 600」的单个文件执行而失败；用函数 + "$@" 传参，bash/zsh 都对。
# CODEV_TIMEOUT（默认 600s）只兜底真正卡死的进程——慢模型靠【后台执行】跑完，不受前台 300s 约束；核实型评审可调到 1200。
# -k 15：先发 TERM、15 秒后补 KILL。不加的话 trap 了 SIGTERM 的 CLI（Node/Python 的优雅退出处理器）
# 会活过 CODEV_TIMEOUT，超时就成了摆设（GC 已按 owner pid 判活，不会因此误删活沙盒，但进程会一直挂着）。
codev_run() {
  if [ -n "$CODEV_TO" ]; then "$CODEV_TO" -k 15 "$CODEV_TIMEOUT" "$@"; else "$@"; fi
}

# codev_classify <agent> <rc> <outfile> <errfile> — 把一次调用归成一个类别（只输出类别名）：
#   timeout | quota | auth | turns | error | empty | ok
# 为什么不能只看退出码（均为实测事故）：
#   - qoderclicn 额度耗尽时把 "You've reached your credit usage limit" 打到【stdout】且 exit 0
#     → 旧逻辑判 ✔，那句话会被当成评审逐字呈现；
#   - codex 撞用量上限时 stdout 空、错误行在 1MB stderr 的【尾部】（头 5 行只是 banner）；
#   - codebuddy 429 的错误串里带【重置时间】，不显示出来用户就得自己翻 err 文件；
#   - reasonix "context canceled"、codebuddy "Max turns (N) exceeded" 都是 stdout 空 + 一行 stderr。
# 误报防护：stdout 只在【很短】（<600 字节）时才拿去匹配额度模式——正常评审正文里出现 "quota"/"429"
# （比如被评审的代码就是限流模块）不该被误判；stderr 只看"错误行"（以 ERROR/error/错误/三位状态码开头的行），
# 不扫 codex 回显的提示词和文件清单。
codev_classify() {
  local agent="$1" rc="$2" out="$3" err="$4" osz=0 short="" errlines="" c=""
  # 124 = timeout 发 TERM 后退出；137 = 子进程 trap 了 TERM、-k 补 KILL 后退出（timeout 自身也回 137）。
  [ "$rc" = "124" ] || [ "$rc" = "137" ] && { echo timeout; return 0; }
  [ -s "$out" ] && osz=$(wc -c < "$out" | tr -d ' ')
  [ "$osz" -gt 0 ] && [ "$osz" -lt 600 ] && short=$(cat "$out" 2>/dev/null)
  errlines=$(codev_err_lines "$err")
  # ① 很短的 stdout 本身就是错误串（qoderclicn 额度、某些 CLI 把登录提示打到 stdout）→ 按其类别。
  #    但【像评审结论的短回复】不走这条：consult/quick 模式下 "LGTM. No P1. The 401 handling is correct."
  #    也不到 600 字节，光靠额度/鉴权关键词会把有效评审判成 auth/quota 丢掉，还进账本记它一次失败。
  #    结论标记（PASS/FAIL/LGTM/P1-P3/✔/结论/发现/Markdown 标题）是错误串里绝不会出现的东西。
  if [ -n "$short" ] && ! printf '%s' "$short" | grep -qE '(^|[^A-Za-z])(PASS|FAIL|LGTM|P[123])([^A-Za-z]|$)|✔|结论|发现|^#'; then
    c=$(codev_match_class "$short"); [ -n "$c" ] && { echo "$c"; return 0; }
  fi
  # ①' 长 stdout（≥600 字节）不能一律放行：额度/登录页也可能是一整页 HTML/说明文（三轮评审都提了这条）。
  #    但也不能用 ① 的宽模式：consult 式的长散文回答里讨论 "429 / rate limit" 很正常、又没有 P 级/标题标记，
  #    会被误杀成 quota（第 4 轮自查实测 860 字节散文 → quota）。所以三条同时成立才判：
  #    【全文】无评审结论标记、【开头 600 字节】命中【强】错误短语（不设总长上限：5KB 的 HTML 额度页也见过）——
  #    只认"用量/额度已耗尽、请登录、密钥无效"这类整句，不认 rate limit / 429 / 401 / authentication 这类可能出现在正文里的词。
  if [ "$osz" -ge 600 ] && ! grep -qE '(^|[^A-Za-z])(PASS|FAIL|LGTM|P[123])([^A-Za-z]|$)|✔|结论|发现|^#' "$out" 2>/dev/null; then
    # 只认整句：评审限流模块的散文里也会出现 "usage limit" / "quota limit" 这种词，要的是 "you've reached your usage limit" 这种句子。
    if head -c 600 "$out" 2>/dev/null | grep -qiE "(you('ve| have)|has been|have been) (reached|exceeded|hit) (your |the )?(daily |monthly )?(usage|credit|quota|rate|request) limit|credit usage limit|quota (has been )?exceeded|额度(已)?(用尽|耗尽|不足)|insufficient (balance|credit|funds)|resource.?exhausted|upgrade your (subscription|plan)"; then echo quota; return 0; fi
    if head -c 600 "$out" 2>/dev/null | grep -qiE 'not logged in|please (log ?in|login)|invalid api key|login (required|expired)|登录已过期|认证失败|请先登录'; then echo auth; return 0; fi
  fi
  # ② stdout 为空：stderr 错误行决定类别；没有错误行且 rc=0 → empty。
  if [ "$osz" -eq 0 ]; then
    c=$(codev_match_class "$errlines"); [ -n "$c" ] && { echo "$c"; return 0; }
    if [ "$rc" != "0" ] || [ -n "$errlines" ]; then echo error; else echo empty; fi
    return 0
  fi
  # ③ stdout 有正文：即使 stderr 有额度错误也算 ok（正文可能只是被截断——codev_report 会附警告让人核对），
  #    不能把已经产出的评审整份作废。
  [ "$rc" != "0" ] && { echo error; return 0; }
  echo ok
}

# codev_match_class <text> — 文本命中已知致命模式时输出 quota / auth / turns，否则输出空串。
codev_match_class() {
  local t="$1"
  [ -n "$t" ] || return 0
  if printf '%s' "$t" | grep -qiE 'usage limit|rate limit|credit usage|quota|额度|频率限制|too many requests|insufficient (balance|credit|funds)|resource.?exhausted|(^|[^0-9])(429|402)([^0-9]|$)'; then
    echo quota; return 0
  fi
  if printf '%s' "$t" | grep -qiE 'unauthorized|not logged in|please (log ?in|login)|invalid api key|authentication|鉴权|认证失败|登录已过期|(^|[^0-9])401([^0-9]|$)'; then
    echo auth; return 0
  fi
  if printf '%s' "$t" | grep -qiE 'max turns'; then echo turns; return 0; fi
  return 0
}

# codev_err_lines <errfile> — 从 stderr 里抽"错误行"（最多 6 行）：以 ERROR/Error/error/错误/Err 或三位
# HTTP 状态码开头的行，外加 "context canceled"/"Max turns" 这类无前缀的已知致命句。
codev_err_lines() {
  local err="$1"
  [ -s "$err" ] || return 0
  grep -aE '^[[:space:]]*(ERROR|Error|error|Err|错误|FATAL|fatal|panic)[:：[:space:]]|^[[:space:]]*[0-9]{3}[[:space:]]|context canceled|[Mm]ax turns' "$err" 2>/dev/null | tail -n 6
}

# codev_tokens <agent> — 能拿到才输出 "tokens N"（拿不到输出空串，调用方省略该字段，绝不编造）：
#   codex   : stderr 末尾的 "tokens used" 下一行；
#   reasonix: 调用时带 --metrics "$CODEV_DIR/codev-metrics-reasonix.json"（实测 v1.35 可用），
#             取 prompt_tokens + completion_tokens。
# Claude-Code 系 CLI（codebuddy 等）用 `--output-format json` 时，stdout 是一个消息数组，
# 末元素 type=result 同时带 .result（正文）、.usage（token）、.total_cost_usd（成本）。
# 这里把正文还原回 codev-out-<agent>.txt，并把用量归一化成 metrics JSON——复用 codev_tokens /
# codev_cost 既有的解析路径，不必为每个 CLI 各写一套提取器。
# 【fail-safe】任何一步不满足就原样不动：宁可少一条计量，也不能毁掉要逐字呈现的正文。
# 必须在 codev_classify 之前调用：JSON 包着的正文会让 classify 的结论标记/错误短语判据失准。
codev_unwrap_result() {
  local agent="$1" out="$CODEV_DIR/codev-out-$1.txt" m="$CODEV_DIR/codev-metrics-$1.json" unwrap_rc
  [ -s "$out" ] || return 0
  [ "$(head -c 1 "$out" 2>/dev/null)" = "[" ] || return 0   # 不是 JSON 数组就不碰
  command -v python3 >/dev/null 2>&1 || return 0
  if python3 - "$out" "$m" <<'CODEV_UNWRAP_PY' >/dev/null 2>&1
import json, os, sys
out, mfile = sys.argv[1], sys.argv[2]
with open(out, encoding="utf-8") as f:
    d = json.load(f)
if not isinstance(d, list) or not d:
    raise SystemExit(1)
last = d[-1]
if not isinstance(last, dict) or last.get("type") != "result":
    raise SystemExit(1)
text = last.get("result")
subtype = last.get("subtype", "")
if not isinstance(subtype, str):
    raise SystemExit(11 if last.get("is_error") is True else 1)
failed = last.get("is_error") is True or subtype.startswith("error")
failure_status = (10 if "max_turns" in subtype else 11) if failed else 0
if failed and (text is None or text == ""):
    text = subtype or "structured result reports an error"
if not isinstance(text, str) or not text.strip():
    raise SystemExit(failure_status or 1)
u = last.get("usage") or {}
if not isinstance(u, dict):
    raise SystemExit(failure_status or 1)  # 保留原文，但不能丢失已识别的失败状态
tmp = out + ".unwrap"
try:
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, out)         # 原子替换，半截文件不会被 agent 读到
except OSError:
    raise SystemExit(failure_status or 1)
# 归一化成 codev_tokens/codev_cost 认得的键名；取不到的写 null，两边的正则都要求冒号后紧跟数字，
# 所以 null 会被安全地当成"没有该项"。
metrics = {
    "prompt_tokens": u.get("input_tokens"),
    "completion_tokens": u.get("output_tokens"),
    "cost": last.get("total_cost_usd"),
    "currency": "USD",
}
try:
    if metrics["prompt_tokens"] is not None or metrics["cost"] is not None:
        with open(mfile, "w", encoding="utf-8") as f:
            json.dump(metrics, f)
except OSError:
    raise SystemExit(failure_status or 1)
raise SystemExit(failure_status)
CODEV_UNWRAP_PY
  then return 0
  else unwrap_rc=$?; fi
  # 10/11 表示成功解包的结构化失败，不是解析失败。report 必须优先采用这一状态。
  case "$unwrap_rc" in 10|11) return "$unwrap_rc";; *) return 0;; esac
}

codev_tokens() {
  local agent="$1" err="$CODEV_DIR/codev-err-$1.txt" m="$CODEV_DIR/codev-metrics-$1.json" n="" a b v=""
  # 编排器直接告知的用量：子 agent（G1 check / G2 self）没有 CLI、拿不到 metrics 文件，
  # 用量只有编排器手里有。与 codev_model_of 的 CODEV_MODEL_<agent> 同一范式。
  # agent 名先过白名单再 eval（同 codev_model_of），防注入；值必须全是数字才采信。
  case "$agent" in *[!A-Za-z0-9_]*|'') ;; *) eval "v=\${CODEV_TOKENS_$agent:-}";; esac
  case "$v" in ''|*[!0-9]*) ;; *) printf 'tokens %s' "$v"; return 0;; esac
  case "$agent" in
    codex)
      n=$(grep -aiA1 'tokens used' "$err" 2>/dev/null | tail -n 1 | tr -cd '0-9') ;;
    *)
      if [ -s "$m" ]; then
        # 只取【第一次出现】：metrics JSON 里同名键会在嵌套的 per-provider 段重复出现，
        # 不加 head -n1 会把多个数字串接成一个天文数字（实测 5826 → 58265848）。
        # 同 codev_cost：冒号后紧跟数字，否则 "prompt_tokens": null 会串到下一个键的数字上。
        a=$(grep -o '"prompt_tokens"[[:space:]]*:[[:space:]]*[0-9][0-9]*' "$m" 2>/dev/null | head -n 1 | tr -cd '0-9')
        b=$(grep -o '"completion_tokens"[[:space:]]*:[[:space:]]*[0-9][0-9]*' "$m" 2>/dev/null | head -n 1 | tr -cd '0-9')
        [ -n "$a" ] && n=$(( ${a:-0} + ${b:-0} ))
      fi ;;
  esac
  [ -n "$n" ] && printf 'tokens %s' "$n"
  return 0
}

# codev_model_of <agent> — 该次调用的模型名：优先环境变量 CODEV_MODEL_<agent>（Claude 在调用命令里
# `export CODEV_MODEL_reasonix=deepseek-v4` 设，值来自 -m/--model 或该 CLI 的默认）；codex 从 stderr banner
# 的 "model: xxx" 行取；都没有输出 unknown。账本与 commit trailer 都靠它记模型。
codev_model_of() {
  local agent="$1" v=""
  case "$agent" in *[!A-Za-z0-9_]*|'') echo unknown; return 0;; esac
  eval "v=\${CODEV_MODEL_$agent:-}"
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  if [ "$agent" = codex ] && [ -s "$CODEV_DIR/codev-err-codex.txt" ]; then
    v=$(grep -am1 '^model: ' "$CODEV_DIR/codev-err-codex.txt" 2>/dev/null | sed 's/^model: //' | tr -d '\r')
  fi
  printf '%s' "${v:-unknown}"
}

# codev_cost <agent> — 能取到才输出 "0.052 CNY"（reasonix --metrics 的 cost/currency 首次出现）；否则空串。
codev_cost() {
  local agent="$1" m="$CODEV_DIR/codev-metrics-$1.json" c u v=""
  # 同 codev_tokens：编排器可直接告知，形如 "1.29 CNY"。只接受 数字/点/空格/字母。
  case "$agent" in *[!A-Za-z0-9_]*|'') ;; *) eval "v=\${CODEV_COST_$agent:-}";; esac
  case "$v" in '') ;; *[!0-9.\ A-Za-z]*) ;; *) printf '%s' "$v"; return 0;; esac
  [ -s "$m" ] || return 0
  # 冒号后必须【紧跟】数字：不锚定的话 "cost": null 会一路吃到同一行下一个数字（实测把 4210 个 token 当成 4210.000 CNY 报出去）。
  c=$(grep -o '"cost"[[:space:]]*:[[:space:]]*[0-9][0-9.]*' "$m" 2>/dev/null | head -n 1 | sed 's/.*[^0-9.]\([0-9][0-9.]*\)$/\1/')
  u=$(grep -o '"currency"[[:space:]]*:[[:space:]]*"[A-Za-z]*"' "$m" 2>/dev/null | head -n 1 | sed 's/.*"\([A-Za-z]*\)"$/\1/')
  [ -n "$c" ] && printf '%.3f %s' "$c" "${u:-?}"
  return 0
}

# codev_reset_note <text> — 从额度/限流错误串里抽重置时间："将在 X 重置" / "try again at X" / "resets at X"。
codev_reset_note() {
  local t="$1" r=""
  r=$(printf '%s' "$t" | sed -nE 's/.*将在 ?(.+) ?重置.*/\1/p' | head -n 1 | sed 's/[ ，,.。]*$//')
  [ -z "$r" ] && r=$(printf '%s' "$t" | sed -nE 's/.*(try again|resets?|available) (at|after|in) ([^.。,，]+).*/\3/p' | head -n 1)
  [ -n "$r" ] && printf '重置 %s' "$r"
  return 0
}

# codev_ledger_append <agent> <class> <rc> <secs> [note] — 追加一行到跨会话账本（失败静默）。
# 列：时间 会话 agent 模型 类别 rc 用时 提示词字节 输出字节 tokens 成本 备注（12 列，制表符分隔）。
codev_ledger_append() {
  local agent="$1" cls="$2" rc="$3" secs="$4" note="${5:-}" pb=0 ob=0 d tk cost
  d=$(dirname "$CODEV_LEDGER"); mkdir -p "$d" 2>/dev/null || return 0
  [ -s "$CODEV_DIR/codev-prompt-$agent.txt" ] && pb=$(wc -c < "$CODEV_DIR/codev-prompt-$agent.txt" | tr -d ' ')
  [ -s "$CODEV_DIR/codev-out-$agent.txt" ] && ob=$(wc -c < "$CODEV_DIR/codev-out-$agent.txt" | tr -d ' ')
  tk=$(codev_tokens "$agent" | tr -cd '0-9'); cost=$(codev_cost "$agent")
  note=$(printf '%s' "$note" | tr '\t\n' '  ')
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%Y-%m-%dT%H:%M)" "$(basename "$CODEV_DIR")" \
    "$agent" "$(codev_model_of "$agent")" "$cls" "$rc" "$secs" "$pb" "$ob" "${tk:--}" "${cost:--}" "${note:--}" >> "$CODEV_LEDGER" 2>/dev/null
  return 0
}

# codev_ledger_recent <agent> — 该 agent 最近 3 次类别（旧→新，quota 附重置时间）+ 最近一次时间。
codev_ledger_recent() {
  local agent="$1" rows
  [ -s "$CODEV_LEDGER" ] || return 0
  # 兼容升级前写下的旧行：7 列布局是 时间 agent 类别 rc 用时 提示词字节 输出字节（agent 在第 2 列、类别在第 3 列）。
  # 只认 12 列的话，老用户升级后 probe 的"近期 3 次结果"会整片消失，连续 quota 的 agent 就拦不住了。
  rows=$(grep -a "	$agent	" "$CODEV_LEDGER" 2>/dev/null | awk -F'\t' -v a="$agent" 'NF>=12 && $3==a { print } NF==7 && $2==a { print $1 "\t-\t" $2 "\t-\t" $3 "\t" $4 "\t" $5 "\t" $6 "\t" $7 "\t-\t-\t-" }' | tail -n 3)
  [ -n "$rows" ] || return 0
  printf '%s (最近 %s)' \
    "$(printf '%s\n' "$rows" | awk -F'\t' '{ if ($5=="quota" && $12!="-") printf "%s(%s) ", $5, $12; else printf "%s ", $5 }' | sed 's/ $//')" \
    "$(printf '%s\n' "$rows" | tail -n 1 | cut -f1 | cut -c6-)"
}

# codev_session_summary — 本会话（CODEV_DIR）所有调用的 用时/tokens/成本 一览，fan-out 全部结束后打印一次。
codev_session_summary() {
  local sess
  sess=$(basename "$CODEV_DIR")
  [ -s "$CODEV_LEDGER" ] || { echo "（本会话无账本记录）"; return 0; }
  echo "本会话用量（agent 模型 类别 用时 tokens 成本）："
  awk -F'\t' -v s="$sess" '$2==s { printf "  %-10s %-18s %-8s %4ss  %8s  %s\n", $3, $4, $5, $7, $10, $11 }' "$CODEV_LEDGER"
}

# codev_finding_add <repo> <doc> <round> <agent> <model> <id> <severity> <column> <verdict> <verified> <unique> <desc>
# 发现台账追加一行（13 列：时间 + 12 个入参；入参里的制表符/换行会被替换成空格）。
#   severity: P1/P2/P3   column: A/B（agent 自报的已查证/待核实）   verdict: 采纳/驳回/存疑
#   verified: 成立/不成立/待定（Claude 亲验结果）   unique: 独家/共同（是否只有这一家发现）
codev_finding_add() {
  # 必须是 -eq：-ge 会放过没加引号的多词描述（"漏 tenant_id" 拆成 3 个实参），写出 13 列以外的坏行。
  [ $# -eq 12 ] || { echo "用法: codev_finding_add repo doc round agent model id severity column verdict verified unique desc（12 个实参，描述记得加引号）" >&2; return 1; }
  # 【枚举校验】三个判定列必须是中文枚举：codev_stats 只认中文，写成 adopted/yes 会被静默计 0，
  # 台账看着有行、统计却全是零（实测本机 48 行 adopted + 129 行 yes 就是这么来的，跨会话累积、
  # 事后才发现）。宁可当场拒收让调用方改对，也不要留一条永远不会被统计到的行。
  case "$9"  in 采纳|驳回|存疑) ;; *) echo "codev_finding_add: 第 9 个实参（verdict）须为 采纳/驳回/存疑，收到「$9」" >&2; return 1;; esac
  case "${10}" in 成立|不成立|待定) ;; *) echo "codev_finding_add: 第 10 个实参（verified）须为 成立/不成立/待定，收到「${10}」" >&2; return 1;; esac
  case "${11}" in 独家|共同) ;; *) echo "codev_finding_add: 第 11 个实参（unique）须为 独家/共同，收到「${11}」" >&2; return 1;; esac
  local d f
  d=$(dirname "$CODEV_FINDINGS"); mkdir -p "$d" 2>/dev/null || return 1
  printf '%s' "$(date +%Y-%m-%dT%H:%M)" >> "$CODEV_FINDINGS"
  for f in "$@"; do printf '\t%s' "$(printf '%s' "$f" | tr '\t\n' '  ')" >> "$CODEV_FINDINGS"; done
  printf '\n' >> "$CODEV_FINDINGS"
}

# codev_stats [repo] — 按 agent+模型汇总发现台账：声称 P1 里经亲验成立的比例、独家且成立数、总条数、采纳数。
codev_stats() {
  local repo="${1:-}"
  [ -s "$CODEV_FINDINGS" ] || { echo "（发现台账为空：${CODEV_FINDINGS}）"; return 0; }
  echo "发现台账统计（agent 模型 | P1 成立/声称 | 独家成立 | 总条数 | 采纳）${repo:+，仓库=$repo}："
  # LC_ALL=C 必须：macOS 自带 awk（BWK 20200816）在 UTF-8 locale 下 "不成立"=="成立" 判真（实测 3/3），
  # 中文字段相等比较只能按字节做。
  LC_ALL=C awk -F'\t' -v r="$repo" '
    r=="" || $2==r {
      k=$5 "\t" $6; n[k]++
      if ($8=="P1") { p1[k]++; if ($11=="成立") ok[k]++ }
      if ($12=="独家" && $11=="成立") u[k]++
      if ($10=="采纳") a[k]++
    }
    END { for (k in n) { split(k, kk, "\t"); printf "  %-10s %-18s P1 %d/%d  独家成立 %d  总 %d  采纳 %d\n", kk[1], kk[2], ok[k]+0, p1[k]+0, u[k]+0, n[k], a[k]+0 } }' "$CODEV_FINDINGS" | sort
}

# codev_opinion_add <repo> <doc> <round> <agent> <model> <role> <issue> <stance> <severity> <fix> <note>
# 意见与判断记录追加一行（13 列：时间 + 11 个入参 + task；仍兼容旧 12 列记录）。
# task 用 CODEV_TASK_ID；未指定时用 CODEV_DIR 的会话名，跨会话恢复须显式沿用 CODEV_TASK_ID。
# 入参里的制表符/换行会被替换成空格，写入接口仍严格只收 11 个实参。
#   role:     评审（提出问题）/ 判断（对某问题裁决）/ 自审（self review 阶段的发现）/ 复核（补修后定向复核）
#   issue:    稳定问题 ID 或发现编号（r<轮次>-<agent>-<序号>）；同一问题的多方立场靠它串起来
#   stance:   提出 / 采纳 / 驳回 / 存疑 / 未返回（未返回是显式记录缺席，不能当同意——见 spec §3.4）
#   severity: P1/P2/P3/-（各主体可以给不同级别，差异本身要留痕，不能取低值绕门禁）
#   fix:      该主体选定的具体修法（判断组是否"同意相同修法"就靠比这一列）；没有写 -
#   note:     证据、快照 ID 或原话摘要
# 一个 agent 对一个问题可以有多行（先提出、后裁决）；同一任务/对象/轮次内按 (agent, issue, role)
# 的最后追加行取有效立场，改主意就在 note 里写明改判依据，不覆盖旧行。
codev_opinion_add() {
  # 与 codev_finding_add 同理必须是 -eq：-ge 会放过没加引号的多词修法，写出列数错误的坏行。
  [ $# -eq 11 ] || { echo "用法: codev_opinion_add repo doc round agent model role issue stance severity fix note（11 个实参，修法和备注记得加引号）" >&2; return 1; }
  case "$6"  in 评审|判断|自审|复核) ;; *) echo "codev_opinion_add: 第 6 个实参（role）须为 评审/判断/自审/复核，收到「$6」" >&2; return 1;; esac
  case "$8"  in 提出|采纳|驳回|存疑|未返回) ;; *) echo "codev_opinion_add: 第 8 个实参（stance）须为 提出/采纳/驳回/存疑/未返回，收到「$8」" >&2; return 1;; esac
  case "$9"  in P1|P2|P3|-) ;; *) echo "codev_opinion_add: 第 9 个实参（severity）须为 P1/P2/P3/-，收到「$9」" >&2; return 1;; esac
  local d f
  d=$(dirname "$CODEV_OPINIONS"); mkdir -p "$d" 2>/dev/null || return 1
  printf '%s' "$(date +%Y-%m-%dT%H:%M)" >> "$CODEV_OPINIONS"
  for f in "$@"; do printf '\t%s' "$(printf '%s' "$f" | tr '\t\n' '  ')" >> "$CODEV_OPINIONS"; done
  printf '\t%s\n' "$(printf '%s' "${CODEV_TASK_ID:-$(basename "$CODEV_DIR")}" | tr '\t\n' '  ')" >> "$CODEV_OPINIONS"
}

# codev_opinions [issue [repo [doc [round [task]]]]] — 空参数为该维度不过滤；不传参数回放全部。
# 按 repo/doc/round/task/issue 隔离，只用每位判断主体最后追加的立场计票，完整历史仍按角色展示。
codev_opinions() {
  [ $# -le 5 ] || { echo "用法: codev_opinions [issue [repo [doc [round [task]]]]]" >&2; return 1; }
  local want="${1:-}" repo="${2:-}" doc="${3:-}" round="${4:-}" task="${5:-}"
  [ -s "$CODEV_OPINIONS" ] || { echo "（意见记录为空：${CODEV_OPINIONS}）"; return 0; }
  echo "意见与判断记录（${CODEV_OPINIONS}）${want:+，问题=$want}："
  # 不排序：时间戳只有分钟精度，甚至可能回退；NR 才代表真实追加顺序。
  # LC_ALL=C 避免 macOS awk 的中文相等比较问题；长度前缀避免范围字段拼接碰撞。
  LC_ALL=C awk -F'\t' -v want="$want" -v repo="$repo" -v doc="$doc" -v round="$round" -v task="$task" '
    function part(s) { return length(s) ":" s }
    function flush(g,   v,i,row,f,nj,adopt,reject,uniqfix,lastfix,stances,p1seen,firstsev,sevdiff,missing,a) {
      printf "%s\n%s%s%s%s", head[g], hist[g,"评审"], hist[g,"自审"], hist[g,"判断"], hist[g,"复核"]
      nj = judges[g]+0
      for (i=1; i<=nj; i++) {
        row = latest[g,agent[g,i]]
        split(row,a,"\t")
        f=a[11]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", f)
        if (a[9]=="采纳") {
          adopt++
          if (f=="" || f=="-" || f=="同意" || f=="待补充" || f=="TBD") missing=1
          if (!uniqfix) { uniqfix=1; lastfix=f } else if (f!=lastfix) uniqfix=2
        }
        if (a[9]=="驳回") reject++
        if (a[10]=="P1") p1seen=1
        if (i==1) firstsev=a[10]; else if (a[10]!=firstsev) sevdiff=1
        stances = (stances=="" ? a[9] : stances "/" a[9])
      }
      if (nj == 0)            v = "→ 判断组尚无记录（目前只有评审/自审意见）"
      else if (nj > 2)        v = "→ 判断主体超过两个：选择冲突，不进入执行清单"
      else if (p1seen && sevdiff) v = "→ 判断组严重级别分歧：涉及 P1，澄清前不进入执行清单或关闭该项"
      else if (missing)      v = "→ 采纳意见缺少具体修法：待补充，不进入执行清单"
      else if (reject == nj)  v = "→ 判断组一致驳回：关闭该项，保留驳回依据"
      else if (adopt == nj && uniqfix == 1) v = "→ 判断组一致采纳同一修法：可进执行清单"
      else if (adopt == nj)   v = "→ 均认为缺陷成立但修法不同：缺陷 open、修法 disputed，不执行任意一方"
      else                    v = "→ 判断组未达成一致（" stances "）：只执行明确一致且可独立执行的部分"
      if (legacy[g] && (v ~ /可进执行清单|一致驳回/)) v = "→ 旧记录仅供回顾：缺少 task ID，补齐任务归属前不进入执行清单或关闭该项"
      printf "  %s\n", v
      if (p1seen && (sevdiff || missing || nj>2 || v ~ /未达成一致|disputed/)) printf "  %s\n", "⚠️ 涉及 P1：澄清前按潜在阻塞项保留，不得取较低级别放行"
      if (legacy[g]) print "  ⚠️ 旧记录缺少 task ID：仅按仓库/对象/轮次隔离，无法区分同范围内的不同历史任务"
      printf "\n"
    }
    (NF==12 || NF==13) && (want=="" || $8==want) && (repo=="" || $2==repo) && (doc=="" || $3==doc) && (round=="" || $4==round) && (task=="" || $13==task) {
      key=part($2) part($3) part($4) part($13) part($8)
      if (!(key in groups)) {
        groups[key]=++count; g=count; legacy[g]=($13=="")
        head[g]=sprintf("%s  [repo=%s doc=%s r%s task=%s]", ($8=="" ? "(缺问题 ID)" : $8), $2, $3, $4, ($13=="" ? "(旧记录缺失)" : $13))
      } else g=groups[key]
      # 不用 %-Ns 对齐中文列：awk 按字节算宽度，"评审"占 6 字节反而把版面撑歪。
      line = "  " $7 " " $5 "(" $6 ")  " $9 "  " $10 "  修法: " $11 ($12 == "-" || $12 == "" ? "" : "  ｜ " $12) "\n"
      hist[g,$7]=hist[g,$7] line
      if ($7 == "判断") {
        if (!((g,$5) in latest)) { judges[g]++; agent[g,judges[g]]=$5 }
        latest[g,$5]=$0
      }
    }
    END { for (g=1; g<=count; g++) flush(g); if (!count) print "  （没有匹配的记录）" }' "$CODEV_OPINIONS"
}

# codev_commit_round <files> <round> <reviewers> <p1> <prev_p1> <summary> [extra-trailer...]
# 一轮回流后的 commit：【只提交 <files> 里显式列出的文件】，绝不 add -A，也【不收目录】——工作树里常有
# 用户自己未提交的无关改动，给目录会把它们一起卷进来，而且 add/commit 在同一次调用里，调用方来不及干预。
# <files> = 空格或换行分隔的文件路径列表（因此路径不能含空格）；传目录直接报错返回 1。
# 提交信息 = <summary> + 空行 + trailer 块（Codev-Round / Codev-Reviewed-By / Codev-Verified-P1 + 透传的额外 trailer，
# 如 Co-Authored-By）。trailer 让 `git log --grep '^Codev-Round: 2'` 能直接回答"第 2 轮评了谁、剩几条 P1"。
codev_commit_round() {
  [ $# -ge 6 ] || { echo "用法: codev_commit_round files round reviewers p1 prev_p1 summary [trailer...]" >&2; return 1; }
  # 变量名【绝不能叫 path】：zsh 里 path 是绑定 $PATH 的特殊数组，local path=… 会把 PATH 换成该路径，
  # 函数体内 git/mktemp/sed 全部 command not found。同理见 codev_prev_round_commit。
  local files="$1" round="$2" rev="$3" p1="$4" prev="$5" summary="$6" msg t rc
  shift 6                                   # 剩下的位置参数是要透传的 trailer，先写进 msg 再复用位置参数装文件列表
  msg=$(mktemp -t codev-msg.XXXXXX) || return 1
  {
    printf '%s\n\n' "$summary"
    printf 'Codev-Round: %s\n' "$round"
    printf 'Codev-Reviewed-By: %s\n' "$rev"
    printf 'Codev-Verified-P1: %s (prev %s)\n' "$p1" "$prev"
    for t in "$@"; do printf '%s\n' "$t"; done
  } > "$msg"
  # 把 <files> 拆成逐个位置参数。【不能】写 `set -- $files`：zsh 默认不对未加引号的变量做词拆分
  # （SH_WORD_SPLIT 关着，$# 恒为 1），而 `set -f` 在 zsh 里开的是 NO_RCS 而不是 NO_GLOB。
  # 用 read 逐行收：不依赖拆词、不经过通配，bash/zsh 行为一致。
  set --
  while IFS= read -r t; do [ -n "$t" ] && set -- "$@" "$t"; done <<CODEV_EOF
$(printf '%s\n' "$files" | tr ' \t' '\n\n')
CODEV_EOF
  if [ $# -lt 1 ]; then echo "⚠️ 没有给任何文件路径" >&2; rm -f "$msg"; return 1; fi
  for t in "$@"; do
    if [ -d "$t" ]; then
      echo "⚠️ $t 是目录：codev_commit_round 只收具体文件，否则会把工作树里无关的脏文件一并提交" >&2
      rm -f "$msg"; return 1
    fi
  done
  # 提交的是【整个文件的工作树内容】（文件粒度，不是 hunk 粒度）。若用户对该文件做了部分暂存
  # （index ≠ HEAD 且 index ≠ 工作树），git add 会把边界抹平、把用户没打算提交的那部分一起带走——拒收，让用户先处理。
  for t in "$@"; do
    if ! git --literal-pathspecs diff --cached --quiet -- "$t" 2>/dev/null && ! git --literal-pathspecs diff --quiet -- "$t" 2>/dev/null; then
      echo "⚠️ $t 同时有已暂存与未暂存的改动（部分暂存）：codev_commit_round 按整文件提交，会抹掉这个边界。先 git commit 或 git reset 该文件再回流" >&2
      rm -f "$msg"; return 1
    fi
  done
  # 逐文件记下 add 之前 index 就干净的那些：commit 失败时只撤回它们（用户自己整文件暂存好的那份不动）。
  local to_reset=
  for t in "$@"; do git --literal-pathspecs diff --cached --quiet -- "$t" 2>/dev/null && to_reset="$to_reset
$t"; done
  # -- 只结束选项，不会关闭 * 或 :(glob) 等 pathspec；所有操作必须一致使用字面路径。
  if ! git --literal-pathspecs add -- "$@"; then
    printf '%s\n' "$to_reset" | while IFS= read -r t; do [ -n "$t" ] && git --literal-pathspecs reset -q -- "$t" 2>/dev/null; done
    rm -f "$msg"; return 1
  fi
  if git --literal-pathspecs diff --cached --quiet -- "$@"; then echo "⚠️ $files 没有待提交的改动，跳过 commit" >&2; rm -f "$msg"; return 1; fi
  git --literal-pathspecs diff --cached --stat -- "$@" | sed 's/^/  暂存: /'
  git --literal-pathspecs commit -q -F "$msg" -- "$@"; rc=$?
  rm -f "$msg"
  # commit 失败时把刚 add 进去的撤回，别给用户留一个它没做过的暂存状态（只撤 add 之前 index 本来干净的那些文件）。
  if [ "$rc" != 0 ] && [ -n "$to_reset" ]; then
    printf '%s\n' "$to_reset" | while IFS= read -r t; do [ -n "$t" ] && git --literal-pathspecs reset -q -- "$t" 2>/dev/null; done
  fi
  [ "$rc" = 0 ] && echo "✔ 已提交第 $round 轮回流：$(git log -1 --format=%h) $summary"
  return $rc
}

# codev_prev_round_commit <path> <round> — 找触及 <path> 且 trailer 为 Codev-Round: <round-1> 的最近 commit（找不到输出空）。
# 用途：第 N 轮提示词里内联 `git diff <该 commit> -- <path>`，让 agent 看到两版之间的真实差异而不是手写的"改动章节"。
codev_prev_round_commit() {
  local f="$1" round="$2" prev                 # 变量名不能叫 path：zsh 里它绑定 $PATH，见 codev_commit_round 的注释
  prev=$((round - 1)); [ "$prev" -ge 1 ] || return 0
  git log --format=%H --grep="^Codev-Round: $prev\$" -- "$f" 2>/dev/null | head -n 1
}

# codev_archive <slug> <round> — 把本会话的 prompt/out/err/metrics 归档到 <仓库根>/.superpowers/codev/<slug>/r<N>/。
# 会话目录 24h 后被 GC，归档让"第 3 轮 codex 当时原话是什么"仍可查；目录用 common gitdir 的 info/exclude
# 保证不入库（本地生效、不改仓库的 .gitignore）。评审原文不进 git：几十 KB × 多家 × 多轮会堆满仓库。
codev_archive() {
  [ $# -eq 2 ] || { echo "用法: codev_archive slug round" >&2; return 1; }
  local slug="$1" round="$2" root gitdir dest f files
  case "$round" in ''|*[!0-9]*) echo "⚠️ 归档轮次必须为数字" >&2; return 1;; esac
  root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "⚠️ 非 git 仓库，跳过归档" >&2; return 1; }
  # 不能硬写 $root/.git：worktree / submodule 里 .git 是【文件】，mkdir 会失败，exclude 就写不进去。
  # 要的是 common dir 而不是 --absolute-git-dir：linked worktree 的 info/exclude 只认共享 gitdir，
  # 写进 .git/worktrees/<name>/info/exclude 是不生效的（实测 check-ignore 仍为 NOT）。
  gitdir=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null)
  case "$gitdir" in ''|/*) ;; *) gitdir="$root/$gitdir";; esac
  slug=$(printf '%s' "$slug" | tr -c 'A-Za-z0-9._-' '-')
  case "$slug" in ''|.|..) echo "⚠️ 归档 slug 无效" >&2; return 1;; esac
  dest="$root/.superpowers/codev/$slug/r$round"
  mkdir -p "$dest" || return 1
  if ! git -C "$root" check-ignore -q ".superpowers/codev/$slug/r$round/x" 2>/dev/null; then
    [ -n "$gitdir" ] && mkdir -p "$gitdir/info" && printf '.superpowers/\n' >> "$gitdir/info/exclude"
  fi
  # 用 find 而不是 for f in "$CODEV_DIR"/xxx-*：zsh 默认 NOMATCH，glob 匹配不到文件时直接报错终止函数
  # （只有 metrics 缺失就整个归档失败）。find 还顺带能扛住路径里的空格。
  files=$(mktemp "$CODEV_DIR/codev-archive.XXXXXX") || return 1
  if ! find "$CODEV_DIR" -maxdepth 1 -type f \( -name 'codev-prompt-*.txt' -o -name 'codev-out-*.txt' \
    -o -name 'codev-err-*.txt' -o -name 'codev-metrics-*.json' \) -print0 > "$files"; then
    rm -f "$files"; return 1
  fi
  while IFS= read -r -d '' f; do
    if ! cp -- "$f" "$dest/"; then
      echo "⚠️ 归档复制失败，目标可能不完整：$dest" >&2
      rm -f "$files"; return 1
    fi
  done < "$files"
  rm -f "$files"
  # 只有真的忽略掉了才这么说——评审原文含仓库 diff，被误 `git add -A` 进仓库比不归档更糟。
  if git -C "$root" check-ignore -q ".superpowers/codev/$slug/r$round/x" 2>/dev/null; then
    echo "已归档到 ${dest}（已被 git 忽略）"
  else
    echo "已归档到 ${dest}（⚠️ 未能写进 git 忽略，请勿 git add -A，自行确认它不进仓库）"
  fi
}

# codev_report <agent> <rc> <errfile> — 打印完成行 + 【按类别显式上报】+ 记账本。
# 关键：让调用方（Claude）不会把"无输出"误判成模型卡死、也不会把额度耗尽误判成成功；
# 超时(124)/额度/鉴权/turn/报错/空输出都清楚标注，并附 stderr 里的错误行原句（含 429 的重置时间）。
# 若调用方设了 CODEV_T0（epoch 秒，codev_bg_* 会设），完成行附"用时 Ns"；能取到 token 就附。
codev_report() {
  local agent="$1" rc="$2" err="$3" out="$CODEV_DIR/codev-out-$1.txt" cls secs="" extra="" lines tk cost note="" unwrap_rc=0
  codev_unwrap_result "$agent" || unwrap_rc=$?
  cls=$(codev_classify "$agent" "$rc" "$out" "$err")
  # 进程超时优先；其余情况下结构化 is_error/subtype 优先于正文中的 PASS、标题或退出码 0。
  if [ "$cls" != timeout ]; then
    case "$unwrap_rc" in 10) cls=turns;; 11) cls=error;; esac
  fi
  [ -n "${CODEV_T0:-}" ] && secs=$(( $(date +%s) - CODEV_T0 ))
  tk=$(codev_tokens "$agent")
  [ -n "$secs" ] && extra="用时 ${secs}s"
  [ -n "$tk" ] && extra="${extra:+$extra | }$tk"
  cost=$(codev_cost "$agent"); [ -n "$cost" ] && extra="${extra:+$extra | }$cost"
  # 全角括号不能紧贴 ${extra:+…}：bash 在 UTF-8 locale 下会把 `extra（` 一起当变量名（实测 set -u 下
  # 报 "extra（: unbound variable"）。先用普通赋值把括号包好，再以 %s 传给 printf。
  [ -n "$extra" ] && extra="（${extra}）"
  lines=$(codev_err_lines "$err")
  # 用 printf %s 传变量（不要写 "exit=$rc："——UTF-8 locale 下 bash 会把紧跟的全角字符与变量展开
  # 一起误扫，吞掉退出码；ASCII 冒号 + printf 稳）。
  case "$cls" in
    ok)      printf '✔ %s 完成 exit=0%s\n' "$agent" "$extra"
             [ -n "$lines" ] && { printf '  ⚠️ 但 stderr 含错误行（输出可能被截断，核对正文是否完整）:\n'; printf '%s\n' "$lines" | sed 's/^/  /'; } ;;
    timeout) printf '⏭ %s 跳过（超时 rc=%s%s，撞 CODEV_TIMEOUT=%ss 安全网%s）→ 缩小核实范围/改路径引用少内联/或 export CODEV_TIMEOUT=1200 后重试\n' \
               "$agent" "$rc" "$([ "$rc" = 137 ] && printf '，进程 trap 了 TERM 由 -k 补 KILL')" "$CODEV_TIMEOUT" "${secs:+，用时 ${secs}s}" ;;
    quota)   printf '⛔ %s 额度/限流（exit=%s，本轮无效，勿当评审呈现）:\n' "$agent" "$rc"
             { [ -n "$lines" ] && printf '%s\n' "$lines"; [ -s "$out" ] && head -c 600 "$out"; } | sed 's/^/  /'   # 长额度页只显示开头 600 字节
             echo "  → 跳过该 agent；错误串里若有重置时间，之后再试；换其它 agent 补位" ;;
    auth)    printf '⛔ %s 鉴权失败（exit=%s）→ 按 agents.md 的登录命令处理后重试:\n' "$agent" "$rc"
             printf '%s\n' "$lines" | sed 's/^/  /' ;;
    turns)   printf '⚠️ %s turn 预算耗尽（exit=%s，终稿未产出）→ 调高 --max-turns 并收窄核实范围到 3-5 条后重试:\n' "$agent" "$rc"
             printf '%s\n' "$lines" | sed 's/^/  /'
             [ "$unwrap_rc" = 10 ] && echo "  结构化结果标记 turn 预算耗尽，部分正文不能当作完成的评审" ;;
    empty)   printf '⚠️ %s 空输出（exit=0，stdout/stderr 均无内容，本轮无效）→ 先看 %s 分诊，勿当成"无问题"\n' "$agent" "$err" ;;
    error)   printf '⚠️ %s 非零退出/报错 exit=%s%s（stderr 错误行）:\n' "$agent" "$rc" "${secs:+，用时 ${secs}s}"
             [ "$unwrap_rc" = 11 ] && echo "  结构化结果标记失败，进程退出码 0 不代表评审成功"
             if [ -n "$lines" ]; then printf '%s\n' "$lines" | sed 's/^/  /'; elif [ -s "$err" ]; then tail -n 5 "$err" 2>/dev/null | sed 's/^/  /'; else echo "  (无 stderr)"; fi
             case "$lines" in *"context canceled"*) echo "  → reasonix 上游断流/被掐，多为提示词过大；缩到 ≤45KB 或改路径引用后重试一次";; esac ;;
  esac
  if [ "$cls" = quota ]; then
    note=$(codev_reset_note "$lines
$( [ -s "$out" ] && [ "$(wc -c < "$out" | tr -d ' ')" -lt 600 ] && cat "$out" )")
  fi
  codev_ledger_append "$agent" "$cls" "$rc" "${secs:-0}" "$note"
}

# codev_repo_copy <sbox> — 在沙盒里铺一份【只读仓库副本】到 <sbox>/repo。
# 解决"非原生只读 agent 是瞎子"：空目录让它们只能吃提示词里的文本，看不到 diff 之外的既有代码，
# 遇到"这个不变量在别处成立吗""这个函数真实调用方是谁"只能标存疑 → 假阳性。给一份【副本】既恢复
# 视野、又保住 cwd 隔离：顺手的写入落在副本上，真仓库不在 cwd 里，也就不需要快照/归因（防误写不防故意，
# 有 shell 的 agent 用绝对路径仍能碰到沙盒外）。
# 布局：<sbox> 本身可写（当 cwd，免得某些 CLI 往 cwd 写日志/会话就崩），<sbox>/repo 只读。
# 副本内容 = tracked + 未被 .gitignore 忽略的 untracked（即工作区当前状态，含待评审的未提交改动），
# 不含 .git（省体积；agent 跑不了 git 命令，diff 由提示词提供），且过滤掉明显的密钥文件（喂 tar 前按 basename
# 的 case 清单 + 解包后两轮 find，见 codev_repo_master 内注释）。
# ⚠️ 隐私边界变了：以前空目录只发提示词里那点文本，现在【整个工作区都可能被 agent 读取并发给它的模型】。
# 凡进副本的内容都要当作"已经发出去了"。文件名过滤只挡常见密钥文件名，挡不住硬编码在源码里的密钥——
# Step 2B 的 secret 扫描仍然必须做。仓库确实敏感就用 CODEV_SANDBOX_MODE=text 退回只喂文本，并排除在真仓库跑的 codex/gemini。
# 返回 0=已铺好，1=跳过（非 git 仓库 / 超体积闸门 / 拷贝失败），由调用方退回 text 模式。
# 【每个（仓库 + 工作区内容）签名只 tar 一次】：母本铺在会话目录里、路径带签名哈希（codev_master_path），
# 各 agent 的沙盒从母本 clone（见 codev_repo_copy）；同会话内改了代码再评会自动换新母本。
# 否则 N 个 agent = N 次全量 tar，大仓库上很浪费。实测 55MB / 2000 文件 / 6 agent：
# 「6 次全量 tar」5.06s → 「1 次 tar + 6 次 clone」2.72s；且 APFS clone 共享数据块——
# 额外 5 份副本的真实磁盘增量仅 6MB（df 实测；du 会虚报 ~280MB，它数不出共享块）。
CODEV_MASTER="$CODEV_DIR/codev-master-repo"

# codev_hash — stdin 的摘要（十六进制/数字串）。优先 shasum（macOS 自带 perl 版，Linux 也常有）：cksum 是 32 位 CRC，
# 碰撞可人为构造，撞上就静默复用错树；没有 shasum 才退回 POSIX 的 cksum。
# shasum 存在但跑不动（perl 环境坏）时也要能退到 cksum：先把 stdin 落到临时文件，依次尝试，谁先有输出用谁。
codev_hash() {
  # 临时文件放会话目录：输入含 git diff + 未跟踪文件全文，放 $TMPDIR 的话进程被杀就永久留一份工作区内容，GC 也不收它；
  # 会话目录随收尾 / 24h GC 一起删。CODEV_DIR 不可写时才退到 $TMPDIR。
  local t h; t=$(mktemp "$CODEV_DIR/codev-hash.XXXXXX" 2>/dev/null || mktemp -t codev-hash.XXXXXX) || return 1
  cat > "$t" || { rm -f "$t"; return 1; }
  if h=$(shasum < "$t" 2>/dev/null); then h=$(printf '%s' "$h" | cut -c1-40)
  elif h=$(cksum < "$t" 2>/dev/null); then h=$(printf '%s' "$h" | tr -cd '0-9')
  else rm -f "$t"; return 1; fi
  rm -f "$t"
  case "$h" in ''|*[!0-9a-f]*) return 1;; esac
  printf '%s' "$h"
}

# codev_master_path — 把母本路径【按仓库根 + 工作区状态】区分开，回填 CODEV_MASTER。
# 为什么需要：codev_repo_master 开头是无条件复用「母本已存在就直接用」。只要 CODEV_DIR 被复用
# （漏设时的固定路径、或用户在同一会话里换仓库/改完代码再评一轮），复用就会给出【错的树】：
#   - 跨仓库：repoB 的 agent 拿到 repoA 的母本（实测只看到 A 的文件、B 的一个都没有）；
#   - 同仓库二轮：改完代码再 review，agent 仍读第一轮的快照，把已修的问题当现存报、
#     新代码的缺陷全看不见（agents.md 里正是用这条理由否掉 git worktree 的）。
# 做法：哈希「仓库根 + HEAD + 工作区改动摘要」。任一变化 → 换一个母本目录 → 自然重铺；
# 没变化 → 命中同一个目录 → 保住"每个签名只 tar 一次"的收益。
codev_master_path() {
  local root sig h base
  root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$root" ] || return 1
  # 工作区签名：HEAD + `git status --porcelain`（哪些文件脏了）+ 【脏文件的实际内容】（git diff HEAD 覆盖
  # tracked 的已暂存/未暂存改动，未跟踪文件直接 cat）。只哈希 porcelain 是不够的：它只有状态字母 + 路径，
  # 同一个已脏文件再改几行，porcelain 一个字节都不变 → 命中旧母本 → agent 读到上一轮快照（实测三次连改同路径）。
  # 成本只与脏文件规模相关，干净仓库几乎为零。xargs -r：GNU 空输入不执行，BSD 本就不执行且接受 -r 为空操作。
  # 整段在仓库根算：`git ls-files --others` 只列 cwd 之下，从子目录调用签名会不同——同一工作区铺两份母本，
  # 只改子目录之外的未跟踪文件时还会命中旧母本。cd 放在子 shell 里，不改调用方 cwd。
  base=$(git rev-parse --verify HEAD 2>/dev/null) || base=$(git hash-object -t tree /dev/null) || return 1
  # 空仓库以空树为基线；未跟踪文件带路径和字节长度，避免 ab+c 与 a+bc 拼接碰撞。
  # pipefail 只在子 shell 生效；上游读取或哈希失败都不得产生可复用的签名。
  sig=$( ( set -o pipefail
    ( cd "$root" || exit 1
      git status --porcelain --untracked-files=all || exit 1
      git diff "$base" --binary --no-color --no-ext-diff --no-textconv || exit 1
      git ls-files --others --exclude-standard -z | while IFS= read -r -d '' f; do
        if [ -f "$f" ] && [ ! -L "$f" ]; then
          size=$(wc -c < "$f") || exit 1
          printf '\0%s\0%s\0' "$f" "$size"
          cat -- "$f" || exit 1
        fi
      done
    ) | codev_hash
  ) 2>/dev/null ) || { echo "⚠️ 工作区内容读取或哈希失败，退回 text 模式" >&2; return 1; }
  h=$(printf '%s' "$root|$base|$sig" | codev_hash) || return 1
  h=$(printf '%s' "$h" | tr -cd '0-9a-f' | cut -c1-16)
  # 哈希为空（shasum 是 perl 脚本，perl 坏了 command -v 仍能找到它；cksum 也失败）就别铺：退成 .0 会让不同仓库/
  # 状态共用同一个母本——正是上面列的"复用错树"事故。返回 1 让调用方退回 text 模式。
  [ -n "$h" ] || { echo "⚠️ 母本签名计算失败（shasum 与 cksum 都没有输出），退回 text 模式" >&2; return 1; }
  CODEV_MASTER="$CODEV_DIR/codev-master-repo.$h"
  return 0
}

# codev_repo_master — 把工作区铺成【母本】 $CODEV_MASTER（每个签名只做一次，已存在就直接复用；建成后 chmod -R a-w）。
# 返回 0=可用，1=不可用（非 git / 超闸门 / 失败）。
codev_repo_master() {
  codev_master_path || return 1     # 先按仓库+工作区状态定母本路径，避免复用到别的树
  if [ -d "$CODEV_MASTER" ]; then           # 已铺好，复用
    # 上一个 builder 若在 mv 之后、chmod 之前被杀，母本是可写的；复用前补一次 a-w（只有发布者会碰母本，补权限无竞争）。
    [ -n "$(find "$CODEV_MASTER" \( -type f -o -type d \) -perm -u+w 2>/dev/null | head -1)" ] && chmod -R a-w "$CODEV_MASTER" 2>/dev/null
    return 0
  fi
  # holder 必须在这里【一次性】声明：写成循环体内的 `local holder` 会在 zsh 下每轮打印
  # 「holder=<pid>」污染输出——zsh 未设 TYPESET_SILENT 时，对【已存在】的变量再执行不带赋值的
  # local/typeset 会显示它的当前值（实测等待循环每秒吐一行）。bash 无此行为。
  local root sz holder lock="$CODEV_MASTER.lock" waited=0 me rp
  # 【并发护栏】fan-out 时 N 个 agent 是 N 个独立 shell、会同时进到这里。没有锁的话它们会
  # 同时往同一个母本目录 tar，解出交错/截断的文件（agent 读到半个文件比读不到更糟）。
  # mkdir 是原子的：抢到的铺母本，没抢到的等它铺完再复用。
  until mkdir "$lock" 2>/dev/null; do
    [ -d "$CODEV_MASTER" ] && return 0      # 别人铺好了，直接用
    # 【陈旧锁回收】持锁进程可能已被杀（前台超时/Ctrl-C），锁却留着。不回收的话本会话
    # 后续每个 agent 都要白等满 300s 再退回 text 模式（等于副本功能静默失效）。
    # 判活【先看 PID 再看 mtime】：只凭 mtime 会偷走活锁——铺母本在慢盘/接近闸门的大仓上
    # 可能真的超过阈值，此时持锁者还在写，回收方却删掉它的锁和 .partial，两个进程同时往
    # 同一个 .partial 解 tar → 母本交错/截断（波及全部 agent）。`kill -0` 判进程是否还在。
    # 注意 -mmin +2 因 find 按整分钟截断，实际语义是【≥3 分钟】，仅作为 PID 丢失时的兜底。
    if [ -n "$(find "$lock" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then
      holder=$(cat "$lock/pid" 2>/dev/null)
      # 持锁者还活着就不回收，继续等——宁可等满 300s 退回 text，也不能让两个 builder 并存。
      if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
        :
      else
        # 【单一赢家】：N 个等待者会同时判定这把锁陈旧。原来各自 `rm -rf $lock; mkdir $lock`，
        # 结果 A 刚 mkdir 出来的新锁被 B 的 rm -rf 删掉、B 再 mkdir 成功，两个 builder 并存往同一个
        # .partial 里 tar（实测 15 个等待者里 5-8 个同时进 tar，母本只剩 5/100 个文件却 rc=0 发布）。
        # 光把 rm 换成 mv 也不够：判陈旧和动手之间有窗口，路径上可能已经换成别人刚 mkdir 的新锁
        # （实测 8 个等待者里 2-3 个的新锁被这样偷走，pid 文件写不进去、rc=1）。
        # 所以回收本身也要排他：先抢 .reclaim 子锁，只有拿到的那一个能动 $lock；拿到后【再核实一遍】
        # 陈旧（持锁者死了就没人能放它、又只有我能回收，核实通过后到 rm -rf 之间路径不可能被换掉），
        # 然后 rm 掉旧锁、放掉子锁、照常去抢 $lock——抢不到（有人比我快）也无妨，谁 mkdir 成功谁是唯一 builder。
        # 旧持锁者的 .partial 这里不碰：每个 builder 用带自己 pid 的 .partial.<pid>，死掉的由赢家按 pid 判活清掉。
        if mkdir "$lock.reclaim" 2>/dev/null; then
          # 子锁也记 owner，让下面的陈旧判定能 kill -0。写不进去就放弃这次回收：没 owner 的子锁 3 分钟后
          # 会被别人当陈旧删掉再回收，而我若恰好停顿到那之后才动手，删的就是别人的新锁。
          sh -c 'echo $PPID' > "$lock.reclaim/pid" 2>/dev/null; rp=$(cat "$lock.reclaim/pid" 2>/dev/null)
          holder=$(cat "$lock/pid" 2>/dev/null)
          if [ -n "$rp" ] && [ -n "$(find "$lock" -maxdepth 0 -mmin +2 2>/dev/null)" ] \
             && { [ -z "$holder" ] || ! kill -0 "$holder" 2>/dev/null; } \
             && [ "$(cat "$lock.reclaim/pid" 2>/dev/null)" = "$rp" ]; then rm -rf "$lock"; fi   # 动手前再确认子锁还是我的
          rm -rf "$lock.reclaim" 2>/dev/null
        elif [ -n "$(find "$lock.reclaim" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then
          # 回收者自己死在半路（极窄窗口）：子锁也会陈旧。同样先 kill -0 判活，活着的不碰。
          holder=$(cat "$lock.reclaim/pid" 2>/dev/null)
          if [ -z "$holder" ] || ! kill -0 "$holder" 2>/dev/null; then rm -rf "$lock.reclaim"; fi
        fi
        # 【不能 continue】：回收失败时（如会话目录不可写）锁还在，continue 会跳过下面的
        # sleep 与 waited++ → 变成无 sleep 的忙等，把一个核吃满且永不退出（实测 timeout 124、
        # spins 上万）。故这里【不跳过】计时与休眠，让它照常走满 300s 再退回 text 模式。
        mkdir "$lock" 2>/dev/null && break     # 回收成功就立刻抢到锁，进入铺母本
      fi
    fi
    waited=$((waited+1))
    [ "$waited" -gt 300 ] && return 1       # 等超过 ~300s 判失败（母本再大也该好了），退回 text 模式
    sleep 1
  done
  # 记下持锁者 pid，供上面的 kill -0 判活，也供放锁时确认是自己的锁。【不能用 $$】：fan-out 的 N 个
  # agent 若是同一个 shell 里 `( … ) &` 出来的子 shell，$$ 在 bash/zsh 下都是父 shell 的 pid——
  # 父 shell 一退出所有锁就"死"了，或者反过来 N 个 builder 共用同一个 .partial.<pid>。
  # `sh -c 'echo $PPID'` 作为直接子进程跑，PPID 就是当前这个（子）shell 自己的 pid，bash/zsh 一致。
  # 拿到锁后先看母本是不是已经有了：等待者在 until 里的 mkdir 恰在赢家放锁的瞬间成功，就会带着"已铺好"的
  # 母本再进一次临界区（自己 tar 一份再在 -e 处丢掉——不出错但白干一遍，builders 计数也会多一行）。
  if [ -d "$CODEV_MASTER" ]; then rm -rf "$lock" 2>/dev/null; return 0; fi
  sh -c 'echo $PPID' > "$lock/pid" 2>/dev/null
  me=$(cat "$lock/pid" 2>/dev/null)
  if [ -z "$me" ]; then
    # 写不进 pid 就【放弃】：带着空 pid 的锁 3 分钟后会被等待者按"持锁者已死"回收，两个 builder 并存。
    # 原来退回 me=$$ 继续构建正是这个窗口。放掉锁、退回 text 模式，比赌会话目录马上恢复可写更稳。
    rm -rf "$lock" 2>/dev/null
    echo "⚠️ 母本锁 pid 写入失败（$lock 不可写？），放弃铺母本，退回 text 模式" >&2
    return 1
  fi
  # 拿到锁了。下面用子 shell 包住全部工作，出口统一放锁——
  # 【不能】在中途直接 return：那样锁不会被删，同会话后续 agent 全卡死在上面的 until。
  # .partial 带持锁者 pid：builder 之间绝不共用同一个半成品目录，回收陈旧锁的人也不需要碰别人的。
  local rc=0 part="$CODEV_MASTER.partial.$me"
  (
    root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 1
    [ -n "$root" ] || exit 1
    # 清掉【死掉的】builder 留下的 .partial.<pid>（被杀的前台超时/Ctrl-C）；活着的（pid 还在）不碰。
    while IFS= read -r -d '' d; do
      p=${d##*.partial.}
      case "$p" in *[!0-9]*|'') ;; *) kill -0 "$p" 2>/dev/null || rm -rf "$d";; esac
    done < <(find "$CODEV_DIR" -maxdepth 1 -type d -name "$(basename "$CODEV_MASTER").partial.*" -print0 2>/dev/null)
    # 体积闸门：只统计将被拷的文件（已被 .gitignore 排除的 node_modules/build 产物天然不计入）。
    # 空输入用 `|| true` 吞退出码（macOS 的 BSD xargs 其实接受 -r 且空输入本就不执行，见 codev_master_path 注释；
    # 这里不依赖 -r 只是为了少一个假设）；du 可能被 xargs 分批多次调用，awk 累加即可。
    # ⚠️ cd 必须在【整条管道之外】（即命令替换的子 shell 里）：若写成 `{ cd "$root" && git ls-files; } | xargs du`，
    # cd 只作用于管道左段的子 shell，右段的 du 仍在原 cwd 解析相对路径 → 全部 No such file → 恒得 0，闸门形同虚设。
    sz=$( cd "$root" 2>/dev/null && { git ls-files -z; git ls-files --others --exclude-standard -z; } \
          | { xargs -0 du -sk -- 2>/dev/null || true; } | awk '{s+=$1} END{print s+0}' )
    # 注：本机 xargs 空输入不执行命令（实测），故空仓库不会让 du 误measure整个 cwd；
    # 但【别指望 `|| true` 挡这个】——它只吞退出码，不阻止命令被空跑。若移植到会空跑的
    # xargs 版本上，需改成先判文件列表是否为空。
    [ "${sz:-0}" -gt "$CODEV_MAX_COPY_KB" ] 2>/dev/null && exit 1
    echo "$me" >> "$CODEV_MASTER.builders" 2>/dev/null   # 进入临界区的 builder 记一行：测试据此断言"单一赢家"
    # 先解到 .partial 再原子改名：万一进程在解压中途被杀，留下的是 .partial，
    # 下次不会被 `[ -d "$CODEV_MASTER" ]` 误判成"已铺好"而让 agent 读到半个仓库。
    rm -rf "$part"
    mkdir -p "$part" || exit 1
    # tar 按 cwd 相对路径打包，故必须先 cd 进仓库根；--null -T - 读 NUL 分隔文件名（含空格/换行也安全）。
    # 密钥载体的过滤【在下面的 while 循环里按文件名（basename）做】，不用 tar 的 --exclude：
    # 副本会被外部模型读取，凡进副本的内容都视同已发送出去；但 --exclude 是按【路径分量】匹配的，
    # `*.env` 会把名叫 dark.env/ 的【目录】整棵子树静默吃掉（实测 src/themes/dark.env/colors.txt 一个不剩，
    # find 兜底也救不回 tar 根本没写出来的东西）。按 basename 用 case 匹配就只挡文件、不挡目录，
    # 且 bash/zsh 行为一致。（不用 grep：本机 grep 可能是 ugrep，其 -z 是"解压"而非 NUL 分隔。）
    # ⚠️ --no-recursion 是【必须的】：git ls-files 对 submodule 只输出一个 mode 160000 的
    # 目录路径（如 `sub`），tar 收到目录默认会【递归整个已初始化 submodule】——连 submodule
    # 自己的 untracked / 被它 .gitignore 忽略的文件一起打包（实测 sub/untracked_secret.txt
    # 进了包）。那既违反"tracked + 未忽略 untracked"的内容约定，也可能把私密数据发给外部模型。
    # 加了它，目录项只建空目录、不下钻；普通文件因 ls-files 已逐个列出，不受影响（实测）。
    # ⚠️ 必须把列表过滤成【当前真实存在的路径】再喂给 tar：`git ls-files` 列的是索引内容，
    # 已删未提交的 tracked 文件（`git rm` 前的 ` D` 状态，review 场景最常见的改动之一）仍在列表里，
    # tar 对它报 "Cannot stat" 并【整体退出非零】。配合上面的 pipefail，母本构建就此判失败 →
    # 每个沙盒 agent 静默退回 text 模式、`./repo` 功能全废（实测：删一个 tracked 文件即触发，
    # codev_repo_master rc=1、母本不存在）。bsdtar 不支持 --ignore-failed-read（实测 "not supported"），
    # 故只能在管道里先筛。-e 对 broken symlink 为假，补 -L 保住它（symlink 稍后统一 -delete）。
    ( set -o pipefail 2>/dev/null   # 让左段 git/tar 的失败也能传出去，不被右段 tar -xf 的 0 掩盖
      cd "$root" && { git ls-files -z; git ls-files --others --exclude-standard -z; } \
        | { while IFS= read -r -d '' f; do
              { [ -e "$f" ] || [ -L "$f" ]; } || continue
              case "$f" in .git|.git/*|*/.git|*/.git/*) continue;; esac
              # 目录项（只可能是 submodule 挂载点，ls-files 对普通目录不输出）直通：过滤只挡【文件】，
              # 名叫 vendor.env 的 submodule 不该因为名字被整棵挡掉；--no-recursion 只建空目录、不下钻。
              [ -d "$f" ] && [ ! -L "$f" ] && { printf '%s\0' "$f"; continue; }
              # 只收普通文件与 symlink（symlink 稍后统一删）：FIFO/socket/设备文件进了副本，agent 一 cat 就阻塞到超时。
              { [ -f "$f" ] || [ -L "$f" ]; } || continue
              # 这份清单必须与下面 find -iname 那轮【一一对应】（那轮补大小写变体）。改一边就同步另一边。
              case "${f##*/}" in
                .env|*.env|.env.*|.envrc|*.pem|*.key|*.p12|*.pfx|id_rsa*|id_dsa*|id_ecdsa*|id_ed25519*|\
                *.keystore|*.jks|.netrc|.npmrc|*.tfvars|*.tfstate|*.tfstate.*) continue;;
              esac
              printf '%s\0' "$f"
            done; } \
        | tar -cf - --null -T - --no-recursion \
        | ( cd "$part" && tar -xf - ) ) 2>/dev/null \
      || { rm -rf "$part"; exit 1; }
    # 【P1 修复：symlink 穿透】tar 原样保留 tracked symlink。若仓库含指向仓库外的绝对路径
    # 链接，agent 经 ./repo/link 就能读到沙盒外的真实文件；更糟的是【能写穿】——实测
    # `chmod -R a-w` 之后 `echo X > repo/link` 仍成功改掉了真实目标（chmod 只改 symlink
    # 自身权限位，不保护目标）。那会击穿"写入只落在副本上"这条主防线，故一律删掉链接。
    find "$part" -type l -delete 2>/dev/null
    # 大小写盲区：上面 case 的 glob 大小写敏感（UPPER.KEY / .ENV 不被排除），
    # 故再用 -iname 做一轮大小写不敏感清扫兜底。
    # ⚠️ 必须加 -type f：不加会匹配到目录，`-delete` 虽拒删非空目录，但空目录/单文件目录仍会
    # 连带整棵子树消失。
    # 【这一轮必须覆盖上面 case 清单的【全部】文件名模式】，否则该项的大小写变体就成了裸奔——
    # case 那边大小写敏感，这里是唯一的兜底。改动任一边都要同步另一边（`*.key`/`*.env`/`*.jks`/
    # `id_*` 曾在一次修 credentials 的提交里被漏掉，导致 SERVER.KEY / PROD.ENV / ID_RSA 直接进副本）。
    # credentials* 不在这一轮里，它有自己的一轮（见下），因为需要额外的源码扩展名白名单。
    find "$part" -type f \( -iname '.env' -o -iname '*.env' -o -iname '.env.*' \
         -o -iname '.envrc' -o -iname '*.pem' -o -iname '*.key' -o -iname '*.p12' \
         -o -iname '*.pfx' -o -iname '*.keystore' -o -iname '*.jks' -o -iname '.netrc' \
         -o -iname '.npmrc' -o -iname 'id_rsa*' -o -iname 'id_dsa*' \
         -o -iname 'id_ecdsa*' -o -iname 'id_ed25519*' \
         -o -iname '*.tfvars' -o -iname '*.tfstate' -o -iname '*.tfstate.*' \) -delete 2>/dev/null
    # credentials 单独一轮：宽通配能挡住 gcp-credentials.json / aws_credentials /
    # credentials.yml.enc 这类前缀后缀变体，但会连 credentials.go / CredentialsProvider.kt 这类
    # 【合法源码】一起删。原来用"源码扩展名白名单"摘出来，可白名单永远列不全——.proto/.scala/.ex/
    # .sql/.tf/.xaml/.gradle 全被删了（实测 9/9）。改成【只删数据格式与无扩展名的】：凭证真正的
    # 载体就是 json/yml/ini/toml/properties/enc/pem/txt/csv/xml 这些和光秃秃的 credentials；
    # 其它任何扩展名一律视为源码留下。`! -name '*.*'` = 无扩展名。
    # 只在这里挡、不进上面的 case 清单：那边按文件名会连 credentials.proto 一起挡；这里 -type f 也不碰目录。
    find "$part" -type f -iname '*credentials*' \
         \( ! -name '*.*' -o -iname '*.json' -o -iname '*.yml' -o -iname '*.yaml' -o -iname '*.ini' \
            -o -iname '*.cfg' -o -iname '*.conf' -o -iname '*.toml' -o -iname '*.properties' \
            -o -iname '*.enc' -o -iname '*.gpg' -o -iname '*.asc' -o -iname '*.txt' -o -iname '*.csv' \
            -o -iname '*.xml' -o -iname '*.plist' -o -iname '*.env' -o -iname '*.pem' -o -iname '*.p12' \) \
         -delete 2>/dev/null
    # mv 前守卫：目标已存在时 `mv dir existingdir` 会把源【移进】目标里（实测 rc=0，
    # 得到 M/codev-master-repo.partial），`||` 分支根本不触发 → 母本里留个嵌套垃圾目录。
    [ -e "$CODEV_MASTER" ] && { rm -rf "$part"; exit 0; }   # 别人已铺好，复用
    # mv 失败但母本已在：别人先发布并已 chmod a-w，我的 mv 被 EACCES 挡住——那是好事，复用即可，别退回 text。
    # 快照一致性：签名是进临界区前算的，tar 期间工作区若被改，母本就是新旧混合的树、却挂着旧签名。
    # 构建完再算一次，不一致就丢掉这份（exit 2 让外层重试一次），一致才发布。子 shell 里重算只改子 shell 的 CODEV_MASTER。
    # 复算失败（哈希都没输出）也按"变了"处理：函数在赋值前就 return 1，CODEV_MASTER 保持旧值会被误判成"没变"而放行。
    codev_master_path 2>/dev/null || { rm -rf "$part"; exit 2; }
    if [ "$CODEV_MASTER" != "${part%.partial.*}" ]; then rm -rf "$part"; exit 2; fi
    mv "$part" "$CODEV_MASTER" || { rm -rf "$part"; [ -d "$CODEV_MASTER" ] && exit 0; exit 1; }
    # 双 builder 极窄窗口（上一行 -e 与 mv 之间别人先发布、且还没来得及 chmod）：mv 会把我的 .partial 移【进】它里面。
    # 母本已是 a-w，先给顶层 u+w 才能删掉嵌进去的那份。
    if [ -d "$CODEV_MASTER/${part##*/}" ]; then
      chmod u+w "$CODEV_MASTER" 2>/dev/null; chmod -R u+w "$CODEV_MASTER/${part##*/}" 2>/dev/null
      rm -rf "$CODEV_MASTER/${part##*/}"
    fi
    # 母本自己也 a-w：沙盒 agent 是同用户进程，枚举 $TMPDIR 就能找到母本；不锁的话一个带 Bash 的 agent
    # 能改写母本，后启动的 agent 从被改母本 clone 出副本、评审建立在被篡改的代码上。
    # 会话收尾 rm -rf 前要先 chmod -R u+w（agents.md 收尾清理段与 codev_sbox_gc 都已这么做）。
    chmod -R a-w "$CODEV_MASTER" 2>/dev/null
    # chmod 失败（ACL/只读挂载/部分 I/O 错）不能静默：还有可写文件就当铺失败，删掉退回 text，别让 ▶ 行谎称只读。
    # 文件和目录都查：目录可写 = agent 能在母本里建/删文件，后启动的 agent 会 clone 到被改的树。
    # 注意此时母本已 mv 到位，until 里的等待者可能在下面 rm 之前看到它并开始 clone——它们 clone 出的副本
    # 会在 codev_repo_copy 自己的校验里再被拦一次，所以不会有 agent 拿到可写副本，只是白干一次。
    # 除了看 mode 位，再做一次【有效权限】探针：ACL/特殊文件系统可能在 u+w 清掉后仍允许写。能在母本根建目录就是没锁住。
    # 探针：mkdir 成功就是不安全，rmdir 成败不参与判定（原来写 mkdir && rmdir，rmdir 失败反而判成安全、还留下探针目录）。
    probe=; if mkdir "$CODEV_MASTER/.codev-probe" 2>/dev/null; then probe=1; rmdir "$CODEV_MASTER/.codev-probe" 2>/dev/null; fi
    if [ -n "$probe" ] || [ -n "$(find "$CODEV_MASTER" \( -type f -o -type d \) -perm -u+w 2>/dev/null | head -1)" ]; then
      echo "⚠️ 母本 chmod -R a-w 未完全生效，放弃副本模式" >&2
      chmod -R u+w "$CODEV_MASTER" 2>/dev/null; rm -rf "$CODEV_MASTER"; exit 1
    fi
  ); rc=$?
  # exit 2 = 构建期间工作区变了：放锁后重试一次（新签名 → 新母本路径）；再变就退回 text。
  if [ "$rc" = 2 ]; then
    holder=$(cat "$lock/pid" 2>/dev/null); [ -n "$lock" ] && [ "$holder" = "$me" ] && rm -rf "$lock" 2>/dev/null
    if [ -z "${CODEV_MASTER_RETRIED:-}" ]; then CODEV_MASTER_RETRIED=1; codev_repo_master; rc=$?; unset CODEV_MASTER_RETRIED; return $rc; fi
    echo "⚠️ 铺母本期间工作区持续变化，退回 text 模式" >&2; return 1
  fi
  # 放锁：无论上面成败都执行。用 rm -rf 而不是 rmdir——锁目录里有 pid 文件（非空），
  # rmdir 会静默失败（实测：锁泄漏 → 同会话后续每个 agent 白等 300s 再退回 text 模式，
  # 副本功能静默失效）。空值守卫防 CODEV_MASTER 意外为空时 rm -rf 打到 ".lock" 之外的东西。
  # 【只放自己的锁】：pid 文件写着别人 → 那是别人在陈旧回收后新拿的锁，删了它就又是两个 builder 并存。
  # pid 为空也不放：自己的锁 pid 写失败时上面已经放掉并返回，走到这里 pid 一定写成功过；
  # 现在为空只可能是别人刚 mkdir 还没来得及写——那是别人的锁。
  holder=$(cat "$lock/pid" 2>/dev/null)
  if [ -n "$lock" ] && [ "$holder" = "$me" ]; then rm -rf "$lock" 2>/dev/null; fi
  return $rc
}

codev_repo_copy() {
  local sbox="$1" probe
  codev_repo_master || return 1              # 母本（每个工作区签名只 tar 一次，已 chmod -R a-w）
  # secret 扫描钉住的母本（SKILL 2B 第 3 步写 codev-scanned-master）：扫描与 fan-out 之间工作区被改，签名就变、
  # 母本就是另一份没扫过的树——拒发，退回 text 并告警，别把没扫过的内容发出去。没有钉子（未扫或 text 模式）就不拦。
  if [ -s "$CODEV_DIR/codev-scanned-master" ] && [ "$(cat "$CODEV_DIR/codev-scanned-master")" != "$CODEV_MASTER" ]; then
    echo "⚠️ 工作区在 secret 扫描之后又变了（母本 $(basename "$CODEV_MASTER") ≠ 已扫描的 $(basename "$(cat "$CODEV_DIR/codev-scanned-master")")），拒绝铺副本；重扫后再发" >&2
    return 1
  fi
  # 从母本给这个 agent 拷一份【独立】副本：`cp -c` 在 APFS 上走 clonefile（写时复制）——
  # 秒级完成、几乎不占额外磁盘，但各 agent 之间【互不影响】（实测改 clone1 不影响母本和 clone2）。
  # 非 APFS / 不支持 -c 的平台自动退回普通 cp -R（-c 失败时重试一次）。
  # 为什么不用硬链接共享一份：硬链接是【同一个 inode】，任一 agent 若绕过 chmod 改了文件，
  # 会串到所有 agent 和母本；clone 是写时复制，改动只落在自己那份。
  # ⚠️ 回退前【必须】清掉残缺目标：`cp -c` 若在建好 $sbox/repo 之后才失败（ENOSPC、跨卷、
  # 个别 inode 不支持 clonefile），紧接着的 `cp -R src dst`【dst 已存在】语义变成"拷进 dst 内部"
  # → $sbox/repo/codev-master-repo/…，且 rc=0（实测）。agent 看到的 ./repo 布局全错、
  # 提示词里承诺的路径全部失效，而 ▶ 行仍显示"只读仓库副本"，故障完全静默。
  # ⚠️ 母本是 a-w 的，cp/clone 会原样带过来权限位；残缺目标 rm -rf 之前必须先 chmod -R u+w，
  # 否则 rm 在只读子树上失败、残缺目录还在，下一步 cp -R 就又变成"拷进内部"（实测 rm 报 Permission denied）。
  cp -c -R "$CODEV_MASTER" "$sbox/repo" 2>/dev/null \
    || { chmod -R u+w "$sbox/repo" 2>/dev/null; rm -rf "$sbox/repo"; cp -R "$CODEV_MASTER" "$sbox/repo" 2>/dev/null; } \
    || { chmod -R u+w "$sbox/repo" 2>/dev/null; rm -rf "$sbox/repo"; return 1; }   # 失败也自清理：否则 text 模式下会残留半个 repo
  chmod -R a-w "$sbox/repo" 2>/dev/null   # 纵深防御：误写立即报错，而不是静默改副本
  probe=; if mkdir "$sbox/repo/.codev-probe" 2>/dev/null; then probe=1; rmdir "$sbox/repo/.codev-probe" 2>/dev/null; fi   # mkdir 成功即不安全
  if [ -n "$probe" ] || [ -n "$(find "$sbox/repo" \( -type f -o -type d \) -perm -u+w 2>/dev/null | head -1)" ]; then   # mode 位 + 有效权限探针
    chmod -R u+w "$sbox/repo" 2>/dev/null; rm -rf "$sbox/repo"; return 1
  fi
  return 0
}

# codev_prepare_call <agent> — 清理本轮输出与计量；在提前跳过路径之前执行，不改变调用者 umask。
codev_prepare_call() {
  local agent="$1" out="$CODEV_DIR/codev-out-$1.txt" err="$CODEV_DIR/codev-err-$1.txt"
  case "$agent" in ''|*[!A-Za-z0-9_-]*) echo "⚠️ 无效 agent 标签" >&2; return 1;; esac
  (
    umask 077
    : > "$out" && : > "$err" && chmod 600 "$out" "$err" &&
    rm -f "$CODEV_DIR/codev-metrics-$agent.json" "$out.unwrap"
  ) || { echo "⚠️ 无法准备 $agent 的输出/计量文件，未启动调用" >&2; return 1; }
}

# codev_bg_sandboxed <agent> <cmd...> — 非原生只读 agent
# （reasonix / qoderclicn / opencode / codebuddy）：在【隔离沙盒】里跑，cwd 够不到真实仓库
# → 从根本上免掉快照/污染问题。默认沙盒里带一份只读仓库副本（见 codev_repo_copy），
# 设 CODEV_SANDBOX_MODE=text 可退回旧的"空目录只喂文本"。
# 输出走会话目录字面路径 $CODEV_DIR/codev-out-<agent>.txt。
# 用法：codev_bg_sandboxed reasonix reasonix run "$(cat "$PROMPT")" --effort high -p
#       （首个参数是 agent 标签，其后是要执行的完整命令 argv；"$(cat)" 由调用方先展开成单个 arg。）
codev_bg_sandboxed() {
  local agent="$1"; shift
  local out="$CODEV_DIR/codev-out-$agent.txt" err="$CODEV_DIR/codev-err-$agent.txt"
  # 【任何提前返回之前就清空】：Claude 按字面路径读 $out，若本轮没跑成而文件还留着上一轮的
  # 评审正文，那份陈旧内容会被当成本轮结论逐字呈现（最坏情况：上一轮说 FAIL 的问题已修好，
  # 这轮却又拿旧文本判一次 FAIL）。所以清空必须在 timeout 缺失、mktemp 失败等所有出口之前。
  codev_prepare_call "$agent" || return 1
  if [ -z "$CODEV_TO" ]; then     # 无 timeout：后台裸跑会永久挂起 → 跳过，不阻塞其它
    echo "⏭ $agent 跳过（无 timeout，后台无兜底）→ 改前台串行或先 brew install coreutils"
    return 0
  fi
  local sbox rc mode
  sbox=$(mktemp -d -t codev-sbox.XXXXXX) || { echo "⚠️ $agent mktemp 失败"; return 1; }
  # owner 标记：codev_sbox_gc 删 60 分钟以上的沙盒前先 kill -0 这个 pid，活着的沙盒不删。
  # 光靠 mtime 不够——母本等待/构建阶段没有 timeout 管，加上 CODEV_TIMEOUT 最大 3000s，是能拖过 60 分钟的。
  if ! sh -c 'echo $PPID' > "$sbox/.codev-owner" 2>/dev/null; then
    # 标记写不进去 = 沙盒目录不可写，agent 也没法在里面干活；且没标记的活沙盒超 60 分钟会被 GC 当残留删掉。
    echo "⚠️ $agent 沙盒不可写（owner 标记写入失败），跳过"; rm -rf "$sbox" 2>/dev/null; return 1
  fi
  if [ "$CODEV_SANDBOX_MODE" = repo ] && codev_repo_copy "$sbox"; then
    # 副本可能【建成了但里面没东西】：空仓库、或全部文件都命中密钥过滤（实测两种都 rc=0、0 文件）。
    # 此时提示词还在承诺"可以读 ./repo 核实"，agent 找不到任何代码 → 又回到"瞎子"状态，
    # 而 ▶ 行却显示副本就绪，用户无从察觉。故实测文件数，为 0 就如实标出。
    if [ "$(find "$sbox/repo" -type f 2>/dev/null | head -1)" ]; then
      mode="隔离沙盒 + 只读仓库副本 ./repo"
    else
      mode="隔离沙盒 + ./repo（⚠️ 副本内 0 个文件：空仓库或全被密钥过滤挡下，agent 无代码视野）"
    fi
  else
    # 兜底清残留：copy 失败路径已自清理，这里再保一手——否则 agent 被告知"空目录"，
    # cwd 里却躺着半个 repo，它若发现了就会基于残缺代码评审（比看不到更糟）。
    chmod -R u+w "$sbox/repo" 2>/dev/null; rm -rf "$sbox/repo" 2>/dev/null   # 残留可能是 a-w 的
    mode="隔离空目录（只喂提示词文本）"
  fi
  # 用 printf 传 $mode：变量展开【紧邻全角字符】时 bash 在 UTF-8 locale 下会误扫、吞掉后半行
  # （实测 echo "…（$mode）" 只输出到"启动（"就截断）。同 codev_report 里 $rc 的处理。
  printf '▶ %s 启动: %s\n' "$agent" "$mode"
  # umask 077 放进子 shell：输出含 diff/可能密钥仅本人可读，且【不把 umask 泄漏给调用方 shell】。
  CODEV_T0=$(date +%s)
  ( umask 077; cd "$sbox" && codev_run "$@" < /dev/null > "$out" 2>"$err" ); rc=$?
  # 副本被 chmod a-w，rm 需要先恢复目录写权限；空值守卫防 mktemp 失败时 rm -rf ""
  [ -n "$sbox" ] && { chmod -R u+w "$sbox" 2>/dev/null; rm -rf "$sbox"; }
  codev_report "$agent" "$rc" "$err" # 捕【agent】退出码，不是 rm 的
}

# codev_bg_native <agent> <cmd...> — 原生只读 agent（codex `-s read-only` / gemini `--approval-mode plan`）：
# 无需沙盒（沙盒级只读保证），在【当前 cwd（应为仓库根）】跑。输出同样走字面路径。
# 用法：codev_bg_native codex codex review "$(cat "$PROMPT")" -c 'model_reasoning_effort="medium"'
codev_bg_native() {
  local agent="$1"; shift
  local out="$CODEV_DIR/codev-out-$agent.txt" err="$CODEV_DIR/codev-err-$agent.txt"
  codev_prepare_call "$agent" || return 1
  echo "▶ $agent 启动（原生只读，真实仓库 cwd）"
  if [ -z "$CODEV_TO" ]; then
    echo "⏭ $agent 跳过（无 timeout，后台无兜底）→ 改前台串行或先 brew install coreutils"
    return 0
  fi
  local rc
  # umask 077 放进子 shell：不把 umask 泄漏给调用方 shell（前台/内联退化场景会残留 0600）。
  CODEV_T0=$(date +%s)
  ( umask 077; codev_run "$@" < /dev/null > "$out" 2>"$err" ); rc=$?
  codev_report "$agent" "$rc" "$err"
}

# codev_sbox_gc — 清理【残留沙盒】。正常路径下 codev_bg_sandboxed 收尾会删掉自己的沙盒，但
# 进程被杀时（前台工具超时、Ctrl-C、机器重启）收尾跑不到，沙盒就漏在 TMPDIR 里。
# 空目录时代漏了无所谓，现在沙盒里有整份仓库副本 → 会堆磁盘、也留代码残迹，所以要定期扫。
# 判死三步：先看 .codev-owner 里的 pid 是否还活着（活着不删——但超 7 天不看 pid 一律删，pid 会被复用），再看 mtime 是否超 60 分钟（老版本沙盒没有
# owner 标记时的兜底启发；CODEV_TIMEOUT ≤ 3000s 让它"多半已死"，但母本等待/构建阶段没有 timeout 管，所以不是证明）。
codev_sbox_gc() {
  local t="${TMPDIR:-/tmp}" d n=0 o
  # -mmin 是 BSD/GNU find 都有的；-maxdepth 1 防递归进副本内部。副本被 chmod a-w，rm 前先恢复写权限。
  # 只扫【沙盒】：沙盒天生短命（单次 agent 调用），60 分钟 + owner pid 已死才删。
  # ⚠️ 【不要】把会话目录 codev.* 也按 60 分钟扫：会话目录是长命的（用户看完输出、讨论、再跑一轮
  #    很容易超过 1 小时），且并发的另一个 /codev run 的会话目录同样匹配 —— 那样会删掉别人正在用的
  #    母本/提示词/输出。会话目录由 skill 收尾的 `chmod -R u+w "$CODEV_DIR"; rm -rf "$CODEV_DIR"` 负责
  #    （母本就在里面且是 a-w 的，先恢复写权限再删）；
  #    进程被杀漏下的由下面 24 小时那轮兜底。
  # 用 -print0 + read -d '' 而不是 `for d in $(find …)`：后者依赖词拆分，$TMPDIR 含空格/换行时
  # 会把一个路径拆成多个删除目标（如 `/tmp/work dir/codev-sbox.x` → 试图删 `/tmp/work`）。
  # （注：命令替换在 bash 和 zsh 下【都会】词拆分，这不是 zsh 特有问题——别被"zsh 不拆分"
  #   的说法误导，那条只适用于未加引号的【变量】展开。）
  while IFS= read -r -d '' d; do
    # owner 还活着就不删（7 天内）：60 分钟只是"多半已死"的启发，不是证明（见 codev_bg_sandboxed 写标记处的注释）。
    o=$(cat "$d/.codev-owner" 2>/dev/null)
    # pid 会被复用：owner 早死、pid 落到别的长命进程头上，沙盒就永远"活着"。超过 7 天不管 pid 一律删（CODEV_TIMEOUT 上限 50 分钟）。
    if [ -z "$(find "$d" -maxdepth 0 -mmin +10080 2>/dev/null)" ]; then
      case "$o" in *[!0-9]*|'') ;; *) kill -0 "$o" 2>/dev/null && continue;; esac
    fi
    chmod -R u+w "$d" 2>/dev/null; rm -rf "$d" 2>/dev/null && n=$((n+1))
  done < <(find "$t" -maxdepth 1 -type d -name 'codev-sbox.*' -mmin +60 -print0 2>/dev/null)
  # 会话目录（含母本，可能几十 MB）用 24 小时这档兜底：够长，不会撞上"用户慢慢看输出"或并发 run；
  # 且显式跳过【本次会话】自己的目录。
  # 会话目录没有单一持有者 pid（编排器每次 Bash 调用都是新 shell），用【活动时间】判活：目录里任一文件 24 小时内
  # 被写过（新的 out/err/metrics/提示词）就还在用，不删——目录本身的 mtime 只在增删条目时变，不够。
  while IFS= read -r -d '' d; do
    [ "$d" = "$CODEV_DIR" ] && continue
    [ -n "$(find "$d" -type f -mmin -1440 2>/dev/null | head -1)" ] && continue
    chmod -R u+w "$d" 2>/dev/null; rm -rf "$d" 2>/dev/null && n=$((n+1))
  done < <(find "$t" -maxdepth 1 -type d -name 'codev.*' -mmin +1440 -print0 2>/dev/null)
  [ "$n" -gt 0 ] && echo "已清理 $n 个残留沙盒/会话目录（沙盒超 60 分钟、会话目录超 24 小时）"
  return 0
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
  local c r
  codev_sbox_gc          # 顺手回收上一轮被杀进程漏下的沙盒（含仓库副本，会堆磁盘）
  for c in codex gemini reasonix qoderclicn opencode codebuddy; do
    if command -v "$c" >/dev/null 2>&1; then
      r=$(codev_ledger_recent "$c")
      if [ "$c" = codex ]; then echo "OK   codex ($(codev_auth_codex))${r:+  近期: $r}"; else echo "OK   $c${r:+  近期: $r}"; fi
    else
      echo "MISS $c"
    fi
  done
  r=$(codev_ledger_recent self); echo "OK   self（本 agent 的 fresh-subagent 做 G2 自评，不耗外部额度；G1 自查另以 check 记台账。见 SKILL 通用机制 G）${r:+  近期: $r}"
  echo "timeout -> ${CODEV_TO:-MISSING}（CODEV_TIMEOUT=${CODEV_TIMEOUT}s）"
  [ -s "$CODEV_LEDGER" ] && echo "账本 -> ${CODEV_LEDGER}（近期类别：ok/quota/auth/turns/timeout/empty/error；连续 quota 的 agent 别放进推荐组合）"
  [ -s "$CODEV_FINDINGS" ] && echo "发现台账 -> ${CODEV_FINDINGS}（codev_stats 看每个 agent/模型的 P1 亲验成立率）"
  [ -s "$CODEV_OPINIONS" ] && echo "意见记录 -> ${CODEV_OPINIONS}（codev_opinions [问题ID] 回放某条当时谁怎么说、判断组是否一致）"
  return 0   # 上面三行是可选提示，没有台账文件时它的假值不能变成 probe 的失败状态
}
