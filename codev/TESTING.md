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
意见与判断记录（`codev_opinion_add` 三个枚举列校验 + `codev_opinions` 的四种一致性结论、缺席不当同意、组内顺序、
按追加顺序改判、仓库/对象/轮次/task 隔离与范围筛选、新 13 列及旧 12 列兼容、P1 级别分歧、缺失修法与补齐后重判）、
`codev_commit_round`（隔离脏文件、拒收目录、trailer、找回上一轮 commit、拒收含空白占位的文件清单且不留提交或暂存改动、真实换行分隔清单完整提交、允许一个末尾换行但拒收连续末尾换行）、
账本写入失败时 `codev_finding_add` / `codev_opinion_add` 自报丢失、无 timeout 的跳过路径不打 ▶ 运行中、`codev_archive`（归档 + git 忽略，
含 worktree 场景）、probe 空台账返回 0、cost/tokens 遇 null 不串号、账本兼容旧 7 列、`codev_commit_round` 多文件
（zsh 不拆词）、短结论含 401/rate limit 不误判、rc=137 判 timeout、母本签名随脏文件内容变、母本过滤只挡文件不挡目录
+ credentials 源码保留 + 大小写变体、陈旧锁并发回收单一赢家（直接计数进入临界区的 builder）+ 母本 a-w、
`CODEV_MAX_COPY_KB` 校验/上限与体积闸门、`CODEV_TIMEOUT` 位数守卫、沙盒 GC 按 owner pid 判活 + 会话目录按活动时间判活、
回流 commit 拒收部分暂存 + 失败时只撤回本次 add 的文件、rc=137 翻牌如实、母本签名与 cwd 无关、
母本 chmod 校验失败退回 text（chmod 被替身、母本不铺）、签名哈希皆空时不铺母本、长额度页判 quota 而长评审仍 ok、
shasum 坏时 cksum 兜底、未跟踪 FIFO 不挂死签名、沙盒超 7 天不看 pid 直接删、`self`（本 agent 的自评）走同一套翻牌/账本/probe、长散文回答含 429/rate limit 仍判 ok、FIFO 不进母本、
探针 rmdir 失败仍判不安全、扫描钉住的母本与当前不一致时拒铺副本、复用可写母本时补 a-w、长额度页翻牌带开头、
散文里的 quota limit 词不误杀；全库自审回归覆盖未跟踪内容边界、初始仓库和 textconv 签名、哈希失败传播、字面文件提交、归档复制失败和路径参数、重复调用清理 metrics、输出及 JSON 解包权限、结构化错误优先级与坏 usage；第二轮补充结构化状态重复读取、空白/对象 JSON、科学计数法和大整数、缺失计量、并发短/长记录、损坏意见拒绝放行及不可覆盖归档。
第三轮补充计量保存故障后的原文保留与重试、metrics 权限、解析器缺失/损坏、方括号正文兼容、GC 路径别名/尾斜杠/父目录保护、半行意见写入期间的回放一致性、四个读取入口的错误传播及空白主体/问题编号拒收。
9/25 使用审计回流（第 43、44 节）：503/529 过载归 quota 且正文含 503 不误杀、裸 `default` 模型名归一、轮次 `r12`/`12` 归一与非数字拒收、agent 列只收小写标签、`codev_round_trend` 计数与 ≥5 轮提示、self/check 有 token 无正文时拒绝记账、退化空目录的 ✔ 警告与账本备注及 prepare_call 清标记、codex 带行号源码不算错误行而 4xx/5xx 仍算、钉子不匹配时 `codev_bg_sandboxed` 不启动（rc=2）且不写账本、会话目录名缺随机后缀告警、`codev_prompt_gate` 三档阈值、`codev_scan_triage` 聚合与高置信形态、probe 列出 pi。f2ef64a 评审回流（第 45 节）：短回复谈过载不误杀、`401 {…}`/`403 - …`/`429 (…)` 状态行恢复、200 不算错误行、codex 回显 4xx/5xx 源码与夹具不算错误行且 ERROR 行照常、闸门在 zsh 无提示词时不中断、分诊不放过特殊字符/短值/配置裸值密钥且不把引用当真、无文件名输入聚合、轮次前导零/读取端 r 前缀/归档 rN、换行 agent 拒收、self 529 记 quota、0 文件副本打退化。5861656 评审回流（第 46 节）：self/check 调用戳与多轮 529、真实错误格式（`API Error:`、`[API Error: {…}]`、单行 JSON）、stdout 错误句式与正常短回复、非 codex 行号回显与真状态行、codex 只认行首 `ERROR:`、分诊 9 个正例与 11 个负例及原文不截断/超量 rc=4、轮次筛选拒收与非法历史行、trailer 归一与 prev_round_commit、`$PREV^` 回流 diff、闸门符号链接与断链。只读参数守卫（第 47 节）：各家 skill 写法放行、旧写法（pi `--exclude-tools`、reasonix 不带 `--permission-mode read-only`）与缺参拒绝、白名单混入写工具拒绝、九种放行类参数拒绝、提示词正文含这些字样不误判、未登记 agent 不校验、两个调用入口被拦时不启动不记账不留输出。子测试用当前 shell（`TEST_SH`）与探测到的 `CODEV_TO` 起子进程。

**加功能先加测试**：先写夹具让它红，再改库。历史上三个 bug 都是测试抓的：`$var` 紧邻全角字符被 bash 当变量名、
metrics JSON 重复键把 token 串接成天文数字、macOS awk 在 UTF-8 下 `"不成立"=="成立"` 判真。

## 1b. 各家 CLI 只读实测（CLI 升级后必跑，真调外部 agent、耗额度）

```bash
bash tests/readonly-probe.sh --control            # 全部 agent，含正向对照
bash tests/readonly-probe.sh reasonix pi          # 只测指定几家
```
每个场景用一次性临时仓库，要求 agent 真的发起三种写入（写文件工具 / shell 仓库内 / shell 仓库外）。判读：非 control 行
三项都应是 `-` 且 `existing=hello`；control 行三项都应 `WRITTEN`（否则说明提示词没让它动手，结论无效）。
`-` 只说明没写成：是 CLI 拦截还是模型自拒，要看输出目录里 `<label>.out` 的逐条报告。结果变了就同步
`references/agents.md`「只读实测」与库的 `codev_readonly_argv_check`，并在 `tests/test-lib.sh` 第 47 节改对应断言。

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
- [ ] `codev_opinions` 能按编号回放本次每个 agent 的立场，判断组结论与综合里的裁决一致；没回答的主体记的是 `未返回` 而不是空缺。
- [ ] 文档评审回流的 commit 里**文档和 changelog 两个文件都在**（`git show --stat`）——少一个说明 `$CHANGELOG` 没绑定被静默丢了。

## 4. 验收记录

| 日期 | 版本/commit | 库测试 | 微测试 | 真机清单 | 备注 |
|---|---|---|---|---|---|
| 2026-09-04 | 5b711d1 | 18/18 | 首轮场景 基线 0/3 → 对照 3/3 | 未跑（ntms 当日额度受限） | 七类翻牌/账本/CODEV_TIMEOUT/文档评审模式 |
| 2026-09-04 | 第二批 | 40/40（现 115/115，bash/zsh） | 第 2 轮场景 基线 0/3 → 对照 3/3（diff 段 2/3） | 待跑（ntms 当日 codex/codebuddy 额度受限） | 编号/diff/trailer commit/归档/自动多轮/发现台账；样本在会话 scratchpad microtest/r2-* |
| 2026-09-25 | 使用审计回流 | 302/302（bash/zsh） | 未跑（本轮只改流程文案与库守卫，微测试场景未覆盖新增项） | 未跑 | `reports/2026-09-25-usage-audit.md`；真机待验：⛔ 未启动、self 漏落盘拦截、pi 调用形态、轻量单家复审 |
| 2026-09-25 | f2ef64a 评审修复 | 329/329（bash/zsh；新增 27 项在 f2ef64a 库上 bash 27 / zsh 28 败） | 未跑 | 未跑 | 15 条评审发现全部修复，见 CHANGELOG C057-C064 |
| 2026-09-26 | 5861656 评审修复（分支 fix/codev-review-5861656） | 389/389（bash/zsh；第 46 节在 5861656 库上 bash 44 / zsh 43 败） | 未跑 | 未跑 | /code-review 13 条 + codex 12 条合并去重后全部复现成立并修复，见 CHANGELOG C065-C071 |
| 2026-09-26 | 各家 CLI 只读实测回流（分支 fix/codev-agent-readonly） | 422/422（bash/zsh；第 47 节 33 项） | 未跑 | readonly-probe：codex/gemini/reasonix/pi/codebuddy/opencode 已测，qoderclicn 额度耗尽未测 | 守卫 + pi/reasonix 调用改只读参数，见 CHANGELOG C072-C076 |
