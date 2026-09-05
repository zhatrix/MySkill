# codev 测试与验收手册

改动本 skill 后按这份手册验证。三层：库回归测试（秒级、必跑）→ 文案微测试（subagent 对照、改 SKILL/prompts 时跑）
→ 真机验收（走一遍真实 `/codev`，按清单勾）。

## 1. 库回归测试（必跑）

```bash
bash tests/test-lib.sh   # bash
zsh  tests/test-lib.sh   # 本机默认 shell 是 zsh，两边都要绿
# 注意别写成 zsh -c 'bash tests/test-lib.sh'——那只是起个 zsh 立刻转交 bash，脚本从没在 zsh 下跑过。
# zsh 特有的坑（path 是绑定 $PATH 的特殊数组、glob 无匹配默认报错）只有真跑 zsh 才暴露得出来。
```
末行 `pass=N fail=0` 即通过。覆盖：七类翻牌（含 qoderclicn 额度写 stdout、codex 错误在 1MB stderr 尾部、
codebuddy 429 重置时间、Max turns、context canceled、空输出、部分输出+截断警告）、`CODEV_TIMEOUT` 生效与非法值、
账本 12 列与 probe 摘要、tokens/成本解析（含 JSON 同名键重复）、模型识别、发现台账与 `codev_stats`、
`codev_commit_round`（隔离脏文件、拒收目录、trailer、找回上一轮 commit）、`codev_archive`（归档 + git 忽略，
含 worktree 场景）、probe 空台账返回 0、cost/tokens 遇 null 不串号、账本兼容旧 7 列、`codev_commit_round` 多文件
（zsh 不拆词）、短结论含 401/rate limit 不误判、rc=137 判 timeout、母本签名随脏文件内容变、母本过滤只挡文件不挡目录
+ credentials 源码保留 + 大小写变体、陈旧锁并发回收单一赢家（直接计数进入临界区的 builder）+ 母本 a-w、
`CODEV_MAX_COPY_KB` 校验/上限与体积闸门、`CODEV_TIMEOUT` 位数守卫、沙盒 GC 按 owner pid 判活 + 会话目录按活动时间判活、
回流 commit 拒收部分暂存 + 失败时只撤回本次 add 的文件、rc=137 翻牌如实、母本签名与 cwd 无关、
母本 chmod 校验失败退回 text（chmod 被替身、母本不铺）、签名哈希皆空时不铺母本、长额度页判 quota 而长评审仍 ok、
shasum 坏时 cksum 兜底、未跟踪 FIFO 不挂死签名、沙盒超 7 天不看 pid 直接删、`self`（本 agent 的自评）走同一套翻牌/账本/probe、长散文回答含 429/rate limit 仍判 ok、FIFO 不进母本、
探针 rmdir 失败仍判不安全、扫描钉住的母本与当前不一致时拒铺副本、复用可写母本时补 a-w、长额度页翻牌带开头、
散文里的 quota limit 词不误杀；子测试用当前 shell（`TEST_SH`）与探测到的 `CODEV_TO` 起子进程。

**加功能先加测试**：先写夹具让它红，再改库。历史上三个 bug 都是测试抓的：`$var` 紧邻全角字符被 bash 当变量名、
metrics JSON 重复键把 token 串接成天文数字、macOS awk 在 UTF-8 下 `"不成立"=="成立"` 判真。

## 2. 文案微测试（改 SKILL.md / prompts.md / synthesis.md 时跑）

方法：同一个场景，旧版 skill 跑 3 个独立 subagent（基线）、新版再跑 3 个（对照），比"产出的提示词/命令/步骤"的形状。
场景文件与打分脚本在 `tests/microtest/`：

```bash
tests/microtest/run.sh <scenario.md> <skill_dir> <out_root> <label> [reps=3]   # 打印 3 条 Agent 调用提示词，逐条用 Agent 工具（sonnet）发出
tests/microtest/score.sh <out_root>/<label>-*                                   # 按场景对应指标打分
```
> `run.sh` 只生成 subagent 提示词，真正发出要用 Claude Code 的 Agent 工具（脚本外没有 subagent）。

已有场景与通过判据：

| 场景 | 判据（每个样本都要满足） | 基线（改前） | 对照（改后） |
|---|---|---|---|
| `scenario.md` 首轮文档评审 | 提示词 ≤ 45KB；路径引用不内联；有「核实清单」；`CODEV_TIMEOUT=1200`；reasonix 带 `--metrics`；codex 用 `exec` | 3/3 内联 63KB、0 收窄 | 3/3 通过（8-11KB） |
| `scenario-round2.md` 第 2 轮 `--auto` | 提示词有「回归核对」且引用编号；列出已驳回项与依据；内联 `git diff`；commit 信息含 `Codev-Round`/`Codev-Reviewed-By`（带模型）/`Codev-Verified-P1`；`git add` 只带文档 pathspec；notes 里外审前有 fresh-subagent 自审、有停止条件与轮次上限 | 0/3（无编号/无已驳回/无 diff/无 trailer/无 fresh 自审；1 例 `git add -A`） | 编号·已驳回·trailer·pathspec·fresh 自审 3/3；diff 段 2/3（漏的那例已在文案里补"必带"说明，未复测） |

判据要人工读每个样本，不能只看 grep 计数（模板回显、引用反例都会假命中）。

## 3. 真机验收清单（每次发版跑一遍）

在任意有外部 agent 的仓库里执行，逐项勾。

- [ ] `/codev` Step 0：`codev_probe` 每个 OK 的 agent 后面有 `近期: …` 摘要（首次使用没有属正常）；末尾有账本路径行。
- [ ] 故意让一个 agent 额度/鉴权失败（或用测试夹具）：翻牌是 `⛔`，输出文件内容**没有**被逐字呈现，综合里标"无效：<类别>"。
- [ ] 文档评审 `/codev review docs/xxx.md`：发出的 reasonix 提示词 `wc -c` ≤ 45KB，含路径引用与 3-8 条核实清单，不含全文内联。
- [ ] fan-out 结束后打印了 `codev_session_summary` 表；reasonix 行有 tokens 与 CNY 成本。
- [ ] 综合里每条发现有 `r<N>-<agent>-<序号>` 编号；每条采纳的 P1 裁决行带 Claude 自己核对的 `文件:行号`。
- [ ] 回流后 `git log -1 --format=%B` 有三条 `Codev-*` trailer；`git status` 显示用户的无关改动仍未提交。
- [ ] `.superpowers/codev/<slug>/r<N>/` 有 prompt/out/err 归档，且 `git status` 不显示它。
- [ ] `--round 2`：提示词里有「回归核对」（编号 + 已驳回依据）与 `DIFF_START` 段；外审前跑了一个 fresh subagent 自审。
- [ ] `--auto --max-rounds 2`：只弹一次 AskUserQuestion；两轮各有一个 commit；停止时打印记录行并给出停止原因。
- [ ] `codev_stats` 能列出本次的 agent/模型行，P1 成立/声称 数字与综合里一致。

## 4. 验收记录

| 日期 | 版本/commit | 库测试 | 微测试 | 真机清单 | 备注 |
|---|---|---|---|---|---|
| 2026-09-04 | 5b711d1 | 18/18 | 首轮场景 基线 0/3 → 对照 3/3 | 未跑（ntms 当日额度受限） | 七类翻牌/账本/CODEV_TIMEOUT/文档评审模式 |
| 2026-09-04 | 第二批 | 40/40（现 115/115，bash/zsh） | 第 2 轮场景 基线 0/3 → 对照 3/3（diff 段 2/3） | 待跑（ntms 当日 codex/codebuddy 额度受限） | 编号/diff/trailer commit/归档/自动多轮/发现台账；样本在会话 scratchpad microtest/r2-* |
