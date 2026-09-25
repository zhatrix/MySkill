# codev 使用审计：2026-09-11 至 2026-09-25

结论：14 天里 codev 在 ntms 一个项目里被密集使用（43 个会话目录、302 次外部/自评调用、1642 条发现），库本身没有出现损坏数据的新缺陷；问题集中在四处：外部 CLI 的过载与超时被记成笼统的 error/empty、编排器反复踩同样的流程坑（self 先 report 后落盘、zsh 语法、worktree 守卫）、多轮评审跨会话失控（一份计划磨到第 14 轮）、以及完整流程对"让一家看一眼"太重（用户三次绕开 codev 自己跑 codex）。本次把能在库层兜住的做成守卫与函数（`codev_report` 两道守卫、`⛔ 未启动`、`codev_round_trend` / `codev_prompt_gate` / `codev_scan_triage`），把流程层的写进 SKILL / synthesis / agents。

上个版本 = `797a875`（2026-09-11）。以下时间均为北京时间。

## 1. 数据源

- 调用账本 `~/.local/state/codev/ledger.tsv`：窗口内 302 行、43 个会话目录。
- 发现台账 `findings.tsv`：1642 行，26 个评审对象，79 个（对象, 轮次）。
- 意见记录 `opinions.tsv`：1670 行。
- Claude Code 会话转录：25 个主会话提到 codev，其中 14 个真正调用了库函数（13 个在 ntms 及其 worktree，1 个是 09-11 的 MySkill 自审）。
- claude-mem 记忆（约 150 条观察 + 5 条 ntms 记忆笔记）；09-24/25 记忆无观察，靠账本补。
- ntms 归档 `.superpowers/codev/<slug>/r<N>/` 的 stderr。

统计脚本与两份原始扫描报告在本次会话 scratchpad（`agg.py` / `transcript-audit.md` / `mem-audit.md`），不进仓库。

## 2. 使用概况

| 项 | 数 |
|---|---:|
| 使用天数 | 11（09-18/19 无活动） |
| 会话目录 | 43 |
| 评审对象 | 26（全部 ntms） |
| 模式 | review / 文档评审（含 `--auto`）为主，brainstorm 2 次；challenge / consult 0 次 |
| 每对象轮次 | 1-3 轮 17 个；4-5 轮 5 个；waybill 计划从第 5 轮到第 14 轮 |

按 agent 的调用与结果：

| agent | 调用 | ok | 失败类别 | ok 用时中位 | tokens 中位 | 成本 |
|---|---:|---:|---|---:|---:|---|
| codex | 90 | 82 | quota 8 | 214s | 83k | - |
| self（G2） | 80 | 73 | empty 6、error 1 | 775s | 174k | - |
| codebuddy | 56 | 49 | timeout 6（1200-1800s）、error 1 | 350s | 627k | 0 |
| reasonix | 39 | 33 | timeout 3、error 3 | 719s | 2.97M | 82.5 CNY（超时也计费） |
| check（G1） | 15 | 14 | empty 1 | 762s | 151k | - |
| pi（未登记） | 14 | 13 | timeout 1（6904s） | 777s | - | - |
| gemini | 7 | 3 | error 2、timeout 2（全是 503） | 212s | - | - |
| qoderclicn | 1 | 0 | quota 1 | | | |

发现台账：1642 条里 self 566、codex 417、check 302、codebuddy 148、reasonix 125、pi 56、post-self 15、gemini 13。声称 P1 403 条，亲验成立 390。意见记录里 `未返回` 168 条（codex 50、codebuddy 47、self 31）。

## 3. 问题清单（34 项，按类别）

标记：**已回流** = 本次改了库或文案；**待验** = 改了但未真机验证；**未处理** = 只记录。

### 3.1 外部 CLI 故障

1. gemini 503 过载，7 次调用 4 败；且 `-m gemini-2.5-pro` 已下线（09-23）。旧版记 error/timeout，账本看不出过载。**已回流**：503/529/overloaded 归 `quota`（额度/限流/过载）；agents.md 去掉钉型号建议。
2. codex 额度耗尽 8 次（4 个会话），一次"第三次撞同一个 2:15 PM 窗口"。库分类正确；用户偏好等重置而非换家。**已回流**：§6.3 只在判断组成员额度耗尽时停整轮。
3. codebuddy 1200-1800s 超时零输出 6 次，提示词已在 4-11KB、清单已收窄；两次导致 `--auto` 因有效外部 < 2 提前停。**未处理**（CLI 侧）；agents.md 记基线，N ≥ 2 轮默认不用它。
4. reasonix：431KB 计划 `read_file … bounded reader cannot establish one source version` 两次废；1200s 超时各 4.4-4.6 CNY；`--max-steps` 非零退出把完整评审判无效。**已回流**：agents.md 行号区间做法 + 成本数据；A1 默认第 N ≥ 2 轮不放它。
5. self / check 子 agent `API Error 529 Overloaded`（596s 零输出）。**已回流**：归 `quota`，SKILL 要求隔几分钟重试一次、再败标"本轮无 self 样本"。
6. qoderclicn 额度死透（09-14 起每次探测都 quota），opencode 从未被用。**未处理**（探测已显示近期 quota）。
7. pi 一次 `CODEV_TIMEOUT=1800` 跑了 6904s（rc=124），安全网没兜住，原因未查明。**待验**：agents.md 记录并要求 Monitor + 手动 kill。

### 3.2 库缺陷 / 库 UX

8. 母本 ≠ 已扫描版本时 `codev_repo_copy` 拒发，但 `codev_bg_sandboxed` 退回空目录继续启动、翻牌 ✔——09-15 一整轮 codebuddy + pi 白跑。**已回流**：`codev_repo_copy` 返回 2，`codev_bg_sandboxed` 打 `⛔ 未启动`、不写账本；其它退化（超闸门/非 git）写标记，✔ 后追加警告、账本备注 `退化:空目录`。
9. codex 回显到 stderr 的带行号源码被 `codev_err_lines` 当错误行，7 个会话 35 次假警告。**已回流**：三位状态码只认 4xx/5xx 且其后为文字。
10. `self`/`check` 先 `codev_report` 后落盘 → 6 行假 empty，一次手工 awk 改账本，Claude 自述"第三次犯同一个流程错误"。**已回流**：有 `CODEV_TOKENS_<agent>` 却无正文即拒绝记账并提示。
11. 账本模型列：codebuddy 写成 codebuddy-default / default / unknown 三桶。**已回流**：`default` 归一为 `<agent>-default`；agents.md 固定写法。
12. 台账轮次写成 `r10..r14`（153 行）与数字并存；agent 列混入模型名/"实跑/推演"（10 行）。**已回流**：`codev_key_round` / `codev_key_agent` 收口，写入实参数量与枚举校验不变。
13. 同一份计划用 4 个 doc 名记账（路径 / 主名 / `plan-` 前缀 / 带 `.md`），按对象统计与回放全散。**已回流**：SKILL 2F 绑定 `SLUG` 并在 finding/opinion/archive/`CODEV_TASK_ID` 四处沿用；库层未强制。
14. G1 `check` 只有 15 行进调用账本，发现台账却有 302 条——每轮最大的一笔 Claude 开销隐形。**已回流**：SKILL G1 补收尾片段。
15. 账本会话列出现 4 行 "codev"（worktree 会话用固定目录绕守卫）。**已回流**：source 时告警 + SKILL 要求 mktemp。
16. 提示词体积每轮手写 `wc -c` 比较（4 个会话各一版）。**已回流**：`codev_prompt_gate`。
17. secret 扫描副本模式噪音高，每个会话现写不同的聚合脚本。**已回流**：`codev_scan_triage`（按文件聚合 + 高置信形态）。
18. `codev_archive` 在 self 补报之前被调用，同轮内容不同拒绝覆盖（2 次）。**已回流**：SKILL 2F 要求全部 report 完再归档。
19. `codev_opinion_add` 11 实参/`codev_archive` 非数字轮次的用法错误 10 次。**部分**：轮次 `rN` 现可接受；实参个数保持严格（有意）。
20. gemini / pi 没有计量，账本 tokens 恒 `-`。**未处理**（pi `--mode json` 未实测）。

### 3.3 编排器（Claude）错误

21. zsh `echo =====` 被当 `=cmd` 展开报错 15 次（8 个会话）；`VAR=x cmd` 前缀赋值后下一行 `$VAR` 为空导致根目录 glob；一次未设 `CODEV_DIR` 就 source。**已回流**：SKILL Step 0 记三个新坑。
22. worktree 隔离会话下宿主拒绝 `source`/复合命令 19 次（4 个会话），每个会话重新摸索"写脚本文件再 bash"。**已回流**：SKILL Step 0 固定做法。
23. brainstorm 回流手写 `git commit` 参数顺序错、changelog 未成对提交。**已回流**：2A 第 5 步要求走 `codev_commit_round`。
24. 3 个会话没有逐字呈现外部原文（只给路径）。**未处理**（铁律已有，用户未抱怨）。
25. 收尾 `rm -rf` 之后仍引用会话目录（5 个会话，无害）。**未处理**。

### 3.4 多轮协议

26. waybill 计划跨会话从第 5 轮磨到第 14 轮；mobile-architecture 5 轮 P1 24→11→7→11→8 不收敛。synthesis §6 的"第 5 轮仍有 P1 → 停下看范围"没被执行，因为每个新会话只看到自己那几轮。**已回流**：`codev_round_trend` + §6 第 0 步。
27. 四个会话 `--auto` 到上限时末轮 P1=0 却记"停止未收敛"，用户随后来问"到底收敛没"。**已回流**：§6.3 条件 5 区分"到达上限·末轮无 P1（待复核）"。
28. 最后一轮回流没人审；P1 反复出在上一轮新写的段落。**已回流**：停止后补一次只跑 G1 的末轮自查。
29. 收敛按全局判，其实按章节：连续两轮只产 P3 的章节仍被整轮重扫。**已回流**：§6 收敛判据加"按章节收敛"。
30. 一家 qoderclicn 额度耗尽就停了整个 `--auto`。**已回流**：§6.3 条件 3 改写。
31. 两判断者协议下 codex 缺席即 P1 门禁卡住；`未返回` 168 条。**未处理**（用户偏好等 codex 重置）。

### 3.5 用户摩擦

32. 用户三次绕开 codev 自己跑 codex 再贴回 127 行结果让 Claude 确认；单会话最多弹 12 次 A1，回答几乎都是 "A"/"继续"。**已回流**：Step 1 轻量单家复审 + 同会话沿用已确认组合。
33. 等待期间用户反复问"reasonix 回来了吗 / codex 回来了吗"；self 单轮 1300-3000s。**已回流**：通用机制 C 给各 agent 预期用时（账本中位数），要求发出时告知。
34. 项目里的 skill 目录是 Finder 别名，`/codev` 加载失败，用户要求换符号链接。**已在项目侧修复**（09-13）。

## 4. 本次改动汇总

库（`bin/codev-lib.sh`，回归 255 → 302 项，bash/zsh 皆绿）：
- 分类：503/529/过载归 `quota`；错误行抽取新增 `API Error` / `status: 5xx` / `"code": 5xx`，三位码只认 4xx/5xx。
- 守卫：self/check 漏落盘拒绝记账；钉子不匹配 `⛔ 未启动`；退化空目录 ✔ 后警告 + 账本备注；会话目录名告警。
- 收口：`codev_key_round`、`codev_key_agent`、`default` 模型名归一。
- 新函数：`codev_round_trend`、`codev_prompt_gate`、`codev_scan_triage`；`codev_probe` 探测 `pi`。

文案：SKILL.md（Step 0 worktree/zsh、Step 1 轻量单家复审与沿用组合、A1 按轮次分档、C 预期用时与 ⛔ 未启动、G1 记账、G2 顺序、F 列规则、2A 提交、2F `SLUG`）、synthesis.md §6（第 0 步趋势、按章节收敛、停止条件 3/5、停止后补 G1）、agents.md（pi 条目与风险表、gemini/reasonix/codebuddy 实测、函数表）、README / prompts / TESTING / CHANGELOG 同步。

## 5. 未验证与遗留

- 本轮没有跑真实外部模型流程；`⛔ 未启动`、self 漏落盘拦截、pi 调用形态、轻量单家复审都待下次真机验。
- pi 的 6904s 超时未查明根因；pi 计量未实测。
- codebuddy 超时与 reasonix 大文件读取是 CLI 侧限制，只能靠选型规避。
- 提示词生成器（各会话手工拼装边界/任务/diff/回归段）没做，仍靠 prompts.md 模板。
- 两判断者协议下判断者缺席的替代机制没做。
