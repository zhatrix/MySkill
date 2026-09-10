# codev 使用审计：2026-09-05 至 2026-09-10

结论：token 增加同时来自更多评审调用、越来越大的文档和上下文、后期更多模型请求；现有账本又混用了不同 token 口径，放大了跨模型比较的误差。最近评审不能收敛，已确认存在回流漏改、错误建议被写入、同一契约多处定义不一致，以及修改后缺少本轮闭环验证。仍有真实的首次发现，不能把后期所有 P1 都归因于回流。

本次仅检查记录和实现，未修改 skill 的运行规则或 ntms 文档。以下时间均为北京时间；会话记录核对截至 9 月 10 日 20:39。统计排除本次 Codex 审计自身。

## 1. 范围与口径

交叉核对了以下来源：

- [调用账本](/Users/zenyu/.local/state/codev/ledger.tsv)：有调用时间、会话目录、agent、模型、状态、用时、提示词字节、输出字节、tokens、成本。
- [发现台账](/Users/zenyu/.local/state/codev/findings.tsv)：当前版本，包含今天补录的第 9 轮及清理后的中文枚举。
- [ntms 评审归档](/Users/zenyu/Project/Tms/ntms/.superpowers/codev/waybill-create-pricing-integrity)：r1–r8 的提示词、输出、stderr、reasonix metrics。
- [Claude 主会话](/Users/zenyu/.claude/projects/-Users-zenyu-Project-Tms-ntms/89c66408-dcb1-468c-9532-70d6ee5729c8.jsonl)及同名目录下的 subagents 日志。
- Codex stderr 中的 session id 对应的本地 rollout；取最后一个 `total_token_usage`，不逐行累加累计值。
- MySkill 与 ntms 的 Git 提交及各版 spec。

Claude usage 按 assistant message id 去重，同一消息的流式片段对各计数字段取最大值，再跨消息求和。读取 `input_tokens`、`cache_creation_input_tokens`、`cache_read_input_tokens`、`output_tokens`；不把子代理通知再加一次，不把 token 预算提醒当成消耗。

这些是客户端记录的用量，不能直接换算为订阅额度或实际账单。Claude、Codex、reasonix 的 tokenizer、缓存及计费口径不同。OpenAI 的 usage 结构也明确区分 input、cached input 和 output：[官方 usage 说明](https://developers.openai.com/api/reference/cli/resources/responses/methods/retrieve)。

## 2. 9 月 5 日至今的可归属记录

用 ntms 主项目及其工作树 Claude 会话中出现的 codev 会话目录名匹配调用账本，得到 123 条调用记录。对应 31 轮外审；G1 没有完整进入调用账本，因此不是全部模型调用数。

| 日期 | 可归属 ntms 的账本记录 | 主要评审对象 |
|---|---:|---|
| 09-05 | 0 | 当天全局账本另有 13 条；本次未匹配为 ntms 调用，不能据此断言 ntms 当天完全没使用 |
| 09-06 | 38 | freight-receipt-writeback、放款方式设计 |
| 09-07 | 24 | 放款方式设计及实施计划 |
| 09-08 | 4 | 集成门禁耗时分析 |
| 09-09 | 12 | 集成门禁耗时分析、套餐目录 v2 spec |
| 09-10 | 45 | 套餐目录 v2 plan、开单计费一致性 spec |

123 条中，codex 31、reasonix 30、codebuddy 31、self 31；状态为 ok 117、quota 5、error 1。仅 60 条有 token 数字：codex 30 条、reasonix 30 条。codebuddy/self 共 62 条用量缺失，codex 还有 1 条缺失；G1 另有未记账调用。

因此不能把账本的缺失值 `-` 当成零，更不能把已有成本相加后称为整个流程的成本。

## 3. 最近“9 轮”的实际构成

对象是 [开单计费一致性 spec](/Users/zenyu/Project/Tms/ntms/docs/superpowers/specs/2026-09-10-waybill-create-pricing-integrity-design.md)。实际完成了 **8 轮外审 + 第 9 轮 G1**。9 月 10 日 19:23 用户转向检查 skill，因此第 9 轮外审没有启动。

| 轮次 | G1 台账 P1 | 外审综合/提交声明 P1 | 状态 |
|---|---:|---:|---|
| 1 | 4 | 11 | 已回流 |
| 2 | 3 | 9 | 已回流 |
| 3 | 1 | 3 | 已回流；本次 auto 批次结束 |
| 4 | 2 | 3 | 已回流 |
| 5 | 0 | 3 | 已回流；self 无有效结论，但已产生用量 |
| 6 | 3 | 5 | 已回流 |
| 7 | 4 | 4 | 已回流；台账外审 P1 只有 3 条，存在记录不一致 |
| 8 | 3 | 4 | 已回流 |
| 9 | 6 | — | 仅 G1，回流为 v3.2 |

两列不能相加当成独立缺陷总量：G1/外审看不同版本，多家发现有重叠，跨轮也有同一问题重现。前一轮 G1 发现的问题也不自动等于“前一轮才引入”，需要逐项比较旧版本。

用户在 10:29、12:25、16:23、18:18 分别启动 auto 批次，轮数参数为 3、2、2、5。超过五轮是多个用户启动的批次累计，不能说成 skill 未经授权自行连跑九轮。但同一对象的累计轮数与返工趋势没有触发有效的流程调整。

这组工作共启动 24 次外部评审（8×3）和 17 次 Claude 自查/自评（9 次 G1、8 次 G2），合计 **41 次评审代理调用**，还不包括主 Claude 的核实、改文档、综合和原文呈现。

## 4. token 增加的原因

### 4.1 版本变化确实增加了固定工作量

Git 历史明确区分了两次变化：

- 08-05，`9772771`：沙盒从只有提示词的空目录改为有仓库副本，外部模型能够读更多代码。
- 09-04，`9b0fa28`：加入自动多轮、fresh-subagent 自查等机制。
- 09-05 20:29，`5d05091`：加入机制 G，G1 每轮自查、G2 与外审并行自评成为固定流程。

用户本次指定的窗口是 09-05 至今天。这个窗口能够解释新版的工作构成，不能据此定量证明“相对 08-05 前上升十倍”。日志中之前那份分析把几次变化混在一起，并给出十倍量级判断，没有同任务、同模型、同口径的前后对照支持。

### 4.2 跨工具的账本 token 不能直接比

[codev_tokens 实现](/Users/zenyu/Project/MySkill/codev/bin/codev-lib.sh:211)对 codex 取 stderr 的 `tokens used`，对 reasonix 取 `prompt_tokens + completion_tokens`。

对有完整 rollout 的七轮逐一核对，codex 的打印值恰好等于 `total_tokens - cached_input_tokens`。reasonix 的打印值包含缓存命中。以第 8 轮为例：

| 第 8 轮 | 账本 tokens | 含缓存的累计 tokens | 缓存命中 | 扣除缓存命中后的余量 |
|---|---:|---:|---:|---:|
| codex | 107,675 | 804,635 | 696,960 | 107,675 |
| reasonix | 987,125 | 987,125 | 888,576 | 98,549 |

直接看账本像 reasonix 是 codex 的 9.17 倍；统一为含缓存累计口径则是约 1.23 倍。统一扣除缓存后，reasonix 反而略低。两者仍不能据此比较金额，但足以否定原来的直接倍数归因。

证据：[codex r8 rollout](/Users/zenyu/.codex/sessions/2026/09/10/rollout-2026-09-10T18-39-28-01a08ae6-ac4c-7690-bf21-a03e9ea85319.jsonl:91)、[reasonix r8 metrics](/Users/zenyu/Project/Tms/ntms/.superpowers/codev/waybill-create-pricing-integrity/r8/codev-metrics-reasonix.json:1)。

另一个异常值是套餐目录计划第 2 轮：reasonix 9,781,600 tokens，83 steps，其中缓存命中 9,568,000（97.8%），输出 72,605。metrics 中估算成本为 3.049845 CNY。它说明长工具循环反复携带上下文，不能表述为“读了近千万 token 的新代码”或“几乎全是推理”。[原始 metrics](/Users/zenyu/Project/Tms/ntms/.superpowers/codev/plan-pricing-v2-plan/r2/codev-metrics-reasonix.json:1)

### 4.3 Claude 的实际负担原来大部分没进账

本组 17 个 G1/G2 子代理，共 595 个去重模型消息：

| 字段 | tokens |
|---|---:|
| 非缓存输入 | 7,068 |
| 缓存创建输入 | 2,689,437 |
| 缓存读取输入 | 67,853,463 |
| 输出 | 476,214 |
| 含缓存累计 | **71,026,182** |

其中 95.5% 是缓存读取；扣除缓存读取后的余量为 3,172,719。这不是 7,103 万个不同 token，也不是 7,103 万个全价输入 token。

主 Claude 在 codev 开始到转向流程审计前（10:29–19:23），还有 335 个模型消息、159,332,973 含缓存累计 tokens，其中 155,781,870 是缓存读取（97.8%）。这一窗口包含外审等待、逐条核实、输出呈现、回流及期间用户指令，不能全部归为纯评审；但它清楚显示，只看外部 agent 的账本会漏掉很大一块工作量。

### 4.4 后期调用更长，文档也越来越大

| Claude G1/G2 阶段 | 调用数 | 模型消息数 | 平均每调用消息数 | 平均每调用含缓存 tokens |
|---|---:|---:|---:|---:|
| r1–r5（日志模型为 claude-fable-5-1，r5 G2 中途失败） | 10 | 207 | 20.7 | 2,046,167 |
| r6–r8（日志模型为 claude-opus-5） | 6 | 341 | 56.8 | 7,545,953 |

平均消息数为原来的 2.75 倍，平均含缓存 tokens 为 3.69 倍。扣除缓存读取后的平均余量只增加约 36%，所以后期大数字主要表现为更多请求反复读取上下文。模型切换、核实任务加重和文档变大同时发生，不能把全部差异单独归因于某个模型。

spec 从第一次外审前 v1.5 的 **51,850 字节**，增至第 9 轮 G1 后 v3.2 的 **176,802 字节**（3.41 倍）。文档夹带了长修订历史、原问题诊断、当前契约、旧说法的反驳和大量精确行号。每轮多个模型重读，主会话还重复接收评审原文及工具结果，形成上下文负担。

## 5. 回流反复出现的原因

### 5.1 修改过程持续留下旧契约

主会话中检出 37 条涉及该 spec 且包含 `.replace()` 的编辑命令、67 个 `.replace()` 表达式。使用替换本身不必然错误；问题在于它与版本差异中的漏改证据相互印证，而 skill 明确要求受影响段落整段重写、概念全文同步。

可复核的例子：

| 修改链 | 实际问题 | 证据 |
|---|---|---|
| r5 → r6 G1 | 新增三态返回契约后，提交步骤仍按 null 处理 | `r6-check-01`；提交 `84a7b7c20` |
| r6 → r7 G1 | blocked 只加进括号说明，联合类型和分支仍是旧版 | `r7-check-02`；提交 `341aff56c` |
| r7/用户拍板 → r8 G1 | §15 旧尾巴仍说只授权 hq_admin，推翻已确认的 hq_ops 授权 | `r8-check-01`；提交 `94d847296` |
| r8 → r9 G1 | dual_key_fix 改为 `{fingerprint, fixes}`，同节两处仍要求旧数组结构 | `r9-check-01`；提交 `9ca5be0a0` |
| r8 → r9 G1 | SQL 约束从四条变五条，标题与 §12 的序号引用未同步 | `r9-check-02/03` |

而且 **r9 仍未完全消除重复定义**：当前文档第 304 行的 hook 联合类型仍是 `{kind: "error"}`，第 308 行却要求 hook error 从源头带 `err`。这直接说明“已修”描述与最终文本之间仍缺少验证。[当前 spec](/Users/zenyu/Project/Tms/ntms/docs/superpowers/specs/2026-09-10-waybill-create-pricing-integrity-design.md:304)

### 5.2 低严重度建议也能把错误带进下一版

r8 的 `r8-self-11` 被当作 P2 采纳，写入“可达性面板应显示暂无预估”和测试改法。r9 核对后发现：开单页并不渲染该外转预估金额；被引用测试使用 legacy mode，且请求包含重量，原推导不成立。这随后成为 `r9-check-05/06` 两条 P1。

[synthesis 0.6](/Users/zenyu/Project/MySkill/codev/references/synthesis.md:46)对拟采纳 P1 强制亲验，但对所有拟写入的新事实、P2/P3 建议缺少同样明确的落笔验证。只验证“被标为 P1 的发现”无法防止 P2 建议在回流中制造 P1。

### 5.3 同一轮没有把最终修改闭环

现行顺序是 G1 → 外审/G2 → 综合 → 回流 → commit → 判停。回流后的新文本要等下一轮 G1 才独立检查；G1 的修复又会产生新文本。达到 auto 上限时，最后的回流版本没有强制的独立验收。

这解释了为什么加轮数会“发现问题”，却不一定降低剩余缺陷：下一轮不断承担上一轮修改的验收成本。r9 只做 G1 就发现六条 P1，是直接证据。[当前流程](/Users/zenyu/Project/MySkill/codev/references/synthesis.md:185)

### 5.4 回归输入不够完整，范围又不断展开

r3、r4 codex 原文明确说，一批上一轮条目只给编号，没有问题描述与验收条件，无法逐 ID 判定是否修复。这不符合逐条回归的实际需要。[r3 输出](/Users/zenyu/Project/Tms/ntms/.superpowers/codev/waybill-create-pricing-integrity/r3/codev-out-codex.txt)、[r4 输出](/Users/zenyu/Project/Tms/ntms/.superpowers/codev/waybill-create-pricing-integrity/r4/codev-out-codex.txt)

评审对象原本就整合七个 issue，涉及计费、历史迁移、编辑、错误处理与权限。后期又深入全局 422/OpenAPI、跨模块测试、原子版本更新、迁移角色与 RLS，单个核实项会展开成很多读文件步骤。没有稳定的契约清单和依赖范围，模型便逐轮补充边缘路径，进一步放大文档。

不能据此说“方案早已完全稳定”。r8 的迁移 RLS 前提，以及先 SELECT 再 flush 的乐观锁问题，仍是需要处理的实质发现。不能把 G1 的来源标签当作缺陷成因，也不能沿用先前会话的“94%”或“73% 都是回流”结论。

### 5.5 库的默认 diff 基线还有一个独立缺陷

[codev_prev_round_commit](/Users/zenyu/Project/MySkill/codev/bin/codev-lib.sh:407)找的是上一轮回流提交，SKILL 却让 G1 对它执行 `git diff "$PREV" -- "$DOC"`。若上一轮已经提交且没有新改动，该 diff 是空的，无法呈现上一轮回流本身。

复现：在 r8 回流提交 `d4596c3ee`，`git diff d4596c3ee d4596c3ee -- <DOC>` 为 0 字节；真正的回流范围 `94d847296..d4596c3ee` 为 123,628 字节。最近这组 G1 提示词手工指定了前后两个正确版本，因此它是潜在流程缺陷，不能冒充本组返工的已证实原因。

## 6. 今天已经修了什么，还没修什么

20:14 的 `ad919c1` 增加 self 用量环境变量回填、codebuddy JSON 用量提取；20:17 的 `553cacf` 增加发现台账中文枚举校验。当前 findings 已有 r9 的 15 条记录，所以早先分析里“第九轮完全没记账”的状态已经过时。

这些修改没有统一跨工具缓存口径，没有回补历史缺失用量，也没有解决回流后的验收位置。G2 增加了用量示例，G1 仍缺少同等完整的调用计量收尾；主编排会话用量也未纳入。当前 codebuddy 归一化还仅取 input/output，是否包含其缓存字段需按实际返回 schema 单独核对。

## 7. 建议调整的先后顺序

1. **先补回流验收，而不是再开全量外审。** 保存评审前版本与回流后版本；对本次接受项逐条检查最终 diff、概念全文引用、新写入事实及测试/迁移示例。验收失败在当前轮修复，最后一轮也必须执行。验收者只看变更和关联契约，避免再读全仓。
2. **给缺陷稳定身份。** 每项记录原问题、证据、预期结果、修复位置、验收结果，增加 `existing / introduced / reopened / scope-added` 成因；G1/G2/外审只作为发现来源。按独立问题计数，保留跨模型来源关系，统一文档 slug 和轮次编号。
3. **收缩并规范文档。** 修订史放归档；每个状态机、错误联合、审计键结构只保留一份权威定义。其它章节引用它；对长段落整段改写，避免把旧诊断和新规范拼接在一起。固定两个快照来计算真实回流 diff。
4. **按风险分配评审。** 首轮允许全量交叉核对，后续聚焦改变的契约及依赖路径；避免每轮三个外部模型加 G1/G2 全部重复扫。reasonix/codebuddy 在本组台账中没有独家成立 P1，但有 P2/P3 贡献；这是调整它们关注面的理由，不能推出停用后检出率必然不变，更不能说成本归零。
5. **统一计量，再定预算。** 各调用记录 input、cache read、cache write、output、模型请求次数、成本币种、是否估算、失败状态和缺失原因；G1/G2/主编排全部覆盖。预算按累计任务而非新 auto 批次重置，达到上限进入范围/返工诊断。

优先级最高的是回流验收和单一契约定义：它们同时减少返工轮数与重复读取。单独换便宜模型或取消某家外审，不能消除已经证实的修改质量问题。
