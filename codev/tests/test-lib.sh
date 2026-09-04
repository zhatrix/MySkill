#!/usr/bin/env bash
# codev-lib.sh 的回归测试：用假的 stdout/stderr 夹具驱动 codev_report / codev_classify / 账本，
# 断言"额度耗尽被判成功"等历史事故不再发生。运行：bash tests/test-lib.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
LIB="$HERE/../bin/codev-lib.sh"
export CODEV_DIR=$(mktemp -d -t codevtest.XXXXXX)
export CODEV_LEDGER="$CODEV_DIR/ledger.tsv"      # 测试不碰真账本
export CODEV_TIMEOUT=600
source "$LIB" || { echo "FATAL: source 失败"; exit 1; }
pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ✔ $1"; }
bad()  { fail=$((fail+1)); echo "  ✘ $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /'; }
mk() { printf '%s' "$2" > "$CODEV_DIR/codev-out-$1.txt"; printf '%s' "$3" > "$CODEV_DIR/codev-err-$1.txt"; }
report() { codev_report "$1" "$2" "$CODEV_DIR/codev-err-$1.txt" 2>&1; }

echo "1. qoderclicn 额度耗尽写在 stdout 且 exit 0 → 不得判 ✔，须标额度"
mk qoderclicn "You've reached your credit usage limit. Please upgrade your subscription plan to get more resources. Report Issue (input /feedback)" ""
r=$(report qoderclicn 0)
case "$r" in *"✔"*) bad "判成了 ✔" "$r";; *"⛔"*额度*) ok "标为额度";; *) bad "未标额度" "$r";; esac

echo "2. codex：stderr 1 万行 banner，额度错误在尾部，exit 0、stdout 空 → 须标额度且显示错误行"
{ for i in $(seq 1 10000); do echo "src/file$i.py"; done; echo "ERROR: You've hit your usage limit. Upgrade to Pro or try again at 3:51 PM."; echo "tokens used"; echo "17,241"; } > "$CODEV_DIR/codev-err-codex.txt"; : > "$CODEV_DIR/codev-out-codex.txt"
r=$(report codex 0)
case "$r" in *"⛔"*额度*"usage limit"*) ok "标额度并带原句";; *) bad "未标额度/未带原句" "$(printf '%s' "$r" | head -3)";; esac

echo "3. codebuddy 429 频率限制（含重置时间）exit 1 → 标额度/限流并带重置时间"
mk codebuddy "" "429 您的使用量已超出频率限制，将在 2026-09-04 15:51:10 UTC+8 重置，您也可以切换其他模型继续使用。 (abc/def)"
r=$(report codebuddy 1)
case "$r" in *"⛔"*"15:51:10"*) ok "带重置时间";; *) bad "缺重置时间" "$r";; esac

echo "4. codebuddy Max turns exceeded → 标 turn 预算"
mk codebuddy "" "Max turns (12) exceeded"
r=$(report codebuddy 1)
case "$r" in *turn*) ok "标 turn";; *) bad "未标 turn" "$r";; esac

echo "5. reasonix context canceled、stdout 空 → 标为断流/空输出，不得 ✔"
mk reasonix "" "错误： context canceled"
r=$(report reasonix 1)
case "$r" in *"✔"*) bad "判成 ✔" "$r";; *"context canceled"*) ok "带原句";; *) bad "未带原句" "$r";; esac

echo "6. 超时 124 → ⏭ 且提到 CODEV_TIMEOUT"
mk reasonix "" ""
r=$(report reasonix 124)
case "$r" in *"⏭"*CODEV_TIMEOUT*) ok "超时提示可调";; *) bad "缺 CODEV_TIMEOUT 提示" "$r";; esac

echo "7. 正常输出 exit 0 → ✔"
mk codex "## A. 已查证
- P1 service.py:12 ..." "tokens used
1,234"
r=$(report codex 0)
case "$r" in *"✔"*) ok "✔";; *) bad "正常输出未判 ✔" "$r";; esac

echo "8. exit 0 但 stdout 为空 → 不得 ✔，标空输出"
mk gemini "" ""
r=$(report gemini 0)
case "$r" in *"✔"*) bad "空输出判 ✔" "$r";; *空输出*) ok "标空输出";; *) bad "未标空输出" "$r";; esac

echo "9. 账本：以上每次 report 追加一行，字段=时间 agent 类别 rc"
[ -f "$CODEV_LEDGER" ] || bad "账本文件不存在"
n=$(wc -l < "$CODEV_LEDGER" | tr -d ' ')
[ "$n" = 8 ] && ok "8 行" || bad "行数 $n ≠ 8" "$(cat "$CODEV_LEDGER")"
grep -q "	qoderclicn	quota	" "$CODEV_LEDGER" && ok "qoderclicn quota" || bad "qoderclicn 未记 quota" "$(cat "$CODEV_LEDGER")"
grep -q "	codex	ok	" "$CODEV_LEDGER" && ok "codex ok" || bad "codex 未记 ok"
grep -q "	reasonix	timeout	" "$CODEV_LEDGER" && ok "reasonix timeout" || bad "reasonix 未记 timeout"

echo "10. codev_probe 展示每个 agent 最近结果（近期账本摘要）"
r=$(codev_probe 2>&1)
case "$r" in *qoderclicn*quota*) ok "probe 显示 qoderclicn 近期 quota";; *) bad "probe 未显示账本" "$r";; esac

echo "11. codev_run 用 CODEV_TIMEOUT 而非硬编码 600"
CODEV_TIMEOUT=1 ; r=$(codev_run sleep 3; echo "rc=$?")
case "$r" in *"rc=124"*) ok "1s 超时生效";; *) bad "CODEV_TIMEOUT 未生效" "$r";; esac
CODEV_TIMEOUT=abc; r=$(source "$LIB" 2>&1 >/dev/null; echo "to=$CODEV_TIMEOUT")
case "$r" in *"to=600"*) ok "非法值退回 600";; *) bad "非法值未退回" "$r";; esac

echo "12. codev_elapsed_note：report 行含用时（秒）"
mk codex "ok body" ""
CODEV_T0=$(( $(date +%s) - 42 ))
r=$(CODEV_T0=$CODEV_T0 report codex 0)
case "$r" in *"用时 4"[0-9]"s"*) ok "含用时";; *) bad "缺用时" "$r";; esac

echo "13. reasonix --metrics JSON 同名键重复出现 → tokens 只取首次出现之和"
mk reasonix "OK" ""
cat > "$CODEV_DIR/codev-metrics-reasonix.json" <<'JSON'
{
  "prompt_tokens": 5826,
  "completion_tokens": 22,
  "providers": { "deepseek": { "prompt_tokens": 5848, "completion_tokens": 22 } }
}
JSON
r=$(report reasonix 0)
case "$r" in *"tokens 5848"*) ok "5826+22";; *) bad "tokens 解析错" "$r";; esac
rm -f "$CODEV_DIR/codev-metrics-reasonix.json"

echo "14. codex stdout 有正文但 stderr 尾部有额度错误 → ✔ 但附截断警告"
mk codex "## 结论
- P1 ..." "banner
ERROR: You've hit your usage limit.
tokens used
9,999"
r=$(report codex 0)
case "$r" in *"✔"*截断*"usage limit"*) ok "✔+警告";; *) bad "缺截断警告" "$r";; esac

rm -rf "$CODEV_DIR"
echo; echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
