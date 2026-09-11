# codev — 使用文档

多 agent 协作开发编排器。让 Claude Code 在开发关键节点，把方案或代码交给**其它 agent CLI**
（codex / gemini / reasonix / qoderclicn / opencode / codebuddy，各自背后是不同大模型）做独立的
头脑风暴、代码评审、对抗挑战，再由 Claude 做**跨模型综合**。核心信念：不同模型的盲区不同，
交叉验证能显著减少 bug 与遗漏。

> 本文件面向**使用者**。`SKILL.md` 是给 Claude 执行的规范，`references/` 是调用细节，日常无需翻。

---

## 1. 它能帮你做什么

| 你想要 | 用法 |
|---|---|
| 让多个模型给同一需求出方案，交叉取优 | `/codev brainstorm <需求>` |
| 让多个模型评审你的代码改动 | `/codev review [关注点]` |
| 让模型扮演攻击者，尽力打破你的代码/方案 | `/codev challenge [焦点]` |
| 把一个技术问题问多个模型，汇总观点 | `/codev consult <问题>` |
| 让多个模型评审一份 spec / 实施计划 / 方案文档（无 diff） | `/codev review docs/xxx.md [关注点]` |
| 第 N 轮评审（带上一轮回归核对 + 两版 diff + fresh-subagent 自审） | `/codev review docs/xxx.md --round 3` |
| 自动连跑多轮直到收敛（开始只问一次，每轮自动 commit） | `/codev review docs/xxx.md --auto --max-rounds 3` |
| 指定 agent 组合、不再弹窗确认 | `… --agents codex,reasonix` |
| 从设计到编码到评审走完整流程 | `/codev <一段需求描述>` |
| 不带参数，让它看你当前改动、问你要干嘛 | `/codev` |

**铁律（安全保障，始终生效）**
- Claude 是**唯一改文件的人**。外部 agent 一律**只读**运行，只输出方案/评审/质疑。
- 发给外部模型前会做 **secret 扫描**，命中疑似密钥会停下让你确认或脱敏。
- fan-out（并行调多个外部 agent）前会用弹窗让你**确认调用哪些**（消耗各自账号额度）；显式 `--agents` 跳过确认，
  `--auto` 多轮只在开始问一次。Claude 自己的 `self` 不耗额度、不在弹窗里。
- 外部 agent 的输出**逐字呈现**，不总结、不裁剪，清楚标注来源与模型。

---

## 2. 前置准备

### 2.1 装 / 登录外部 agent CLI（按需，装几个用几个）
这些是第三方 CLI，skill 不代装。至少装 1 个才有意义，**建议 3 个以上**才有交叉验证价值。

| agent | 背后模型 | 安装后 |
|---|---|---|
| `codex` | OpenAI GPT | `codex login` 或设 `$OPENAI_API_KEY`/`$CODEX_API_KEY` |
| `gemini` | Google Gemini | 首次交互登录 或 `$GEMINI_API_KEY` |
| `reasonix` | DeepSeek | `reasonix setup` 配 key |
| `qoderclicn` | Qoder | 账号交互登录 |
| `opencode` | 多供应商 | `opencode auth` 配 providers |
| `codebuddy` | 腾讯（Claude Code 分支） | 交互登录 |

### 2.2 装 `timeout`（强烈建议）
macOS 原生没有 `timeout`。**不装后台慢模型无兜底会永久挂起**，skill 会自动跳过它们。
```bash
brew install coreutils      # 提供 gtimeout
```
装完 `/codev` 的探测会显示 `timeout -> /opt/homebrew/bin/gtimeout`（或已把 gnubin 加进 PATH 时的 `…/timeout`）。

### 2.3 超时与账本
- `CODEV_TIMEOUT`（默认 600s）：单次 agent 调用的兜底超时。核实型评审、大文档评审建议 `export CODEV_TIMEOUT=1200`。
- 近期结果账本 `~/.local/state/codev/ledger.tsv`：每次调用记一行类别（ok/quota/auth/turns/timeout/empty/error）。
  `/codev` 探测时会给每个 agent 标"近期 3 次结果"，连续额度耗尽的 agent 不会被推荐。设 `CODEV_LEDGER` 可改路径。
- 发现台账 `~/.local/state/codev/findings.tsv`：每条外部发现的裁决与亲验结果；`codev_stats` 看每个 agent/模型的
  "声称 P1 里亲验成立的比例"和"独家成立"数（这是选模型的依据，不是采纳条数）。
- 意见与判断记录 `~/.local/state/codev/opinions.tsv`：每个 agent 对每个问题的**每一条立场**单独一行（谁提出、谁采纳、
  谁存疑、各自给的级别和修法）。`codev_opinions <问题编号>` 事后回放某条当时各方原话立场，并判出判断组是否达成一致；
  不带参数放全部；可用 `codev_opinions <问题编号> <仓库> <对象> <轮次> <task>` 精确筛选（空参数表示不过滤）。
  记录按仓库/对象/轮次/task/问题隔离，历史全部展示，计票只取各判断主体最后追加的记录；P1 级别分歧或缺少具体修法不进入执行清单。
  设 `CODEV_TASK_ID` 标识任务，跨会话恢复须沿用该值；未设置时取 `CODEV_DIR` 会话名。新记录追加 task 为第 13 列，旧 12 列仍可读并提示身份限制，补齐任务归属前仅供回顾，不据此执行或关闭问题。
  跨会话累积，设 `CODEV_OPINIONS` 可改路径。
  三个账本使用 Python 3 文件锁串行追加完整行，读取时在共享锁内取得完整副本，避免半行影响统计或判断。
  读取失败返回非零；意见文件存在损坏行时，回放不据此执行或关闭问题；写入接口拒绝空白主体和问题编号。
- 账本读写、结构化结果处理和归档需要 Python 3。结构化结果先保存计量与状态，再替换正文；解析器或存储故障会明确报错并保留原文，修复故障后可重试 `codev_report`。
- 每轮回流 commit 只提交显式列出的文件（含对应 changelog），所有 Git 路径按字面解释，不把 `*` 或 pathspec magic 展开为额外文件；trailer 带 `Codev-Round` / `Codev-Reviewed-By: codex(gpt-5.6-sol), …` /
  `Codev-Verified-P1: k (prev j)`，`git log --grep '^Codev-Round: 2'` 可直接查；评审原文归档到 gitignored 的
  `.superpowers/codev/<文档>/r<N>/`，不进仓库；归档成功后不被不同内容覆盖，相同内容可重复归档。
- 改了 `bin/codev-lib.sh` 后 `bash tests/test-lib.sh` 与 `zsh tests/test-lib.sh` 两边都要绿；改文案按 `TESTING.md` 跑微测试与真机清单。

### 2.4 shell 说明
skill 已对 **zsh** 做过兼容（用 `codev_run` 函数封装超时，而非 `$TP` 变量前缀——后者在 zsh 下会失败）。
bash/zsh 都能正常跑。

---

## 3. 五种模式详解

### brainstorm — 头脑风暴 / 方案设计
```
/codev brainstorm 给订单模块加一个幂等的支付回调
```
流程：Claude 先出 v0 方案 → 各 agent 独立出自己的方案并挑 v0 的刺 → 综合成
**取舍表 + 风险清单 + 推荐方案**，可选写入 `docs/方案-<主题>.md`。

### review — 多 agent 代码评审
```
/codev review                 # 评审当前全部改动
/codev review 并发安全和错误处理   # 带关注点
```
流程：自动定 base（`@{u}` → `origin/HEAD` → `main`… 回退链，会验证 commit 存在）
→ **Claude 自查**（不带对话上下文的 subagent 先过一遍，明显问题先修）→ 组提示词 → **secret 扫描**（扫的是修完之后的版本）
→ 外部 agent 与 **Claude 自评**（同一份提示词、另一个 fresh subagent，标签 `self`）并行评审 → **事实核查回填**（把 agent 标注的"需核实假设"逐条查证）→ 综合出
**一致性矩阵 + PASS/FAIL 门禁**（出现 P1/critical 即 FAIL）→ 问你要不要让 Claude 修复确认的问题。

- codex 用原生 `codex review`（只读，从仓库根跑，自己跑 `git diff`）。
- 其余 agent 在**隔离沙盒**里跑：cwd 不是真仓库，但沙盒里有一份 `./repo` —— 工作区（含未提交
  改动）的**只读副本**。它们能读全部代码来核实跨文件问题，写入默认只落在副本上、用完即删。
  这是 cwd 隔离 + 副本与母本 `chmod -R a-w`，**不是 OS 级沙盒**：防误写，防不了同用户进程刻意枚举 `$TMPDIR`
  再改回权限的恶意 agent。仓库敏感要做两件事：设 `CODEV_SANDBOX_MODE=text` 让四个沙盒 agent 只拿提示词文本，
  **并用 `--agents` 排除 codex/gemini**——它们在真实仓库里跑，只读旗标只挡写不挡读，`.gitignore` 掉的文件照样读得到，
  text 模式对它们不起作用。

### challenge — 对抗式挑战
（和 review、文档评审一样，Claude 先自查、再与外部 agent 并行自评，见 SKILL 通用机制 G。）
```
/codev challenge lib/auth/token.dart
```
让 agent 扮演攻击者，专找会让代码崩的输入、边界、并发/竞态、错误处理缺失、隐含假设。
产出**攻击面清单**，标注哪些是真问题、哪些已被现有代码处理。

### consult — 咨询汇总
```
/codev consult Riverpod 的 ref.watch 和 ref.read 在什么场景会踩坑
```
把问题转述给多个模型，给出各家观点 + Claude 的收敛结论。

### 全流程（默认）
```
/codev 实现一个带重试和退避的 HTTP 客户端封装
```
brainstorm → 编码 → review → 小结，**每个阶段之间会停下等你确认**，不会一口气冲到底。

---

## 4. 两种分工模式（每次 fan-out 前会问你）

| 模式 | 说明 | 何时用 |
|---|---|---|
| **全量模式**（默认） | 每个 agent 都看**全部内容**，重叠覆盖最能暴露盲区；综合出一致性矩阵（都发现/多数/仅 1） | 想要最强交叉验证、内容不大时 |
| **分工模式** | 每个 agent 只看**自己那一面**（如 codex→架构/数据库、reasonix→UI/交互、opencode→其余）；省额度、快，但无交叉验证 | 改动大、想省 token、每块只需一个模型看时 |

> 参与 agent **< 3 个时分工收益不大**，会直接建议全量。

---

## 5. 运行时你会看到什么

1. **启动状态板**：每个 agent 一行 `▶ codex（模型 GPT）｜ 范围：全量 ｜ 强度 medium ｜ 运行中…`
2. **完成翻牌**：`✔ codex 完成` / `⏭ reasonix 跳过（超时）`
3. **逐字呈现**：每个 agent 的原始输出用分隔框原样展示，不删改：
   ```
   ━━━ CODEX（模型：GPT）━━━━━━━━━━━━━━━
   <原始输出>
   ━━━━━━━━━━━━━━━━━ tokens: … ｜ 用时: …s
   ```
4. **跨模型综合**：一致性矩阵 + Claude 裁决（采纳/存疑/驳回）+（review 模式）PASS/FAIL。

慢模型默认**后台执行**（不受前台超时限制），跑完通知，所以你不会看到它"卡住"。

---

## 6. 推理强度

默认一律 `medium`（**高强度 + 大提示词是超时主因**）。仅复杂任务或你要更深时升 `high`。
输入里带 `--xhigh` 才对支持的 agent 用最高档（codex `xhigh`、reasonix/qoderclicn `max`）——会更慢、更易超时。

> **例外：reasonix 必须用 `high`/`max`。** 它背后的 DeepSeek thinking 模型直接拒绝 `medium`
> （报 `effort must be high, max, or disabled` 并退出）。

---

## 7. 常见问题

| 现象 | 原因 / 处理 |
|---|---|
| 提示"未检测到任何外部 agent CLI" | 一个都没装，按第 2.1 节装并登录 |
| `timeout -> MISSING` | 没装 coreutils，`brew install coreutils`；不装则慢 agent 会被跳过 |
| 某 agent 超时被跳过 | 已默认后台+medium；仍超时可降强度/精简范围重试。不阻塞其它 agent |
| codebuddy 无输出/超时 | 先看翻牌类别：`⛔ 额度/限流`（429，错误串带重置时间）到点再试；`⚠️ turn 预算耗尽` 用 `--max-turns 64` + 核实清单收窄到 3-5 条；提示词压到 25KB 内。仍不行则跳过 |
| opencode 迟迟不返回 | 本机实测极慢（早期未加超时封装时，最小任务 15 分钟仍未返回）。现在走后台 + `timeout 600`，超时即被斩并标 `⏭ 跳过`。当可选 agent 用，不阻塞综合 |
| agent 说"无法验证 / 前提不可知" | 不应再频繁出现——沙盒里有 `./repo` 只读副本可查。若仍出现，Claude 会在综合前逐条替它查证（事实核查回填），不会直接判 FAIL |
| 磁盘里堆了 `codev-sbox.*` | 进程被杀时收尾没跑到留下的；下次 `/codev` 启动会自动清理超 60 分钟且 owner 进程已死的，超 7 天的不看进程一律清（会话目录 `codev.*` 则是超 24 小时且无文件活动） |
| gemini 报网络错误 | 本机 gemini 偶发 503/fetch failed，属它自身网络问题，重试或换 agent |
| review 说 base 无效 | 初始提交/浅克隆时会停下，让你指定 base 或确认用 `git diff --root HEAD` |
| 命中 secret 扫描 | 会停下让你确认继续/脱敏/缩小范围——**不要**把真实 token/密钥发给外部模型 |

---

## 8. 文件结构

```
codev/
├── README.md              # 本文件：使用文档
├── SKILL.md               # 给 Claude 执行的主规范（流程 / 铁律 / 通用机制 A–G）
├── bin/
│   └── codev-lib.sh       # 共享 shell 函数库：timeout 封装 / 沙盒 / 输出捕获 / RC 上报 / 探测
├── references/
│   ├── agents.md          # 每个 agent 的精确调用命令、鉴权、只读策略、失败处理
│   ├── prompts.md         # 发给外部 agent 的提示词模板（含文件系统边界）
│   └── synthesis.md       # 跨模型综合、一致性矩阵、PASS/FAIL 门禁规则
├── TESTING.md             # 测试与验收手册（库回归 / 文案微测试 / 真机验收）
└── tests/
    └── test-lib.sh        # 库的回归测试，bash 与 zsh 各跑一遍
```

> **`bin/codev-lib.sh`**：调用外部 agent 的公共底座。Step 0 会建一个**本次会话专属目录**
> （`mktemp -d`）并把它拷进去，之后每个后台调用 `CODEV_DIR=<会话目录>; source "$CODEV_DIR/codev-lib.sh"`
> 一行即可拿到 `codev_bg_native` / `codev_bg_sandboxed` 等函数——超时封装、隔离沙盒 + 只读仓库副本、
> 退出码/超时的显式上报都集中在这一处，改一次全局生效。输出走会话目录（而非固定 `/tmp/codev-*`），
> 避免并发的两个 `/codev` run 互相覆盖、清理误删。参考 gstack 的 `bin/gstack-codex-probe` 做法。

---

## 9. 隔离沙盒与只读仓库副本

六个外部 agent 按只读保障分四档跑（后三档都在隔离沙盒里）。此外 Claude 自己的 fresh-subagent（`self`）也作为评审方
参与：保障级别与 opencode 同为"弱"（提示词只读 + 前后快照核对），但它跑在真实仓库而不是沙盒：

| 档 | agent | 只读保障 | 跑在哪 |
|---|---|---|---|
| **沙盒级只读** | codex、gemini | CLI 自带进程级限制（`-s read-only` / `--approval-mode plan`） | 真实仓库根 |
| **隔离沙盒** | qoderclicn、codebuddy | 沙盒 + 只读工具白名单（harness 级）+ 提示词边界 | `mktemp -d` 沙盒，内含 `./repo` 只读副本 |
| **隔离沙盒（旗标弱）** | opencode | 沙盒 + `--agent plan`（`edit` 禁了但 `bash` 没禁，可绕过）+ 提示词边界 | 同上 |
| **隔离沙盒（仅沙盒兜底）** | reasonix | 只有沙盒 + 提示词边界——它**没有**可用的只读旗标（`--permission-mode plan` 非交互下报错退出） | 同上 |

沙盒里的 `./repo` 是**工作区（含未提交改动）的只读副本**：`chmod -R a-w`，不含 `.git`，
并已排除常见密钥文件：`.env` / `*.env` / `.env.*` / `.envrc`、`*.pem` / `*.key` / `*.p12` / `*.pfx`、
`id_rsa*` / `id_dsa*` / `id_ecdsa*` / `id_ed25519*`、`*.keystore` / `*.jks`、`.netrc` / `.npmrc`、
`*credentials*`（仅数据格式与无扩展名，见下）、`*.tfvars` / `*.tfstate*`。第一轮按**文件名**（basename）
过滤，大小写敏感；解包后再用 `find -type f -iname` 扫一轮（挡 `.ENV`、`UPPER.PEM` 这类变体）。
> 副作用：`*.key` / `*.env` 会连带挡掉 `src/keymap.key`、`config/test.env` 这类**合法**文件——
> 有意的 security-first 取舍。但只挡文件不挡目录：`src/credentials/`、`themes/dark.env/` 这类
> **目录**不会被整棵吃掉。`*credentials*` 只删 json/yml/ini/toml/enc/pem/txt/csv/xml 等数据格式和
> 无扩展名的（`credentials`、`gcp-credentials.json`、`credentials.yml.enc`），`credentials.go` /
> `credentials.proto` / `Credentials.scala` 这类源码一律保留（详见 `references/agents.md`）。
**tracked 符号链接一律删除**——它们能让 agent 经 `./repo/link` 读到、甚至写穿到沙盒外的真实文件
（`chmod -R a-w` 只改链接自身权限位，不保护目标，实测可写穿）。

**为什么给副本而不是空目录**：早期为了消灭越界写入风险，把这四个 agent 扔进空目录只喂提示词文本。
风险是没了，但它们变成了**瞎子**——看不到 diff 之外的代码，遇到"这个不变量在别处成立吗""这个函数
真实调用方是谁"只能标存疑，评审 spec 时更是只能靠 Claude 手工摘代码塞进提示词（易漏、易与仓库
当前状态脱节），结果给出的"FAIL"往往不是真 bug，而是看不到代码导致的假阳性。
给**副本**同时拿到两边：视野恢复了，物理隔离也还在（写入落在副本上，真仓库根本不在 cwd 里）。

**注意隐私边界变了**：沙盒 agent 现在能读整个工作区并发给它自己的模型，不再只有 diff。
密钥文件已排除、secret 扫描照做，但**挡不住硬编码在源码里的密钥**。仓库整体敏感时，
让 Claude 用 `CODEV_SANDBOX_MODE=text` 退回"只喂提示词文本"（代价：那四个 agent 重新变瞎；对 codex/gemini 无效，
它们要靠 `--agents` 排除）。

副本超过体积闸门（`CODEV_MAX_COPY_KB`，默认 100MB、上限 1GB）或当前不是 git 仓库时，会自动退回空目录模式，
启动行 `▶` 会标出实际用的是哪种。

**每个 agent 拿到的是独立副本**：每个（仓库 + 工作区内容）签名只铺一份"母本"（改了代码再评自动换新母本），各 agent 从母本 `cp -c`
（APFS 写时复制）clone 一份自己的。所以它们互不干扰——某个 agent 就算绕过只读权限改了文件，
也只影响自己那份，其它 agent 和母本不受影响（实测改一份，另一份和母本都没变）。
实测 55MB/2000 文件、6 个 agent：比"每个 agent 各自全量拷" 5.06s → 2.72s，
额外 5 份副本真实只多占 6MB 磁盘（共享数据块，`du` 看不出来会虚报 ~280MB）。

**为什么不用 `git worktree`**：worktree 检出的是一个**提交**，看不到你未提交的改动和未跟踪文件——
而 review 默认评审的正是未提交改动，agent 会对着不一致的代码下结论。而且 worktree 与真仓库
**共享 `.git`**，实测 agent 能在里面 `git commit` 进真仓库的对象库、还成功删掉了真仓库里
另一个分支。现在的副本不含 `.git`，`git` 命令跑不起来，这条通路不存在。
`git clone --local` 安全但同样只看得到已提交状态，故也没采用（细节见 `references/agents.md`）。
