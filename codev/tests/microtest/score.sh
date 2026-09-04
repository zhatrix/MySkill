#!/usr/bin/env bash
# 粗打分（人工仍要读每个样本）。用法: tests/microtest/score.sh <样本目录…>
for d in "$@"; do
  p="$d/codev-prompt-reasonix.txt"; [ -f "$p" ] || { echo "$d: 无提示词"; continue; }
  echo "== $d"
  printf '  提示词字节=%s  内联全文=%s  路径引用=%s  核实清单=%s  回归核对=%s  已驳回=%s  DIFF段=%s  编号=%s\n' \
    "$(wc -c < "$p" | tr -d ' ')" "$(grep -cE 'SPEC_START|DOC_START' "$p")" "$(grep -cE 'repo/|路径引用' "$p")" \
    "$(grep -c '核实清单' "$p")" "$(grep -c '回归核对' "$p")" "$(grep -cE '已驳回|不要重提' "$p")" "$(grep -c 'DIFF_START' "$p")" "$(grep -cE 'r[0-9]+-[a-z]+-[0-9]+' "$p")"
  if [ -f "$d/commit-msg.txt" ]; then
    printf '  commit: Round=%s ReviewedBy=%s VerifiedP1=%s add-A=%s pathspec=%s\n' \
      "$(grep -c '^Codev-Round:' "$d/commit-msg.txt")" "$(grep -c '^Codev-Reviewed-By:.*(' "$d/commit-msg.txt")" "$(grep -c '^Codev-Verified-P1:' "$d/commit-msg.txt")" \
      "$(grep -cE 'git add (-A|\.|--all)' "$d/commit-msg.txt")" "$(grep -cE 'git (add|commit)[^\n]*docs/' "$d/commit-msg.txt")"
  fi
  if [ -f "$d/notes.md" ]; then
    printf '  notes: fresh自审=%s 停止条件=%s 轮次上限=%s CODEV_TIMEOUT=%s metrics=%s\n' \
      "$(grep -ciE 'fresh|subagent|Agent 工具|不带.*上下文' "$d/notes.md")" "$(grep -cE '停止|收敛|连续两轮' "$d/notes.md")" "$(grep -cE 'max-rounds|轮次上限|第 3 轮' "$d/notes.md")" \
      "$(grep -c 'CODEV_TIMEOUT' "$d/notes.md")" "$(grep -c -- '--metrics' "$d/notes.md")"
  fi
done
