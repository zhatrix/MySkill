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

# 中间产物一律放 $CODEV_DIR（每次运行独立的临时目录），不要用固定的 /tmp 路径：
# 固定路径会让两次并发运行互相污染，也会让子 shell 失败时的断言读到上一轮的残留文件而误报通过。
T="$CODEV_DIR"

echo "19. 回流 commit：只提交显式列出的文件，trailer 带轮次/评审方/P1 数；无关脏文件不入库；能按 trailer 找回上一轮 commit"
REPO=$(mktemp -d -t codevrepo.XXXXXX); ( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t \
  && mkdir -p docs src && echo v1 > docs/spec.md && echo a > src/a.py && git add -A && git commit -qm init \
  && echo v1.1 > docs/spec.md && echo dirty > src/a.py \
  && codev_commit_round docs/spec.md 1 "codex(gpt-5.6-sol), reasonix(deepseek-v4)" 2 - "spec v1.0→v1.1：回流 2 条 P1" "Co-Authored-By: X <x@y>" >/dev/null \
  && git status --porcelain > "$T/codev-st.txt" && git log -1 --format=%B > "$T/codev-msg.txt" \
  && echo v1.2 > docs/spec.md \
  && codev_commit_round docs/spec.md 2 "codex(gpt-5.6-sol)" 0 2 "spec v1.1→v1.2" >/dev/null \
  && codev_prev_round_commit docs/spec.md 2 > "$T/codev-prev.txt" \
  && git log --format=%H -2 > "$T/codev-hashes.txt" ) && ok "回流 commit 流程整体成功" || bad "回流 commit 子流程失败（下面的断言不可信）"
grep -q '^ M src/a.py' "$T/codev-st.txt" && ok "无关脏文件未入库" || bad "脏文件被提交" "$(cat "$T/codev-st.txt" 2>&1)"
grep -q '^Codev-Round: 1$' "$T/codev-msg.txt" && ok "Codev-Round trailer" || bad "缺 Codev-Round" "$(cat "$T/codev-msg.txt" 2>&1)"
grep -q '^Codev-Reviewed-By: codex(gpt-5.6-sol), reasonix(deepseek-v4)$' "$T/codev-msg.txt" && ok "Reviewed-By" || bad "缺 Reviewed-By" "$(cat "$T/codev-msg.txt" 2>&1)"
grep -q '^Codev-Verified-P1: 2 (prev -)$' "$T/codev-msg.txt" && ok "Verified-P1" || bad "缺 Verified-P1" "$(cat "$T/codev-msg.txt" 2>&1)"
grep -q '^Co-Authored-By: X <x@y>$' "$T/codev-msg.txt" && ok "额外 trailer 透传" || bad "缺额外 trailer" "$(cat "$T/codev-msg.txt" 2>&1)"
[ -s "$T/codev-prev.txt" ] && [ "$(cat "$T/codev-prev.txt")" = "$(sed -n 2p "$T/codev-hashes.txt")" ] && ok "找回第 1 轮 commit" || bad "prev commit 错" "$(cat "$T/codev-prev.txt" 2>&1) vs $(cat "$T/codev-hashes.txt" 2>&1)"
rm -rf "$REPO" "$T/codev-st.txt" "$T/codev-msg.txt" "$T/codev-prev.txt" "$T/codev-hashes.txt"

echo "19b. 回流 commit 拒收目录：给目录会把同目录下用户未提交的无关改动一起卷进来"
REPO=$(mktemp -d -t codevrepo.XXXXXX); ( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t \
  && mkdir -p docs && echo v1 > docs/spec.md && echo w1 > docs/wip.md && git add -A && git commit -qm init \
  && echo v1.1 > docs/spec.md && echo w2 > docs/wip.md \
  && codev_commit_round docs 1 codex 1 - "给目录" > "$T/codev-dir.txt" 2>&1; echo "rc=$?" >> "$T/codev-dir.txt"
  git -C "$REPO" status --porcelain >> "$T/codev-dir.txt" )
grep -q '^rc=1$' "$T/codev-dir.txt" && ok "目录 pathspec 被拒" || bad "目录未被拒" "$(cat "$T/codev-dir.txt" 2>&1)"
grep -q '^ M docs/wip.md' "$T/codev-dir.txt" && ok "无关文件仍未提交" || bad "无关文件被提交" "$(cat "$T/codev-dir.txt" 2>&1)"
rm -rf "$REPO" "$T/codev-dir.txt"

echo "20. 归档：codev_archive 把本会话 prompt/out/err/metrics 复制到 <repo>/.superpowers/codev/<slug>/r<N>/，并保证被 git 忽略"
REPO=$(mktemp -d -t codevrepo.XXXXXX); mk codex "body" "err"; printf 'p' > "$CODEV_DIR/codev-prompt-codex.txt"
( cd "$REPO" && git init -q && codev_archive spec-a 2 > "$T/codev-ar.txt" && ls .superpowers/codev/spec-a/r2/ >> "$T/codev-ar.txt" \
  && git check-ignore -q .superpowers/codev/spec-a/r2/codev-out-codex.txt && echo ignored >> "$T/codev-ar.txt" ) \
  && ok "归档流程整体成功" || bad "归档子流程失败（下面的断言不可信）" "$(cat "$T/codev-ar.txt" 2>&1)"
grep -q 'codev-out-codex.txt' "$T/codev-ar.txt" && ok "已归档" || bad "未归档" "$(cat "$T/codev-ar.txt" 2>&1)"
grep -q '^ignored$' "$T/codev-ar.txt" && ok "被 git 忽略（.git/info/exclude）" || bad "未忽略" "$(cat "$T/codev-ar.txt" 2>&1)"
grep -q '已被 git 忽略' "$T/codev-ar.txt" && ok "归档提示与实际一致" || bad "归档提示不对" "$(cat "$T/codev-ar.txt" 2>&1)"
rm -rf "$REPO" "$T/codev-ar.txt"

echo "20b. 归档在 worktree 里（.git 是文件）：exclude 要写进真正的 gitdir，且提示不许谎称已忽略"
REPO=$(mktemp -d -t codevrepo.XXXXXX); WT=$(mktemp -d -t codevwt.XXXXXX); rm -rf "$WT"
( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t \
  && echo a > a.txt && git add -A && git commit -qm init && git worktree add -q "$WT" -b wt2 >/dev/null 2>&1 )
( cd "$WT" && codev_archive spec-a 3 > "$T/codev-wt.txt" 2>&1; echo "rc=$?" >> "$T/codev-wt.txt"
  git -C "$WT" check-ignore -q .superpowers/codev/spec-a/r3/codev-out-codex.txt && echo ignored >> "$T/codev-wt.txt" )
grep -q '^rc=0$' "$T/codev-wt.txt" && ok "worktree 归档成功" || bad "worktree 归档失败" "$(cat "$T/codev-wt.txt" 2>&1)"
grep -q '^ignored$' "$T/codev-wt.txt" && ok "worktree 里也真的被忽略" || bad "worktree 未忽略" "$(cat "$T/codev-wt.txt" 2>&1)"
grep -q '已被 git 忽略' "$T/codev-wt.txt" && ok "worktree 提示与实际一致" || bad "提示不对" "$(cat "$T/codev-wt.txt" 2>&1)"
git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1; rm -rf "$REPO" "$WT" "$T/codev-wt.txt"

echo "21. 回归：probe 在没有发现台账时返回 0；cost/tokens 遇到 null 值不串到下一个数字；账本兼容旧 7 列"
( CODEV_FINDINGS="$CODEV_DIR/no-such-findings.tsv"; codev_probe >/dev/null 2>&1 ) && ok "probe 无台账时 rc=0" || bad "probe 无台账时 rc≠0"
printf '{"model":"x","cost": null, "currency": null, "prompt_tokens": 4210, "completion_tokens": 7}\n' > "$CODEV_DIR/codev-metrics-nul.json"
c=$(codev_cost nul); [ -z "$c" ] && ok "cost=null 不报假成本" || bad "cost=null 被当成数字" "$c"
t=$(codev_tokens nul); case "$t" in "tokens 4217") ok "tokens 仍按锚定后的键取";; *) bad "tokens 解析错" "$t";; esac
LEG="$CODEV_DIR/legacy-ledger.tsv"
printf '2026-09-01T10:00\tcodex\tquota\t1\t3\t10\t0\n2026-09-01T10:05\tcodex\tok\t0\t9\t10\t20\n' > "$LEG"
r=$(CODEV_LEDGER="$LEG" codev_ledger_recent codex)
case "$r" in *"quota ok"*"最近 09-01T10:05"*) ok "旧 7 列账本仍可读";; *) bad "旧账本行被丢弃" "$r";; esac
codev_finding_add ntms spec-a 1 codex m id P1 A 采纳 成立 独家 未加引号的 描述 2>/dev/null && bad "多余实参未被拒" || ok "finding_add 拒收未加引号的描述"

echo "22. 回流 commit 多文件：首参空格分隔的多个文件在 bash/zsh 下都要拆开（zsh 不对未加引号变量拆词）"
REPO=$(mktemp -d -t codevrepo.XXXXXX); ( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t \
  && mkdir -p docs && echo a > docs/a.md && echo b > docs/b.md && echo c > docs/c.md && git add -A && git commit -qm init \
  && echo a2 > docs/a.md && echo b2 > docs/b.md && echo c2 > docs/c.md \
  && codev_commit_round "docs/a.md docs/b.md" 1 codex 0 - "两个文件" >/dev/null \
  && git show --stat --format= HEAD > "$T/codev-mf.txt" && git status --porcelain >> "$T/codev-mf.txt" ) \
  && ok "多文件 commit 成功" || bad "多文件 commit 失败" "$(cat "$T/codev-mf.txt" 2>&1)"
grep -q 'docs/a.md' "$T/codev-mf.txt" && grep -q 'docs/b.md' "$T/codev-mf.txt" && ok "a.md b.md 都进了 commit" || bad "文件没都进" "$(cat "$T/codev-mf.txt" 2>&1)"
grep -q '^ M docs/c.md' "$T/codev-mf.txt" && ok "没列的 c.md 仍未提交" || bad "c.md 被顺手提交" "$(cat "$T/codev-mf.txt" 2>&1)"
rm -rf "$REPO" "$T/codev-mf.txt"

echo "23. 短 stdout 像评审结论（含 401 / rate limit 字样）→ ok，不得判成 auth/quota；真错误串仍按类别"
mk x "LGTM. No P1. The 401 handling in auth.py is correct." ""
r=$(codev_classify x 0 "$CODEV_DIR/codev-out-x.txt" "$CODEV_DIR/codev-err-x.txt"); [ "$r" = ok ] && ok "LGTM+401 → ok" || bad "LGTM+401 判成 $r"
mk x "PASS — the rate limit retry path is fine" ""
r=$(codev_classify x 0 "$CODEV_DIR/codev-out-x.txt" "$CODEV_DIR/codev-err-x.txt"); [ "$r" = ok ] && ok "PASS+rate limit → ok" || bad "PASS+rate limit 判成 $r"
mk x "Error: 401 Unauthorized. Please login first." ""
r=$(codev_classify x 0 "$CODEV_DIR/codev-out-x.txt" "$CODEV_DIR/codev-err-x.txt"); [ "$r" = auth ] && ok "真鉴权错误串仍 → auth" || bad "真鉴权串判成 $r"
r=$(codev_classify x 137 "$CODEV_DIR/codev-out-x.txt" "$CODEV_DIR/codev-err-x.txt"); [ "$r" = timeout ] && ok "rc=137（-k KILL）→ timeout" || bad "137 判成 $r"

echo "24. 母本签名：同一个已脏文件再改内容 → 签名必须变；未跟踪文件改内容也要变"
REPO=$(mktemp -d -t codevrepo.XXXXXX)
( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t && echo v1 > a.py && git add -A && git commit -qm init \
  && echo v2 > a.py && codev_master_path && printf '%s\n' "$CODEV_MASTER" \
  && echo v3 > a.py && codev_master_path && printf '%s\n' "$CODEV_MASTER" \
  && echo u1 > new.txt && codev_master_path && printf '%s\n' "$CODEV_MASTER" \
  && echo u2 > new.txt && codev_master_path && printf '%s\n' "$CODEV_MASTER" ) > "$T/codev-sig.txt"
n=$(sort -u "$T/codev-sig.txt" | wc -l | tr -d ' '); [ "$n" = 4 ] && ok "4 次改动得到 4 个不同母本路径" || bad "签名没随内容变（去重后 $n 个）" "$(cat "$T/codev-sig.txt")"
rm -rf "$REPO" "$T/codev-sig.txt"

echo "25. 母本过滤：只挡文件不挡目录；credentials 只删数据格式/无扩展名，源码保留；大小写变体也挡"
REPO=$(mktemp -d -t codevrepo.XXXXXX)
( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t \
  && mkdir -p src/themes/dark.env certs.pem src/credentials proto \
  && echo c > src/themes/dark.env/colors.txt && echo r > certs.pem/readme.md && echo g > src/credentials/a.go \
  && echo p > proto/credentials.proto && echo s > Credentials.scala && echo q > credentials.sql \
  && echo j > credentials.json && echo b > credentials && echo y > gcp-credentials.yml && echo e > credentials.yml.enc \
  && echo k > server.key && echo K > UPPER.KEY && echo E > .ENV && echo ok > main.go \
  && git add -A && git commit -qm init >/dev/null \
  && codev_repo_master && ( cd "$CODEV_MASTER" && find . -type f | sed 's|^\./||' | sort ) ) > "$T/codev-mst.txt" 2>&1
for keep in src/themes/dark.env/colors.txt certs.pem/readme.md src/credentials/a.go proto/credentials.proto Credentials.scala credentials.sql main.go; do
  grep -qx "$keep" "$T/codev-mst.txt" && ok "保留 $keep" || bad "误删 $keep" "$(cat "$T/codev-mst.txt")"
done
for drop in credentials.json credentials gcp-credentials.yml credentials.yml.enc server.key UPPER.KEY .ENV; do
  grep -qx "$drop" "$T/codev-mst.txt" && bad "漏挡 $drop" "$(cat "$T/codev-mst.txt")" || ok "挡住 $drop"
done
chmod -R u+w "$CODEV_DIR"/codev-master-repo.* 2>/dev/null; rm -rf "$REPO" "$T/codev-mst.txt" "$CODEV_DIR"/codev-master-repo.*

# 一个【保证已死】的 pid：起个后台进程等它结束再用它的 pid。不用 999999：Linux 的 pid_max 可到 4194304，可能真活着。
sleep 0 & DEAD=$!; wait "$DEAD" 2>/dev/null
echo "26. 母本锁：陈旧锁（持锁 pid 已死）被多个等待者同时发现时只能有一个赢家；放锁只放自己的"
REPO=$(mktemp -d -t codevrepo.XXXXXX)
( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t && for i in $(seq 1 60); do echo "f$i" > "f$i.txt"; done && git add -A && git commit -qm init >/dev/null )
( cd "$REPO" && codev_master_path && mkdir -p "$CODEV_MASTER.lock" && echo "$DEAD" > "$CODEV_MASTER.lock/pid" \
  && touch -t 202001010000 "$CODEV_MASTER.lock" \
  && for i in 1 2 3 4 5 6 7 8; do ( codev_repo_master; echo "rc=$?" >> "$T/codev-lock.txt" ) & done; wait
  n=$(cd "$CODEV_MASTER" && find . -type f | wc -l | tr -d ' '); echo "files=$n" >> "$T/codev-lock.txt"
  ls -d "$CODEV_MASTER".partial.* 2>/dev/null | wc -l | tr -d ' ' | sed 's/^/partials=/' >> "$T/codev-lock.txt"
  [ -d "$CODEV_MASTER.lock" ] && echo lock-leaked >> "$T/codev-lock.txt" )
[ "$(grep -c '^rc=0$' "$T/codev-lock.txt")" = 8 ] && ok "8 个等待者全部 rc=0" || bad "有等待者失败" "$(cat "$T/codev-lock.txt")"
grep -q '^files=60$' "$T/codev-lock.txt" && ok "母本完整（60 个文件）" || bad "母本不完整" "$(cat "$T/codev-lock.txt")"
grep -q '^partials=0$' "$T/codev-lock.txt" && ok "没有残留 .partial" || bad "残留 .partial" "$(cat "$T/codev-lock.txt")"
grep -q 'lock-leaked' "$T/codev-lock.txt" && bad "锁泄漏" || ok "锁已释放"
nb=$(cat "$CODEV_DIR"/codev-master-repo.*.builders 2>/dev/null | wc -l | tr -d ' '); [ "$nb" = 1 ] && ok "只有 1 个 builder 进过临界区（直接计数）" || bad "进入临界区的 builder 数=$nb" "$(cat "$T/codev-lock.txt")"
m=$(find "$CODEV_DIR" -maxdepth 1 -type d -name 'codev-master-repo.*' ! -name '*.lock' ! -name '*.partial.*' | head -1)
[ -f "$m/f1.txt" ] && [ ! -w "$m/f1.txt" ] && ok "母本已 chmod a-w" || bad "母本不存在或仍可写" "m=$m"

echo "26b. codev_repo_copy：从 a-w 母本 clone 出 ./repo，文件齐全且只读；沙盒清理能删干净"
SB=$(mktemp -d -t codev-sbox.XXXXXX)
( cd "$REPO" && codev_repo_copy "$SB" ) && ok "repo_copy rc=0" || bad "repo_copy 失败"
[ "$(find "$SB/repo" -type f 2>/dev/null | wc -l | tr -d ' ')" = 60 ] && ok "副本 60 个文件" || bad "副本文件数不对"
[ -f "$SB/repo/f1.txt" ] && [ ! -w "$SB/repo/f1.txt" ] && ok "副本只读" || bad "副本可写"
chmod -R u+w "$SB" 2>/dev/null; rm -rf "$SB"; [ -e "$SB" ] && bad "沙盒删不掉" || ok "沙盒已清理"
chmod -R u+w "$CODEV_DIR"/codev-master-repo.* 2>/dev/null; rm -rf "$REPO" "$T/codev-lock.txt" "$CODEV_DIR"/codev-master-repo.*

echo "27. 体积闸门：CODEV_MAX_COPY_KB 非法值退回默认、超 1GB 截到上限；超闸门时 codev_repo_master 返回 1 且不铺母本"
r=$(CODEV_MAX_COPY_KB=abc; source "$LIB" 2>/dev/null; echo "$CODEV_MAX_COPY_KB"); [ "$r" = 102400 ] && ok "非法值 → 102400" || bad "非法值未退回" "$r"
r=$(CODEV_MAX_COPY_KB=9999999999; source "$LIB" 2>/dev/null; echo "$CODEV_MAX_COPY_KB"); [ "$r" = 1048576 ] && ok "超上限 → 1048576" || bad "未截到上限" "$r"
REPO=$(mktemp -d -t codevrepo.XXXXXX)
( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t && head -c 300000 /dev/zero | tr '\0' 'x' > big.txt && git add -A && git commit -qm i >/dev/null \
  && CODEV_MAX_COPY_KB=100 codev_repo_master; echo "rc=$?" > "$T/codev-gate.txt"
  # 不用 ls 通配：zsh 无匹配时报 "no matches found" 而非 "No such file"，用 find 计数两边一致
  echo "masters=$(find "$CODEV_DIR" -maxdepth 1 -type d -name 'codev-master-repo.*' ! -name '*.lock' | wc -l | tr -d ' ')" >> "$T/codev-gate.txt" )
grep -q '^rc=1$' "$T/codev-gate.txt" && ok "超闸门 rc=1" || bad "超闸门未拒绝" "$(cat "$T/codev-gate.txt")"
grep -q '^masters=0$' "$T/codev-gate.txt" && ok "未铺母本" || bad "超闸门仍铺了母本" "$(cat "$T/codev-gate.txt")"
chmod -R u+w "$CODEV_DIR"/codev-master-repo.* 2>/dev/null; rm -rf "$REPO" "$T/codev-gate.txt" "$CODEV_DIR"/codev-master-repo.* 2>/dev/null

echo "28. 沙盒 GC：超 60 分钟但 owner 进程还活着的沙盒不删；owner 已死的删"
GCD="$CODEV_DIR/gc"; mkdir -p "$GCD/codev-sbox.alive" "$GCD/codev-sbox.dead" "$GCD/codev-sbox.nomark"
echo $$ > "$GCD/codev-sbox.alive/.codev-owner"; echo "$DEAD" > "$GCD/codev-sbox.dead/.codev-owner"
touch -t 202001010000 "$GCD/codev-sbox.alive" "$GCD/codev-sbox.dead" "$GCD/codev-sbox.nomark"
( TMPDIR="$GCD"; codev_sbox_gc >/dev/null )
[ -d "$GCD/codev-sbox.alive" ] && ok "owner 活着 → 保留" || bad "活沙盒被 GC 删了"
[ -d "$GCD/codev-sbox.dead" ] && bad "owner 已死仍未删" || ok "owner 已死 → 删"
[ -d "$GCD/codev-sbox.nomark" ] && bad "无标记的旧沙盒未删" || ok "无标记旧沙盒 → 删（兼容旧版）"
rm -rf "$GCD"

echo "29. 回流 commit 拒收部分暂存：目标文件同时有已暂存与未暂存改动时 rc=1 且 index 不动"
REPO=$(mktemp -d -t codevrepo.XXXXXX); ( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t \
  && echo v1 > a.md && git add -A && git commit -qm i && echo v2 > a.md && git add a.md && echo v3 > a.md \
  && codev_commit_round a.md 1 codex 0 - msg >/dev/null 2>&1; echo "rc=$?" > "$T/codev-ps.txt"; git diff --cached -- a.md | grep -c '^+v2' >> "$T/codev-ps.txt"; git log --oneline | wc -l | tr -d ' ' >> "$T/codev-ps.txt" )
[ "$(sed -n 1p "$T/codev-ps.txt")" = "rc=1" ] && ok "部分暂存被拒" || bad "部分暂存未被拒" "$(cat "$T/codev-ps.txt")"
[ "$(sed -n 2p "$T/codev-ps.txt")" = 1 ] && ok "index 仍是用户暂存的 v2" || bad "index 被动了" "$(cat "$T/codev-ps.txt")"
[ "$(sed -n 3p "$T/codev-ps.txt")" = 1 ] && ok "没有产生 commit" || bad "产生了 commit" "$(cat "$T/codev-ps.txt")"
rm -rf "$REPO" "$T/codev-ps.txt"

echo "30. 翻牌行：rc=137 的超时写明 rc=137 而不是写死 124"
mk x "" ""; r=$(report x 137); case "$r" in *"rc=137"*) ok "137 如实显示";; *) bad "仍写死 124" "$r";; esac

chmod -R u+w "$CODEV_DIR" 2>/dev/null; rm -rf "$CODEV_DIR"   # 母本是 a-w 的，先恢复写权限
echo; echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
