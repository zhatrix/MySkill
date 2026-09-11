#!/usr/bin/env bash
# codev-lib.sh 的回归测试：用假的 stdout/stderr 夹具驱动 codev_report / codev_classify / 账本，
# 断言"额度耗尽被判成功"等历史事故不再发生。运行：bash tests/test-lib.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# 当前是哪个 shell 在跑测试：子测试要用同一个 shell 起子进程，zsh 跑的时候才真的验到 zsh 路径
if [ -n "${ZSH_VERSION:-}" ]; then TEST_SH=zsh; else TEST_SH=bash; fi
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

# 清母本：zsh 默认 NOMATCH，`rm -rf … codev-master-repo.*` 在没铺母本的用例里会让【整条清理命令】中止
# （2>/dev/null 挡不住 shell 级错误），$REPO 跟着泄漏（实测每跑一次留一个 300KB 仓库）。用 find 不走 glob；
# 母本是 a-w 的，先恢复写权限。
rm_masters() { find "$CODEV_DIR" -maxdepth 1 -name 'codev-master-repo.*' -exec chmod -R u+w {} + 2>/dev/null; find "$CODEV_DIR" -maxdepth 1 -name 'codev-master-repo.*' -exec rm -rf {} + 2>/dev/null; }
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
# 枚举校验：写成英文会被 codev_stats 静默计 0（本机曾累积 48 行 adopted + 129 行 yes 才被发现）
FCK="$CODEV_DIR/fchk.tsv"
codev_finding_add ntms spec-a 1 codex m id P1 A adopted 成立 独家 "英文 verdict" 2>/dev/null && bad "英文 verdict 未被拒" || ok "finding_add 拒收英文 verdict"
codev_finding_add ntms spec-a 1 codex m id P1 A 采纳 yes 独家 "英文 verified" 2>/dev/null && bad "英文 verified 未被拒" || ok "finding_add 拒收英文 verified"
codev_finding_add ntms spec-a 1 codex m id P1 A 采纳 成立 yes "英文 unique" 2>/dev/null && bad "英文 unique 未被拒" || ok "finding_add 拒收英文 unique"
( CODEV_FINDINGS="$FCK"; codev_finding_add ntms spec-a 1 codex m id P1 A 驳回 不成立 共同 "合法枚举" ) 2>/dev/null \
  && [ "$(wc -l < "$FCK" | tr -d ' ')" = 1 ] && ok "合法枚举照常写入" || bad "合法枚举被误拒"
rm -f "$FCK"

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
rm -rf "$REPO" "$T/codev-mst.txt"; rm_masters

# 一个【保证已死】的 pid：起个后台进程等它结束再用它的 pid。不用 999999：Linux 的 pid_max 可到 4194304，可能真活着。
sleep 0 & DEAD=$!; wait "$DEAD" 2>/dev/null
echo "26. 母本锁：陈旧锁（持锁 pid 已死）被多个等待者同时发现时只能有一个赢家；放锁只放自己的"
REPO=$(mktemp -d -t codevrepo.XXXXXX)
( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t && for i in $(seq 1 60); do echo "f$i" > "f$i.txt"; done && git add -A && git commit -qm init >/dev/null )
( cd "$REPO" && codev_master_path && mkdir -p "$CODEV_MASTER.lock" && echo "$DEAD" > "$CODEV_MASTER.lock/pid" \
  && touch -t 202001010000 "$CODEV_MASTER.lock" \
  && for i in 1 2 3 4 5 6 7 8; do ( codev_repo_master; echo "rc=$?" >> "$T/codev-lock.txt" ) & done; wait
  n=$(cd "$CODEV_MASTER" && find . -type f | wc -l | tr -d ' '); echo "files=$n" >> "$T/codev-lock.txt"
  find "$CODEV_DIR" -maxdepth 1 -type d -name "$(basename "$CODEV_MASTER").partial.*" | wc -l | tr -d ' ' | sed 's/^/partials=/' >> "$T/codev-lock.txt"   # 不用 ls glob：zsh 无匹配会报错
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
rm -rf "$REPO" "$T/codev-lock.txt"; rm_masters

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
rm -rf "$REPO" "$T/codev-gate.txt"; rm_masters
r=$(CODEV_MAX_COPY_KB=99999999999999999999; source "$LIB" 2>/dev/null; echo "$CODEV_MAX_COPY_KB"); [ "$r" = 1048576 ] && ok "20 位数字（超 2^63）也截到上限" || bad "超长数字逃过上限" "$r"

echo "28. 沙盒 GC：超 60 分钟但 owner 进程还活着的沙盒不删；owner 已死的删"
GCD="$CODEV_DIR/gc"; mkdir -p "$GCD/codev-sbox.alive" "$GCD/codev-sbox.dead" "$GCD/codev-sbox.nomark"
echo $$ > "$GCD/codev-sbox.alive/.codev-owner"; echo "$DEAD" > "$GCD/codev-sbox.dead/.codev-owner"
# alive 用"2 小时前"（超 60 分钟但远不到 7 天上限——7 天以上不看 pid 一律删，见测试 34）；dead/nomark 用 2020 即可
touch -t "$(date -v-2H +%Y%m%d%H%M 2>/dev/null || date -d '2 hours ago' +%Y%m%d%H%M)" "$GCD/codev-sbox.alive"
touch -t 202001010000 "$GCD/codev-sbox.dead" "$GCD/codev-sbox.nomark"
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

echo "29b. 回流 commit 失败时只撤回本次 add 的文件：用户自己整文件暂存的 a.md 留在 index，b.md 被撤回"
REPO=$(mktemp -d -t codevrepo.XXXXXX); ( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t \
  && echo a1 > a.md && echo b1 > b.md && git add -A && git commit -qm i && echo a2 > a.md && git add a.md && echo b2 > b.md \
  && printf '#!/bin/sh\nexit 1\n' > .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit \
  && codev_commit_round "a.md b.md" 1 codex 0 - msg >/dev/null 2>&1; echo "rc=$?" > "$T/codev-rb.txt"; git diff --cached --name-only >> "$T/codev-rb.txt" )
grep -q '^rc=1$' "$T/codev-rb.txt" && ok "hook 失败 rc=1" || bad "rc 不对" "$(cat "$T/codev-rb.txt")"
grep -qx 'a.md' "$T/codev-rb.txt" && ok "用户暂存的 a.md 仍在 index" || bad "a.md 被撤回了" "$(cat "$T/codev-rb.txt")"
grep -qx 'b.md' "$T/codev-rb.txt" && bad "本次 add 的 b.md 未撤回" "$(cat "$T/codev-rb.txt")" || ok "本次 add 的 b.md 已撤回"
rm -rf "$REPO" "$T/codev-rb.txt"

echo "30. 翻牌行：rc=137 的超时写明 rc=137 而不是写死 124"
mk x "" ""; r=$(report x 137); case "$r" in *"rc=137"*) ok "137 如实显示";; *) bad "仍写死 124" "$r";; esac

echo "31. 第 2 轮回流：CODEV_TIMEOUT 位数守卫；会话目录 GC 按活动时间判活；母本签名与调用 cwd 无关"
r=$(CODEV_TIMEOUT=99999999999999999999; source "$LIB" 2>/dev/null; echo "$CODEV_TIMEOUT"); [ "$r" = 600 ] && ok "20 位 CODEV_TIMEOUT → 600" || bad "超长 CODEV_TIMEOUT 穿透" "$r"
GCD="$CODEV_DIR/gc2"; mkdir -p "$GCD/codev.active/sub" "$GCD/codev.stale"
echo x > "$GCD/codev.active/sub/codev-out-x.txt"; echo y > "$GCD/codev.stale/old.txt"
touch -t 202001010000 "$GCD/codev.active" "$GCD/codev.stale" "$GCD/codev.stale/old.txt"   # 目录 mtime 都很旧；active 里有个新文件
( TMPDIR="$GCD"; codev_sbox_gc >/dev/null )
[ -d "$GCD/codev.active" ] && ok "24h 内有文件活动的会话目录保留" || bad "活会话目录被 GC 删了"
[ -d "$GCD/codev.stale" ] && bad "24h 无活动的会话目录未删" || ok "无活动会话目录 → 删"
rm -rf "$GCD"
REPO=$(mktemp -d -t codevrepo.XXXXXX)
( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t && mkdir -p a/b && echo 1 > top.txt && echo 2 > a/b/deep.txt && git add -A && git commit -qm i \
  && echo u > untracked-top.txt && codev_master_path && printf '%s\n' "$CODEV_MASTER" && cd a/b && codev_master_path && printf '%s\n' "$CODEV_MASTER" ) > "$T/codev-cwd.txt"
[ "$(sort -u "$T/codev-cwd.txt" | wc -l | tr -d ' ')" = 1 ] && ok "根目录与子目录算出同一母本路径" || bad "签名随 cwd 变" "$(cat "$T/codev-cwd.txt")"
rm -rf "$REPO" "$T/codev-cwd.txt"

echo "33. 长 stdout（≥600 字节）的额度页 → quota；同样长但带标题/P 级的真评审即使提到 429 也 → ok；shasum 坏了退 cksum"
mk x "$(printf 'You have reached your credit usage limit for today. %s' "$(head -c 700 /dev/zero | tr '\0' 'x')")" ""
r=$(codev_classify x 0 "$CODEV_DIR/codev-out-x.txt" "$CODEV_DIR/codev-err-x.txt"); [ "$r" = quota ] && ok "长额度页 → quota" || bad "长额度页判成 $r"
mk x "$(printf '## Review\nThe 429 rate limit retry path is fine. P2: minor. %s' "$(head -c 700 /dev/zero | tr '\0' 'y')")" ""
r=$(codev_classify x 0 "$CODEV_DIR/codev-out-x.txt" "$CODEV_DIR/codev-err-x.txt"); [ "$r" = ok ] && ok "长评审含 429 仍 → ok" || bad "长评审判成 $r"
mk x "$(printf 'The retry path uses a token bucket; when the upstream returns 429 or a rate limit header we back off exponentially and the authentication cache is refreshed. %s' "$(head -c 700 /dev/zero | tr '\0' 'z')")" ""
r=$(codev_classify x 0 "$CODEV_DIR/codev-out-x.txt" "$CODEV_DIR/codev-err-x.txt"); [ "$r" = ok ] && ok "无标记的长散文含 429/rate limit → 仍 ok（只认强错误短语）" || bad "长散文被误杀成 $r"
h=$(printf 'abc' | { shasum() { return 1; }; codev_hash; }); case "$h" in [0-9]*) ok "shasum 坏 → cksum 兜底（${h}）";; *) bad "cksum 兜底失效" "[$h]";; esac

echo "34. 未跟踪的 FIFO 不会让签名计算挂死；沙盒超 7 天即使 owner pid 活着也删"
REPO=$(mktemp -d -t codevrepo.XXXXXX); ( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t && echo a > a.txt && git add -A && git commit -qm i && mkfifo pipe.fifo \
  && "$CODEV_TO" 20 "$TEST_SH" -c '. "'"$LIB"'"; codev_master_path' >/dev/null 2>&1; echo "rc=$?" > "$T/codev-fifo.txt"
  "$CODEV_TO" 60 "$TEST_SH" -c 'CODEV_DIR="'"$CODEV_DIR"'"; . "'"$LIB"'"; codev_repo_master >/dev/null 2>&1 && find "$CODEV_MASTER" -type p | wc -l | tr -d " "' >> "$T/codev-fifo.txt" 2>/dev/null )
grep -q '^rc=0$' "$T/codev-fifo.txt" && ok "有 FIFO 时 codev_master_path 秒回 rc=0" || bad "FIFO 让签名挂死/失败" "$(cat "$T/codev-fifo.txt")"
[ "$(sed -n 2p "$T/codev-fifo.txt")" = 0 ] && ok "FIFO 不进母本" || bad "FIFO 进了母本" "$(cat "$T/codev-fifo.txt")"; rm_masters
rm -rf "$REPO" "$T/codev-fifo.txt"
GCD="$CODEV_DIR/gc3"; mkdir -p "$GCD/codev-sbox.ancient"; echo $$ > "$GCD/codev-sbox.ancient/.codev-owner"; touch -t 202001010000 "$GCD/codev-sbox.ancient"
( TMPDIR="$GCD"; codev_sbox_gc >/dev/null ); [ -d "$GCD/codev-sbox.ancient" ] && bad "7 天以上的沙盒因 pid 活着未删" || ok "超 7 天沙盒不看 pid 直接删"; rm -rf "$GCD"

echo "35. self（本 agent 的 fresh-subagent）走同一套翻牌与账本：codev_report self 记 ✔、模型取 CODEV_MODEL_self、probe 列出 self"
mk self "## A. 已查证的结论
P2 r1-self-01 …" ""; export CODEV_MODEL_self=claude-test-model
r=$(report self 0); case "$r" in *"✔ self 完成"*) ok "self 翻牌 ✔";; *) bad "self 翻牌不对" "$r";; esac
grep -q "	self	claude-test-model	ok	" "$CODEV_LEDGER" && ok "账本 agent=self 模型=CODEV_MODEL_self" || bad "self 未进账本" "$(tail -1 "$CODEV_LEDGER")"
unset CODEV_MODEL_self
codev_probe 2>/dev/null | grep -q '^OK   self' && ok "probe 列出 self" || bad "probe 未列 self"

echo "37. 复用母本时若发现可写（上个 builder 在 mv 后、chmod 前被杀）→ 补 a-w；长额度页翻牌行显示开头"
REPO=$(mktemp -d -t codevrepo.XXXXXX); ( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t && echo v > f.txt && git add -A && git commit -qm i >/dev/null \
  && codev_repo_master >/dev/null 2>&1 && chmod -R u+w "$CODEV_MASTER" && codev_repo_master >/dev/null 2>&1; echo "w=$([ -w "$CODEV_MASTER/f.txt" ] && echo yes || echo no)" > "$T/codev-reuse.txt" )
grep -q '^w=no$' "$T/codev-reuse.txt" && ok "复用时补回 a-w" || bad "复用的母本仍可写" "$(cat "$T/codev-reuse.txt")"; rm -rf "$REPO" "$T/codev-reuse.txt"; rm_masters
mk x "$(printf "You've reached your usage limit for today, upgrade your plan. %s" "$(head -c 700 /dev/zero | tr '\0' 'q')")" ""
r=$(report x 0); case "$r" in *"⛔ x 额度"*"reached your usage limit"*) ok "长额度页翻牌带开头原句";; *) bad "长额度页翻牌没显示原因" "$r";; esac
mk x "$(printf 'When the quota limit of the upstream API is hit we degrade gracefully and the usage limit counter resets at midnight. %s' "$(head -c 700 /dev/zero | tr '\0' 'w')")" ""
r=$(codev_classify x 0 "$CODEV_DIR/codev-out-x.txt" "$CODEV_DIR/codev-err-x.txt"); [ "$r" = ok ] && ok "散文里的 quota limit/usage limit 词不误杀" || bad "散文被判成 $r"

echo "36. 扫描钉住的母本与当前母本不一致（扫完工作区又被改）→ codev_repo_copy 拒发 rc=1；一致或无钉子 → 正常"
REPO=$(mktemp -d -t codevrepo.XXXXXX); SB=$(mktemp -d -t codev-sbox.XXXXXX)
( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t && echo v > f.txt && git add -A && git commit -qm i >/dev/null \
  && codev_master_path && printf '%s' "$CODEV_MASTER" > "$CODEV_DIR/codev-scanned-master" && codev_repo_copy "$SB" >/dev/null 2>&1; echo "match rc=$?" > "$T/codev-pin.txt"
  chmod -R u+w "$SB" 2>/dev/null; rm -rf "$SB/repo"; echo changed >> f.txt && codev_repo_copy "$SB" >/dev/null 2>&1; echo "mismatch rc=$?" >> "$T/codev-pin.txt"
  rm -f "$CODEV_DIR/codev-scanned-master"; chmod -R u+w "$SB" 2>/dev/null; rm -rf "$SB/repo"; codev_repo_copy "$SB" >/dev/null 2>&1; echo "nopin rc=$?" >> "$T/codev-pin.txt" )
grep -q '^match rc=0$' "$T/codev-pin.txt" && ok "钉子一致 → 铺副本" || bad "一致时被拒" "$(cat "$T/codev-pin.txt")"
grep -q '^mismatch rc=1$' "$T/codev-pin.txt" && ok "扫后工作区变了 → 拒发" || bad "不一致未拒" "$(cat "$T/codev-pin.txt")"
grep -q '^nopin rc=0$' "$T/codev-pin.txt" && ok "无钉子 → 不拦" || bad "无钉子被拒" "$(cat "$T/codev-pin.txt")"
chmod -R u+w "$SB" 2>/dev/null; rm -rf "$REPO" "$SB" "$T/codev-pin.txt"; rm_masters

echo "32b. 探针 mkdir 成功但 rmdir 失败（ACL 允许建不允许删）→ 仍判不安全、不铺母本"
REPO=$(mktemp -d -t codevrepo.XXXXXX); ( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t && echo v > f.txt && git add -A && git commit -qm i >/dev/null \
  && chmod() { case "$*" in *a-w*) return 0;; *) command chmod "$@";; esac; } && rmdir() { return 1; } && codev_repo_master >/dev/null 2>&1; echo "rc=$?" > "$T/codev-pr.txt"
  echo "masters=$(find "$CODEV_DIR" -maxdepth 1 -type d -name 'codev-master-repo.*' ! -name '*.lock' | wc -l | tr -d ' ')" >> "$T/codev-pr.txt" )
grep -q '^rc=1$' "$T/codev-pr.txt" && ok "rmdir 失败仍 rc=1" || bad "rmdir 失败被判安全" "$(cat "$T/codev-pr.txt")"
grep -q '^masters=0$' "$T/codev-pr.txt" && ok "未留下母本" || bad "留下了母本" "$(cat "$T/codev-pr.txt")"
rm -rf "$REPO" "$T/codev-pr.txt"; rm_masters

echo "32. 母本 chmod -R a-w 未生效（用替身 chmod 模拟 ACL/只读挂载失败）→ 不铺母本、退回 text；签名哈希皆空 → 不铺母本"
REPO=$(mktemp -d -t codevrepo.XXXXXX); ( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t && echo v > f.txt && git add -A && git commit -qm i >/dev/null \
  && chmod() { case "$*" in *a-w*) return 0;; *) command chmod "$@";; esac; } && codev_repo_master >/dev/null 2>&1; echo "rc=$?" > "$T/codev-chm.txt"
  echo "masters=$(find "$CODEV_DIR" -maxdepth 1 -type d -name 'codev-master-repo.*' ! -name '*.lock' | wc -l | tr -d ' ')" >> "$T/codev-chm.txt" )
grep -q '^rc=1$' "$T/codev-chm.txt" && ok "chmod 无效时 rc=1" || bad "chmod 无效仍成功" "$(cat "$T/codev-chm.txt")"
grep -q '^masters=0$' "$T/codev-chm.txt" && ok "未留下可写母本" || bad "留下了可写母本" "$(cat "$T/codev-chm.txt")"
( cd "$REPO" && shasum() { return 1; } && cksum() { return 1; } && codev_master_path 2>/dev/null; echo "rc=$?" > "$T/codev-hash.txt" )
grep -q '^rc=1$' "$T/codev-hash.txt" && ok "哈希皆空 → codev_master_path rc=1" || bad "哈希皆空仍 rc=0" "$(cat "$T/codev-hash.txt")"
rm -rf "$REPO" "$T/codev-chm.txt" "$T/codev-hash.txt"; rm_masters

echo "22. 计量盲区：CODEV_TOKENS_/CODEV_COST_ 覆盖 + JSON 输出解包（codebuddy/self 曾恒记 0）"
# 22a 编排器直接告知用量（子 agent 没有 CLI、拿不到 metrics 文件）
t=$(CODEV_TOKENS_self=204321 codev_tokens self)
case "$t" in "tokens 204321") ok "CODEV_TOKENS_<agent> 生效";; *) bad "env 用量未生效" "$t";; esac
c=$(CODEV_COST_self='1.29 CNY' codev_cost self)
case "$c" in "1.29 CNY") ok "CODEV_COST_<agent> 生效";; *) bad "env 成本未生效" "$c";; esac
# 22b 变异证明：脏值必须被丢弃，不能拼进账本、更不能被 eval
for v in '123; rm -rf /' 'abc' '1e9' '$(id)' ''; do
  t=$(CODEV_TOKENS_self="$v" codev_tokens self)
  [ -z "$t" ] || { bad "脏 token 值被采信: [$v] → [$t]"; break; }
done
[ -z "${t:-}" ] && ok "非数字/注入型 token 值一律丢弃"
# 22c JSON 解包：正常路径给出正文 + 用量 + 成本
printf '%s' '[{"type":"result","result":"正文 OK","usage":{"input_tokens":7,"output_tokens":3},"total_cost_usd":0.5}]' > "$CODEV_DIR/codev-out-uw.txt"
rm -f "$CODEV_DIR/codev-metrics-uw.json"; codev_unwrap_result uw
[ "$(cat "$CODEV_DIR/codev-out-uw.txt")" = "正文 OK" ] && ok "解包还原正文" || bad "正文未还原" "$(cat "$CODEV_DIR/codev-out-uw.txt")"
t=$(codev_tokens uw); case "$t" in "tokens 10") ok "解包后 tokens 可读";; *) bad "解包后 tokens 错" "$t";; esac
c=$(codev_cost uw); case "$c" in "0.500 USD") ok "解包后 cost 可读";; *) bad "解包后 cost 错" "$c";; esac
# 22d fail-safe 变异：六种坏输入都必须【原样不动】，否则会毁掉要逐字呈现的正文
uwbad=0
for fx in '# 评审结论 无 P1' \
          '[{"type":"message","text":"hi"}]' \
          '[{"type":"result","result":"   "}]' \
          '[{"type":"result","usage":{"input_tokens":5}}]' \
          '[{"type":"result","result":"x"' \
          '{"type":"message","text":"x"}'; do
  printf '%s' "$fx" > "$CODEV_DIR/codev-out-uw.txt"; rm -f "$CODEV_DIR/codev-metrics-uw.json"
  codev_unwrap_result uw
  [ "$(cat "$CODEV_DIR/codev-out-uw.txt")" = "$fx" ] || { bad "坏输入被改写: $fx"; uwbad=1; break; }
  [ -f "$CODEV_DIR/codev-metrics-uw.json" ] && { bad "坏输入仍写了 metrics: $fx"; uwbad=1; break; }
done
[ "$uwbad" = 0 ] && ok "六种坏输入均原样不动、不写 metrics"
# 22e 解包必须排在 classify 之前：JSON 包着正文时 classify 会看错
printf '%s' '[{"type":"result","result":"# 结论\nPASS 无 P1","usage":{"input_tokens":9,"output_tokens":1}}]' > "$CODEV_DIR/codev-out-uw2.txt"
: > "$CODEV_DIR/codev-err-uw2.txt"
r=$(codev_report uw2 0 "$CODEV_DIR/codev-err-uw2.txt" 2>&1)
case "$r" in *"✔"*"tokens 10"*) ok "codev_report 内解包→分类→计量链路通";; *) bad "report 链路未拿到用量" "$r";; esac

echo "23. 意见与判断记录：codev_opinion_add 逐条留痕，codev_opinions 按问题回放并判定判断组是否一致"
export CODEV_OPINIONS="$CODEV_DIR/opinions.tsv"
unset CODEV_TASK_ID  # 不继承调用者的任务身份
codev_opinion_add ntms spec-a 2 codex gpt-5.6-sol 评审 r2-codex-01 提出 P1 "绑定 CHANGELOG" "SKILL.md:537"
codev_opinion_add ntms spec-a 2 claude opus-5 判断 r2-codex-01 采纳 P1 "绑定 CHANGELOG" "已复现空变量被丢弃"
codev_opinion_add ntms spec-a 2 codex gpt-5.6-sol 判断 r2-codex-01 采纳 P1 "绑定 CHANGELOG" -
codev_opinion_add ntms spec-a 2 gemini g3 评审 r2-gem-01 提出 P2 "含	制表符	的修法" -
codev_opinion_add ntms spec-a 2 claude opus-5 判断 r2-gem-01 采纳 P2 "方案甲" -
codev_opinion_add ntms spec-a 2 codex gpt-5.6-sol 判断 r2-gem-01 采纳 P2 "方案乙" -
codev_opinion_add ntms spec-a 2 claude opus-5 判断 r2-drop-01 驳回 - "无需修改" "证据不成立"
codev_opinion_add ntms spec-a 2 codex gpt-5.6-sol 判断 r2-drop-01 驳回 - "无需修改" -
codev_opinion_add ntms spec-a 2 codex gpt-5.6-sol 判断 r2-miss-01 未返回 P1 - "超时"
n=$(wc -l < "$CODEV_OPINIONS" | tr -d ' '); [ "$n" = 9 ] && ok "9 行" || bad "行数 $n" "$(cat "$CODEV_OPINIONS")"
awk -F'\t' 'NF!=13 || $13==""{bad=1} END{exit bad}' "$CODEV_OPINIONS" && ok "每行 13 列（含 task，制表符已转义）" || bad "列数不齐" "$(awk -F'\t' '{print NF}' "$CODEV_OPINIONS")"
r=$(codev_opinions)
# 一致/分歧的四种结论必须分得开——只执行一致意见（spec §3.4）全靠这一判断，判错就会执行没达成一致的修法
case "$r" in *"r2-codex-01"*"一致采纳同一修法"*) ok "同修法同采纳 → 可进执行清单";; *) bad "一致采纳未判出" "$r";; esac
case "$r" in *"修法不同"*disputed*) ok "均采纳但修法不同 → disputed";; *) bad "修法分歧未判出" "$r";; esac
case "$r" in *"r2-drop-01"*"一致驳回"*) ok "一致驳回 → 关闭";; *) bad "一致驳回未判出" "$r";; esac
# 缺席不等于同意：codev_ledger 那边"超时被当成功"的老账已经付过学费，判断票这里更不能重演
case "$r" in *"未返回"*"未达成一致"*) ok "未返回不算同意";; *) bad "未返回被当成一致" "$r";; esac
case "$r" in *"⚠️ 涉及 P1"*) ok "P1 分歧带阻塞提醒";; *) bad "P1 分歧无提醒" "$r";; esac
# 组内顺序：时间戳只到分钟，同轮记录全并列，靠 sort 会把裁决排到提出前面，回放读起来是倒的
case "$r" in *"评审 codex"*"判断 claude"*) ok "组内按 评审→判断 排";; *) bad "组内顺序倒了" "$r";; esac
r=$(codev_opinions r2-codex-01)
case "$r" in *r2-gem-01*) bad "按问题过滤失效" "$r";; *r2-codex-01*) ok "按问题过滤";; *) bad "过滤后没内容" "$r";; esac
case "$(codev_opinions nosuch)" in *"没有匹配的记录"*) ok "无匹配有明确提示";; *) bad "无匹配未提示";; esac
case "$(CODEV_OPINIONS="$CODEV_DIR/none.tsv" codev_opinions)" in *"意见记录为空"*) ok "空记录不报错";; *) bad "空记录处理错";; esac
OCK="$CODEV_DIR/ochk.tsv"
codev_opinion_add a b 1 c d 巡视 i 提出 P1 f n 2>/dev/null && bad "非法 role 未被拒" || ok "opinion_add 拒收非法 role"
codev_opinion_add a b 1 c d 判断 i adopted P1 f n 2>/dev/null && bad "英文 stance 未被拒" || ok "opinion_add 拒收英文 stance"
codev_opinion_add a b 1 c d 判断 i 采纳 P0 f n 2>/dev/null && bad "非法 severity 未被拒" || ok "opinion_add 拒收非法 severity"
codev_opinion_add a b 1 c d 判断 i 采纳 P1 未加引号的 修法 n 2>/dev/null && bad "多余实参未被拒" || ok "opinion_add 拒收未加引号的修法"
( CODEV_OPINIONS="$OCK"; codev_opinion_add a b 1 c d 判断 i 采纳 P1 "合法" - ) 2>/dev/null \
  && [ "$(wc -l < "$OCK" | tr -d ' ')" = 1 ] && ok "合法枚举照常写入" || bad "合法枚举被误拒"
rm -f "$OCK"

echo "24. 回放回归：追加改判、范围隔离、P1 级别分歧与缺失修法"
# 固定同一分钟，并让最后改判的时间更早，确保计票既不按字典序也不按时间排序。
export CODEV_OPINIONS="$CODEV_DIR/opinion-regression.tsv"
printf '%s\n' \
  '2026-09-11T12:01|repo-a|spec-a|1|claude|old|判断|changed|未返回|P1|-|首次缺席|task-a' \
  '2026-09-11T12:01|repo-a|spec-a|1|codex|m|判断|changed|采纳|P2|修法甲|-|task-a' \
  '2026-09-11T12:00|repo-a|spec-a|1|claude|new|判断|changed|采纳|P2|修法甲|补证后改判|task-a' \
  '2026-09-11T12:00|repo-a|spec-a|1|claude|new|评审|changed|提出|P1|修法乙|不同角色不覆盖判断|task-a' \
  | tr '|' '\t' > "$CODEV_OPINIONS"
r=$(codev_opinions changed)
case "$r" in *"可进执行清单"*) ok "最后追加立场覆盖旧票，模型变化不增加判断主体";; *) bad "改判仍未一致" "$r";; esac
case "$r" in *"首次缺席"*"补证后改判"*) ok "同角色完整历史保留追加顺序";; *) bad "历史丢失或排序错误" "$r";; esac
case "$r" in *"⚠️ 涉及 P1"*) bad "旧判断或其它角色的 P1 污染当前判断" "$r";; *) ok "P1 级别只取有效判断";; esac
CODEV_TASK_ID=task-a codev_opinion_add repo-a spec-a 1 claude m 判断 changed 驳回 P2 无需修改 再次改判
r=$(codev_opinions changed)
case "$r" in *"可进执行清单"*) bad "最后改为驳回仍可执行" "$r";; *"未达成一致"*) ok "采纳改为驳回后恢复分歧";; *) bad "改判丢失" "$r";; esac

# 交错写入相同编号，逐一改变仓库、对象、轮次、任务；每组应独立形成结论。
CODEV_TASK_ID=task-a codev_opinion_add repo-a spec-a 1 claude m 判断 shared 采纳 P2 修法甲 base
CODEV_TASK_ID=task-a codev_opinion_add repo-b spec-a 1 claude m 判断 shared 驳回 P2 无需修改 repo
CODEV_TASK_ID=task-a codev_opinion_add repo-a spec-b 1 claude m 判断 shared 驳回 P2 无需修改 doc
CODEV_TASK_ID=task-a codev_opinion_add repo-a spec-a 2 claude m 判断 shared 驳回 P2 无需修改 round
CODEV_TASK_ID=task-b codev_opinion_add repo-a spec-a 1 claude m 判断 shared 驳回 P2 无需修改 task
CODEV_TASK_ID=task-a codev_opinion_add repo-a spec-a 1 codex m 判断 shared 采纳 P2 修法甲 base-again
r=$(codev_opinions shared)
n=$(printf '%s\n' "$r" | awk '/^shared  /{n++} END{print n+0}')
[ "$n" = 5 ] && ok "同名编号按仓库/对象/轮次/任务分为五组" || bad "范围混组: $n" "$r"
n=$(printf '%s\n' "$r" | awk '/一致驳回/{n++} END{print n+0}')
case "$r" in *"未达成一致"*) bad "无关任务污染一致判断" "$r";; *"可进执行清单"*) [ "$n" = 4 ] && ok "交错记录分别采纳一组、驳回四组" || bad "分组结论错误" "$r";; *) bad "采纳组丢失" "$r";; esac
r=$(codev_opinions shared repo-a spec-a 1 task-a)
case "$r" in *"一致驳回"*) bad "范围过滤漏入其它组" "$r";; *"可进执行清单"*) ok "五维筛选仅回放指定任务问题";; *) bad "范围筛选错误" "$r";; esac
case "$(codev_opinions '' repo-b)" in *"repo=repo-a"*) bad "空 issue 的仓库过滤失效";; *"repo=repo-b"*) ok "空参数支持仅按仓库筛选";; *) bad "仓库筛选丢记录";; esac

# 旧 12 列记录保留可读，并与新 task 隔离；缺失身份不能伪装成已知任务。
printf '%s\n' '2026-09-11T12:00|repo-a|spec-a|1|claude|m|判断|shared|驳回|P2|无需修改|legacy' | tr '|' '\t' >> "$CODEV_OPINIONS"
r=$(codev_opinions shared repo-a spec-a 1)
case "$r" in *"旧记录缺少 task ID"*) ok "旧 12 列记录可读并提示身份限制";; *) bad "旧记录消失或无提示" "$r";; esac
awk -F'\t' 'NF==12' "$CODEV_OPINIONS" > "$CODEV_DIR/legacy-only.tsv"
r=$(CODEV_OPINIONS="$CODEV_DIR/legacy-only.tsv" codev_opinions shared)
case "$r" in *"→ 判断组一致驳回：关闭该项"*) bad "旧记录身份不明仍声明关闭" "$r";; *"旧记录仅供回顾"*) ok "旧记录未确认任务归属不声明执行或关闭";; *) bad "旧记录缺少保守结论" "$r";; esac
case "$(codev_opinions shared repo-a spec-a 1 task-a)" in *legacy*) bad "旧记录污染已知任务";; *"可进执行清单"*) ok "旧记录不混入已知任务";; *) bad "已知任务丢失";; esac

codev_opinion_add repo-a spec-a 1 claude m 判断 level 采纳 P1 修法甲 -
codev_opinion_add repo-a spec-a 1 codex m 判断 level 采纳 P2 修法甲 -
r=$(codev_opinions level)
case "$r" in *"可进执行清单"*) bad "P1/P2 同修法被放行" "$r";; *"严重级别分歧"*"⚠️ 涉及 P1"*) ok "同修法的 P1/P2 分歧仍阻塞";; *) bad "级别分歧无阻塞提示" "$r";; esac
codev_opinion_add repo-a spec-a 1 codex m 判断 level 采纳 P1 修法甲 澄清
r=$(codev_opinions level)
case "$r" in *"严重级别分歧"*) bad "旧级别分歧未解除" "$r";; *"可进执行清单"*) ok "级别澄清后使用最新判断";; *) bad "级别澄清未生效" "$r";; esac
codev_opinion_add repo-a spec-a 1 codex m 判断 level 采纳 - 修法甲 级别待定
r=$(codev_opinions level)
case "$r" in *"可进执行清单"*) bad "未知级别绕过 P1 分歧" "$r";; *"⚠️ 涉及 P1"*) ok "P1 与未知级别也保留阻塞";; *) bad "未知级别无阻塞提示" "$r";; esac

for fix in '-' '' '   ' '同意' '待补充' 'TBD'; do
  codev_opinion_add repo-a spec-a 1 claude m 判断 missing 采纳 P1 "$fix" -
  r=$(codev_opinions missing)
  case "$r" in *"可进执行清单"*) bad "单主体占位修法被放行: [$fix]" "$r";; *"缺少具体修法"*) ok "单主体修法待补充: [$fix]";; *) bad "缺失修法未提示: [$fix]" "$r";; esac
done
codev_opinion_add repo-a spec-a 1 claude m 判断 missing 采纳 P1 - -
codev_opinion_add repo-a spec-a 1 codex m 判断 missing 采纳 P1 - -
r=$(codev_opinions missing)
case "$r" in *"可进执行清单"*) bad "双主体占位修法被放行" "$r";; *"缺少具体修法"*) ok "双主体同占位符仍待补充";; *) bad "双主体缺修法未提示" "$r";; esac
codev_opinion_add repo-a spec-a 1 claude m 判断 missing 采纳 P1 修法甲 -
codev_opinion_add repo-a spec-a 1 codex m 判断 missing 采纳 P1 修法甲 -
case "$(codev_opinions missing)" in *"可进执行清单"*) ok "双方补齐同修法后可执行";; *) bad "补齐修法仍不可执行";; esac
codev_opinion_add repo-a spec-a 1 third m 判断 missing 采纳 P1 修法甲 -
r=$(codev_opinions missing)
case "$r" in *"可进执行清单"*) bad "三位判断者被放行" "$r";; *"判断主体超过两个"*) ok "计票仍遵守两位判断主体上限";; *) bad "未提示判断人数冲突" "$r";; esac

echo "38. 全库自审：内容签名、提交边界、归档失败与重复调用"
REPO=$(mktemp -d -t codevreview.XXXXXX)
(
  cd "$REPO" && git init -q && git config user.email t@t && git config user.name t &&
  printf init > tracked && git add tracked && git commit -qm init &&
  printf ab > a && printf c > b && codev_master_path && printf '%s\n' "$CODEV_MASTER" &&
  printf a > a && printf bc > b && codev_master_path && printf '%s\n' "$CODEV_MASTER"
) > "$CODEV_DIR/review-boundary.txt"
n=$(sort -u "$CODEV_DIR/review-boundary.txt" | wc -l | tr -d ' ')
[ "$n" = 2 ] && ok "未跟踪文件内容边界变化使签名改变" || bad "两个文件内容拼接碰撞" "$(cat "$CODEV_DIR/review-boundary.txt")"
(
  cd "$REPO" && printf 'tracked diff=audit\n' > .gitattributes && git add .gitattributes && git commit -qm attributes &&
  git config diff.audit.textconv true && printf changed > tracked && codev_master_path && printf '%s\n' "$CODEV_MASTER" &&
  printf again > tracked && codev_master_path && printf '%s\n' "$CODEV_MASTER"
) > "$CODEV_DIR/review-textconv.txt"
n=$(sort -u "$CODEV_DIR/review-textconv.txt" | wc -l | tr -d ' ')
[ "$n" = 2 ] && ok "textconv 不会隐藏真实文件内容变化" || bad "签名受 textconv 归一化影响"
(
  cd "$REPO" &&
  printf one > a.md && printf two > b.md && git add a.md b.md && git commit -qm files &&
  printf changed > a.md && printf changed > b.md
  before=$(git rev-parse HEAD)
  codev_commit_round '*.md' 1 codex 0 0 test > "$CODEV_DIR/review-glob.txt" 2>&1
  [ $? -ne 0 ] && [ "$(git rev-parse HEAD)" = "$before" ] && [ -z "$(git diff --cached --name-only)" ]
) && ok "通配 pathspec 不卷入多个未指定文件" || bad "通配符扩大提交范围"
(
  cd "$REPO" && printf literal > '*.md' && codev_commit_round '*.md' 1 codex 0 0 literal >/dev/null 2>&1 &&
  [ "$(git show --pretty= --name-only HEAD)" = '*.md' ] && [ -n "$(git diff -- a.md b.md)" ]
) && ok "含通配符的真实文件名可单独提交" || bad "字面通配文件提交不正确"
(
  cd "$REPO"
  cp() { return 1; }
  codev_archive failed-copy 1 > "$CODEV_DIR/review-archive.txt" 2>&1
  [ $? -ne 0 ] && ! grep -q '已归档到' "$CODEV_DIR/review-archive.txt"
) && ok "归档复制失败返回非零且不宣称成功" || bad "归档复制失败被隐藏"
(
  cd "$REPO"
  codev_archive .. 1 >/dev/null 2>&1; r1=$?
  codev_archive scope '1/../../escape' >/dev/null 2>&1; r2=$?
  [ "$r1" -ne 0 ] && [ "$r2" -ne 0 ]
) && ok "归档拒绝越界 slug 或轮次" || bad "归档参数可逃出目标目录"
rm -rf "$REPO"
REPO=$(mktemp -d -t codevreview.XXXXXX)
(
  cd "$REPO" && git init -q && printf one > initial && git add initial &&
  codev_master_path && printf '%s\n' "$CODEV_MASTER" &&
  printf two > initial && codev_master_path && printf '%s\n' "$CODEV_MASTER"
) > "$CODEV_DIR/review-unborn.txt"
n=$(sort -u "$CODEV_DIR/review-unborn.txt" | wc -l | tr -d ' ')
[ "$n" = 2 ] && ok "尚无 HEAD 的已暂存文件修改也改变签名" || bad "初始仓库内容变化未被哈希"
if (
  cd "$REPO"
  codev_hash() { printf abc; return 1; }
  codev_master_path >/dev/null 2>&1
); then bad "签名管道失败仍复用母本"; else ok "签名管道失败不伪造可用快照"; fi
rm -rf "$REPO"

CODEV_TIMEOUT=600  # 前面的非法参数测试故意留下 abc；实际调用必须恢复有效值
for launch in codev_bg_native codev_bg_sandboxed; do
  (
    export CODEV_SANDBOX_MODE=text
    unset CODEV_TOKENS_review CODEV_COST_review
    printf '{"prompt_tokens":900,"completion_tokens":10,"cost":2,"currency":"USD"}' > "$CODEV_DIR/codev-metrics-review.json"
    umask 022
    "$launch" review printf 'PASS' > "$CODEV_DIR/review-launch.txt" 2>&1
    [ "$(cat "$CODEV_DIR/codev-out-review.txt")" = PASS ] && [ ! -e "$CODEV_DIR/codev-metrics-review.json" ] &&
    ! grep -q 'tokens 910' "$CODEV_DIR/review-launch.txt" &&
    [ "$(tail -1 "$CODEV_LEDGER" | cut -f10,11)" = "$(printf '%s\t%s' - -)" ]
  ) && ok "$launch 不复用上一轮 metrics" || bad "$launch 沿用陈旧计量"
  [ -z "$(find "$CODEV_DIR" -maxdepth 1 \( -name codev-out-review.txt -o -name codev-err-review.txt \) \( -perm -004 -o -perm -040 \))" ] &&
    ok "$launch 输出不继承 0644 权限" || bad "$launch 输出其它用户可读"
done
(
  printf old > "$CODEV_DIR/codev-metrics-review.json"
  CODEV_TO=''
  codev_bg_native review printf PASS >/dev/null
  [ ! -e "$CODEV_DIR/codev-metrics-review.json" ]
) && ok "提前跳过调用也清理旧计量" || bad "跳过调用仍留旧计量"

echo "39. 结构化错误输出不能被 PASS 字样变成成功"
for subtype in error_max_turns error_during_execution; do
  printf '[{"type":"result","is_error":true,"subtype":"%s","result":"# Partial\\nPASS","usage":{"input_tokens":1,"output_tokens":2}}]' "$subtype" > "$CODEV_DIR/codev-out-jsonerr.txt"
  : > "$CODEV_DIR/codev-err-jsonerr.txt"
  r=$(codev_report jsonerr 0 "$CODEV_DIR/codev-err-jsonerr.txt")
  case "$r" in *'✔'*) bad "结构化错误被当成功: $subtype" "$r";; *'终稿未产出'*|*'非零退出/报错'*) ok "结构化错误覆盖文本判断: $subtype";; *) bad "错误未分类: $subtype" "$r";; esac
done
printf '%s' '[{"type":"result","is_error":true,"subtype":"error_max_turns","result":""}]' > "$CODEV_DIR/codev-out-jsonerr.txt"
r=$(codev_report jsonerr 0 "$CODEV_DIR/codev-err-jsonerr.txt")
case "$r" in *'✔'*) bad "空结果的结构化错误被当成功" "$r";; *'终稿未产出'*) ok "空结构化错误也识别 turn 耗尽";; *) bad "空错误未分类" "$r";; esac
printf '%s' '[{"type":"result","result":"PASS","usage":"invalid"}]' > "$CODEV_DIR/codev-out-jsonbad.txt"
before=$(cat "$CODEV_DIR/codev-out-jsonbad.txt")
codev_unwrap_result jsonbad
[ "$(cat "$CODEV_DIR/codev-out-jsonbad.txt")" = "$before" ] && ok "坏 usage 不会先覆盖原始正文" || bad "解包失败仍破坏原始输出"
(
  umask 022
  codev_bg_native jsonmode printf '%s' '[{"type":"result","result":"PASS"}]' >/dev/null 2>&1
  [ "$(cat "$CODEV_DIR/codev-out-jsonmode.txt")" = PASS ] &&
  [ -z "$(find "$CODEV_DIR/codev-out-jsonmode.txt" \( -perm -004 -o -perm -040 \))" ]
) && ok "JSON 解包后仍保持输出仅本人可读" || bad "JSON 解包扩大输出权限"
mkdir "$CODEV_DIR/codev-metrics-jsonio.json"
printf '%s' '[{"type":"result","is_error":true,"subtype":"error_max_turns","result":"PASS","usage":{"input_tokens":1}}]' > "$CODEV_DIR/codev-out-jsonio.txt"
: > "$CODEV_DIR/codev-err-jsonio.txt"
r=$(codev_report jsonio 0 "$CODEV_DIR/codev-err-jsonio.txt")
case "$r" in *'✔'*) bad "metrics 写入失败掩盖结构化错误" "$r";; *'终稿未产出'*) ok "metrics 写入失败仍保留结构化错误";; *) bad "metrics 失败后丢失错误状态" "$r";; esac
printf '%s' '[{"type":"result","is_error":true,"result":"PASS","usage":"invalid"}]' > "$CODEV_DIR/codev-out-jsonio.txt"
r=$(codev_report jsonio 0 "$CODEV_DIR/codev-err-jsonio.txt")
case "$r" in *'✔'*) bad "坏 usage 掩盖明确的 is_error" "$r";; *'非零退出/报错'*) ok "坏 usage 不会把明确错误变为成功";; *) bad "坏 usage 后错误状态丢失" "$r";; esac
mkdir "$CODEV_DIR/codev-out-jsonio.txt.unwrap"
printf '%s' '[{"type":"result","is_error":true,"result":"PASS"}]' > "$CODEV_DIR/codev-out-jsonio.txt"
r=$(codev_report jsonio 0 "$CODEV_DIR/codev-err-jsonio.txt")
case "$r" in *'✔'*) bad "正文替换失败掩盖 is_error" "$r";; *'非零退出/报错'*) ok "正文替换失败仍保留结构化错误";; *) bad "替换失败后错误状态丢失" "$r";; esac

echo "40. 第二轮全库自审：结构化状态重放、精确计量与并发持久化"
printf '%s' '[{"type":"result","is_error":true,"result":"PASS"}]' > "$CODEV_DIR/codev-out-repeat.txt"
: > "$CODEV_DIR/codev-err-repeat.txt"
r=$(codev_report repeat 0 "$CODEV_DIR/codev-err-repeat.txt")
r=$(codev_report repeat 0 "$CODEV_DIR/codev-err-repeat.txt")
case "$r" in *'✔'*) bad "二次 report 把失败变为成功" "$r";; *'非零退出/报错'*) ok "二次 report 保留结构化失败";; *) bad "二次 report 丢失状态" "$r";; esac
for fx in '  [{"type":"result","is_error":true,"result":"PASS"}]' '{"type":"result","is_error":true,"result":"PASS"}'; do
  printf '\n%s' "$fx" > "$CODEV_DIR/codev-out-repeat.txt"
  r=$(codev_report repeat 0 "$CODEV_DIR/codev-err-repeat.txt")
  case "$r" in *'✔'*) bad "合法 JSON 形状绕过错误状态" "$r";; *'非零退出/报错'*) ok "识别空白前缀/对象形式的错误 JSON";; *) bad "JSON 状态未识别" "$r";; esac
done
printf '%s' '{"type":"result","result":"PASS","usage":{"input_tokens":2,"output_tokens":3}}' > "$CODEV_DIR/codev-out-repeat.txt"
r=$(codev_report repeat 0 "$CODEV_DIR/codev-err-repeat.txt")
case "$r" in *'✔'*'tokens 5'*) ok "对象形式的成功结果也可解包和计量";; *) bad "成功对象解包失败" "$r";; esac
printf 'PASS changed' > "$CODEV_DIR/codev-out-repeat.txt"
r=$(codev_report repeat 0 "$CODEV_DIR/codev-err-repeat.txt")
case "$r" in *'✔'*) ok "旧状态不污染内容不同的新输出";; *) bad "旧状态污染新输出" "$r";; esac
printf '%s' '[{"type":"result","is_error":true,"result":"PASS"}]' > "$CODEV_DIR/codev-out-repeat.txt"
codev_report repeat 0 "$CODEV_DIR/codev-err-repeat.txt" >/dev/null
r=$(codev_bg_native repeat printf PASS)
case "$r" in *'✔'*) ok "新调用即使正文相同也不沿用旧状态";; *) bad "新调用误用旧状态" "$r";; esac

printf '%s' '{"cost":1e-5,"currency":"USD","prompt_tokens":9223372036854775807,"completion_tokens":2}' > "$CODEV_DIR/codev-metrics-exact.json"
[ "$(codev_tokens exact)" = 'tokens 9223372036854775809' ] && ok "大 token 数不经 shell 溢出" || bad "token 溢出或丢失"
[ "$(codev_cost exact)" = '0.000 USD' ] && ok "科学计数法按真实金额舍入" || bad "科学计数法被截成整数"
printf '%s' '{"provider":{"prompt_tokens":100,"completion_tokens":20,"cost":50},"prompt_tokens":2,"completion_tokens":3,"cost":0.5,"currency":"USD"}' > "$CODEV_DIR/codev-metrics-exact.json"
[ "$(codev_tokens exact)" = 'tokens 5' ] && [ "$(codev_cost exact)" = '0.500 USD' ] && ok "只读取顶层 metrics" || bad "嵌套 provider 冒充总计"
for fx in '{"prompt_tokens":2}' '{"prompt_tokens":2,"completion_tokens":null}' '{"prompt_tokens":2.5,"completion_tokens":3}' '{"prompt_tokens":2,"completion_tokens":3'; do
  printf '%s' "$fx" > "$CODEV_DIR/codev-metrics-exact.json"
  [ -z "$(codev_tokens exact)" ] && ok "缺失/无效 token 不伪报完整总计" || bad "缺失或损坏用量仍计数: $fx"
done
[ -z "$(CODEV_COST_exact=free codev_cost exact)" ] && ok "无效成本覆盖值不被采信" || bad "任意文字被当成本"

(
  export CODEV_FINDINGS="$CODEV_DIR/concurrent-findings.tsv" CODEV_OPINIONS="$CODEV_DIR/concurrent-opinions.tsv"
  for i in $(seq 1 20); do
    codev_finding_add repo doc 1 agent model "i$i" P1 A 采纳 成立 共同 "desc$i" &
    codev_opinion_add repo doc 1 agent model 判断 "i$i" 采纳 P1 fix "note$i" &
  done
  wait
  awk -F'\t' 'NF!=13 || $7 !~ /^i[0-9]+$/ || $13 != "desc" substr($7,2){bad=1} END{exit bad || NR!=20}' "$CODEV_FINDINGS" &&
  awk -F'\t' 'NF!=13 || $8 !~ /^i[0-9]+$/ || $12 != "note" substr($8,2){bad=1} END{exit bad || NR!=20}' "$CODEV_OPINIONS"
) && ok "并发发现/意见写入行完整且字段关联正确" || bad "并发追加破坏 TSV"
(
  export CODEV_OPINIONS="$CODEV_DIR/long-opinions.tsv"
  long_note=$(head -c 70000 /dev/zero | tr '\0' x)
  for i in $(seq 1 8); do codev_opinion_add repo doc 1 agent model 判断 "i$i" 采纳 P1 fix "$i:$long_note" & done
  wait
  awk -F'\t' 'NF!=13 || length($12)!=70002 || substr($12,1,1)!=substr($8,2){bad=1} END{exit bad || NR!=8}' "$CODEV_OPINIONS"
) && ok "长记录并发也不分段交错" || bad "长记录被并发切碎"
(
  export CODEV_OPINIONS="$CODEV_DIR/broken-opinions.tsv"
  codev_opinion_add repo doc 1 claude model 判断 broken 采纳 P1 fix -
  printf 'partial\tcorrupt\n' >> "$CODEV_OPINIONS"
  codev_opinions broken > "$CODEV_DIR/broken-replay.txt"
  [ $? -ne 0 ] && ! grep -q '可进执行清单' "$CODEV_DIR/broken-replay.txt"
) && ok "损坏行不会被忽略后误判可执行" || bad "坏行被忽略并错误放行"
REPO=$(mktemp -d -t codevreview.XXXXXX)
(
  cd "$REPO" && git init -q &&
  printf original > "$CODEV_DIR/codev-out-immutable.txt" && codev_archive immutable 1 >/dev/null &&
  codev_archive immutable 1 >/dev/null &&
  printf changed > "$CODEV_DIR/codev-out-immutable.txt"
  codev_archive immutable 1 > "$CODEV_DIR/archive-conflict.txt" 2>&1
  [ $? -ne 0 ] && [ "$(cat .superpowers/codev/immutable/r1/codev-out-immutable.txt)" = original ]
) && ok "同内容可重复归档，不同内容不能覆盖已归档轮次" || bad "历史归档被新内容覆盖"
rm -rf "$REPO"

chmod -R u+w "$CODEV_DIR" 2>/dev/null; rm -rf "$CODEV_DIR"   # 母本是 a-w 的，先恢复写权限
echo; echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
