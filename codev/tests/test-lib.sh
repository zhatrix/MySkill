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
grep -q "	qoderclicn	[^	]*	quota	" "$CODEV_LEDGER" && ok "qoderclicn quota" || bad "qoderclicn 未记 quota" "$(cat "$CODEV_LEDGER")"
grep -q "	codex	[^	]*	ok	" "$CODEV_LEDGER" && ok "codex ok" || bad "codex 未记 ok"
grep -q "	reasonix	[^	]*	timeout	" "$CODEV_LEDGER" && ok "reasonix timeout" || bad "reasonix 未记 timeout"

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

echo "15. 模型识别：codex 从 stderr banner 取 model；其它 agent 取 CODEV_MODEL_<agent>；都没有则 unknown"
mk codex "body" "OpenAI Codex v0.152.0
--------
model: gpt-5.6-sol
provider: openai"
[ "$(codev_model_of codex)" = "gpt-5.6-sol" ] && ok "codex banner" || bad "codex model=$(codev_model_of codex)"
CODEV_MODEL_reasonix=deepseek-v4; [ "$(codev_model_of reasonix)" = "deepseek-v4" ] && ok "env override" || bad "env override=$(codev_model_of reasonix)"
unset CODEV_MODEL_reasonix; [ "$(codev_model_of gemini)" = "unknown" ] && ok "unknown" || bad "unknown=$(codev_model_of gemini)"

echo "16. 账本行含 会话 与 模型 两列；429 行把重置时间写进 note 列"
: > "$CODEV_LEDGER"
mk codex "body" "model: gpt-5.6-sol"
report codex 0 >/dev/null
mk codebuddy "" "429 您的使用量已超出频率限制，将在 2026-09-04 15:51:10 UTC+8 重置，您也可以切换其他模型继续使用。"
report codebuddy 1 >/dev/null
sess=$(basename "$CODEV_DIR")
grep -q "^[^	]*	$sess	codex	gpt-5.6-sol	ok	" "$CODEV_LEDGER" && ok "session+model 列" || bad "列不对" "$(cat "$CODEV_LEDGER")"
grep -q "	codebuddy	[^	]*	quota	.*重置 2026-09-04 15:51:10" "$CODEV_LEDGER" && ok "重置时间进 note" || bad "缺重置时间" "$(cat "$CODEV_LEDGER")"
r=$(codev_probe 2>&1); case "$r" in *codebuddy*quota*15:51*) ok "probe 显示重置时间";; *) bad "probe 未显示重置时间" "$(printf '%s' "$r" | grep codebuddy)";; esac

echo "17. 成本：reasonix metrics 取 cost+currency；本会话汇总行按 agent 列 用时/tokens/成本"
mk reasonix "OK" ""
cat > "$CODEV_DIR/codev-metrics-reasonix.json" <<'JSON'
{ "prompt_tokens": 100, "completion_tokens": 5, "cost": 0.052425, "currency": "CNY", "x": { "cost": 9.9 } }
JSON
r=$(CODEV_T0=$(( $(date +%s) - 3 )) report reasonix 0)
case "$r" in *"tokens 105"*"0.052 CNY"*) ok "tokens+cost";; *) bad "缺 cost" "$r";; esac
r=$(codev_session_summary)
case "$r" in *reasonix*105*0.052*CNY*) ok "汇总含 reasonix";; *) bad "汇总缺" "$r";; esac
case "$r" in *codex*gpt-5.6-sol*) ok "汇总含模型";; *) bad "汇总缺模型" "$r";; esac
rm -f "$CODEV_DIR/codev-metrics-reasonix.json"

echo "18. 发现台账：codev_finding_add 追加结构化行；codev_stats 按 agent+模型算 P1 精确率与独家命中"
export CODEV_FINDINGS="$CODEV_DIR/findings.tsv"
codev_finding_add ntms spec-a 1 codex gpt-5.6-sol r1-codex-01 P1 A 采纳 成立 独家 "register_payment 漏 tenant_id"
codev_finding_add ntms spec-a 1 codex gpt-5.6-sol r1-codex-02 P1 A 驳回 不成立 独家 "说 advisory 锁不存在"
codev_finding_add ntms spec-a 1 reasonix deepseek-v4 r1-reasonix-01 P2 B 采纳 成立 共同 "seq 唯一约束措辞"
codev_finding_add ntms spec-a 2 codex gpt-5.6-sol r2-codex-01 P1 A 采纳 成立 共同 "含	制表符	的描述"
n=$(wc -l < "$CODEV_FINDINGS" | tr -d ' '); [ "$n" = 4 ] && ok "4 行" || bad "行数 $n" "$(cat "$CODEV_FINDINGS")"
awk -F'\t' 'NF!=13{bad=1} END{exit bad}' "$CODEV_FINDINGS" && ok "每行 13 列（制表符已转义）" || bad "列数不齐" "$(awk -F'\t' '{print NF}' "$CODEV_FINDINGS")"
r=$(codev_stats)
case "$r" in *"codex"*"gpt-5.6-sol"*) ok "stats 含 codex";; *) bad "stats 缺 codex" "$r";; esac
# codex: 声称 P1 3 条(r1-01 成立, r1-02 不成立, r2-01 成立) → 成立 2/3；独家且成立 1
case "$r" in *"2/3"*) ok "P1 精确率 2/3";; *) bad "精确率错" "$r";; esac
case "$r" in *"reasonix"*"0/0"*) ok "reasonix 无 P1 显示 0/0";; *) bad "reasonix 行错" "$r";; esac

echo "19. 回流 commit：只提交 pathspec，trailer 带轮次/评审方/P1 数；无关脏文件不入库；能按 trailer 找回上一轮 commit"
REPO=$(mktemp -d -t codevrepo.XXXXXX); ( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t \
  && mkdir -p docs src && echo v1 > docs/spec.md && echo a > src/a.py && git add -A && git commit -qm init \
  && echo v1.1 > docs/spec.md && echo dirty > src/a.py \
  && codev_commit_round docs/spec.md 1 "codex(gpt-5.6-sol), reasonix(deepseek-v4)" 2 - "spec v1.0→v1.1：回流 2 条 P1" "Co-Authored-By: X <x@y>" >/dev/null \
  && git status --porcelain > /tmp/codev-st.txt && git log -1 --format=%B > /tmp/codev-msg.txt \
  && echo v1.2 > docs/spec.md \
  && codev_commit_round docs/spec.md 2 "codex(gpt-5.6-sol)" 0 2 "spec v1.1→v1.2" >/dev/null \
  && codev_prev_round_commit docs/spec.md 2 > /tmp/codev-prev.txt \
  && git log --format=%H -2 > /tmp/codev-hashes.txt )
grep -q '^ M src/a.py' /tmp/codev-st.txt && ok "无关脏文件未入库" || bad "脏文件被提交" "$(cat /tmp/codev-st.txt)"
grep -q '^Codev-Round: 1$' /tmp/codev-msg.txt && ok "Codev-Round trailer" || bad "缺 Codev-Round" "$(cat /tmp/codev-msg.txt)"
grep -q '^Codev-Reviewed-By: codex(gpt-5.6-sol), reasonix(deepseek-v4)$' /tmp/codev-msg.txt && ok "Reviewed-By" || bad "缺 Reviewed-By" "$(cat /tmp/codev-msg.txt)"
grep -q '^Codev-Verified-P1: 2 (prev -)$' /tmp/codev-msg.txt && ok "Verified-P1" || bad "缺 Verified-P1" "$(cat /tmp/codev-msg.txt)"
grep -q '^Co-Authored-By: X <x@y>$' /tmp/codev-msg.txt && ok "额外 trailer 透传" || bad "缺额外 trailer" "$(cat /tmp/codev-msg.txt)"
[ "$(cat /tmp/codev-prev.txt)" = "$(sed -n 2p /tmp/codev-hashes.txt)" ] && ok "找回第 1 轮 commit" || bad "prev commit 错" "$(cat /tmp/codev-prev.txt) vs $(cat /tmp/codev-hashes.txt)"
rm -rf "$REPO" /tmp/codev-st.txt /tmp/codev-msg.txt /tmp/codev-prev.txt /tmp/codev-hashes.txt

echo "20. 归档：codev_archive 把本会话 prompt/out/err/metrics 复制到 <repo>/.superpowers/codev/<slug>/r<N>/，并保证被 git 忽略"
REPO=$(mktemp -d -t codevrepo.XXXXXX); mk codex "body" "err"; printf 'p' > "$CODEV_DIR/codev-prompt-codex.txt"
( cd "$REPO" && git init -q && codev_archive spec-a 2 >/dev/null && ls .superpowers/codev/spec-a/r2/ > /tmp/codev-ar.txt && git check-ignore -q .superpowers/codev/spec-a/r2/codev-out-codex.txt && echo ignored >> /tmp/codev-ar.txt )
grep -q 'codev-out-codex.txt' /tmp/codev-ar.txt && ok "已归档" || bad "未归档" "$(cat /tmp/codev-ar.txt)"
grep -q '^ignored$' /tmp/codev-ar.txt && ok "被 git 忽略（.git/info/exclude）" || bad "未忽略" "$(cat /tmp/codev-ar.txt)"
rm -rf "$REPO" /tmp/codev-ar.txt

rm -rf "$CODEV_DIR"
echo; echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
