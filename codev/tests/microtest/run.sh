#!/usr/bin/env bash
# 生成 N 条 subagent 提示词（不发出——发出要用 Claude Code 的 Agent 工具，model=sonnet，general-purpose）。
# 用法: tests/microtest/run.sh <scenario.md> <skill_dir> <out_root> <label> [reps=3]
set -eu
sc="$1"; skill="$2"; root="$3"; label="$4"; reps="${5:-3}"
for i in $(seq 1 "$reps"); do
  cat <<P
--- Agent 提示词 #$i ---
Read the scenario file $sc and follow it exactly. Replace \`SKILL_DIR\` with \`$skill\` and \`OUT_DIR\` with \`$root/$label-$i\` (create it). Do not run external agent CLIs, do not create session directories, do not ask questions, do not commit. Produce the files the scenario asks for and stop. Reply with only the file paths.
P
done
