# agents.md — 外部 agent 调用参考

## 安装 / 登录（Step 0 一个都没探测到时给用户）

这些是第三方 CLI，本 skill 不代装。按需安装并登录（各家以官方文档为准）：
- **codex**（OpenAI）：装后 `codex login`，或设 `$OPENAI_API_KEY` / `$CODEX_API_KEY`。
- **gemini**（Google）：装后首次交互登录，或设 `$GEMINI_API_KEY`。
- **reasonix**（DeepSeek）：`reasonix setup` 配 API key。
- **qoderclicn / codebuddy**：各自账号交互登录。
- **opencode**：`opencode auth` 配置 providers。
- **timeout**：macOS 无原生 `timeout`，`brew install coreutils` 装 `gtimeout`。

---

每个 agent 背后是不同的大模型。调用前先 Step 0 探测；只用 `command -v` 命中的。
所有命令都以**只读**为目标运行，用 timeout 包裹、`< /dev/null` 喂空 stdin 防挂起、
分别收集 stdout/stderr（用于逐字呈现与读 token/成本）。

## 共享函数库 `bin/codev-lib.sh`（所有调用的公共底座）

重复样板（timeout 封装、沙盒、输出捕获、RC 上报）都收进 `bin/codev-lib.sh`，**Step 0 建【会话专属目录】
`CODEV_DIR=$(mktemp -d -t codev.XXXXXX)` 并把库拷进去**，每个（含后台）调用开头
`CODEV_DIR=<会话目录>; source "$CODEV_DIR/codev-lib.sh"` 即拿到全部函数。
> ⚠️ **变量/函数不跨 Bash 调用**：并行 fan-out 每个 agent 是**独立 Bash 调用 = 独立 shell**，变量/函数
> 都不继承——所以靠**每次 source 库 + 重设 CODEV_DIR 字面值**拿回函数与路径、**输出走会话目录内字面路径**
> `$CODEV_DIR/codev-out-<agent>.txt`。per-session 目录避免并发 run 互相覆盖、清理误删（旧版固定 `/tmp/codev-*` 会）。

| 函数 | 作用 |
|---|---|
| `codev_run <cmd…>` | timeout 封装。取代 `$TP <cmd>` 变量前缀——**zsh 不对无引号变量做词拆分**，`$TP cmd`（`TP="/path/timeout 600"`）会把整串当一个命令名执行 → `no such file or directory`、exit 127（本机 shell 是 zsh，实测每个调用都死在这）。`codev_run` 用 `"$@"` 传参，bash/zsh 都对。 |
| `codev_bg_sandboxed <agent> <cmd…>` | 非原生只读 agent：`mktemp` 隔离沙盒（含 `umask 077`，收进子 shell 不外泄）+ **默认铺一份只读仓库副本 `./repo`**（见下）+ 捕 agent 退出码（非 rm）+ 无 timeout 自动跳过并清空旧输出 + `codev_report`。首参 agent 标签，其后是完整命令 argv。 |
| `codev_repo_master` | 把工作区（tracked + 未忽略的 untracked，含未提交改动，不含 `.git`，过滤密钥文件）铺成**母本** `$CODEV_DIR/codev-master-repo`，**每会话只做一次**。带 `mkdir` 原子锁（并发 fan-out 时只有一个铺、其余等待复用）+ `.partial` 原子改名（中途被杀不会留下半个仓库被误当"已铺好"）+ 陈旧锁回收（`kill -0` 判持锁进程是否存活，确认已死才回收；mtime 兜底阈值 `-mmin +2` 因 find 按整分钟截断，实际是 **≥3 分钟**）。 |
| `codev_repo_copy <sbox>` | 从母本给该 agent clone 一份**独立**副本到 `<sbox>/repo` 并 `chmod -R a-w`。用 `cp -c`（APFS clonefile 写时复制：秒级、几乎不占额外磁盘，但各 agent 互不影响），不支持时退回 `cp -R`。非 git 仓库 / 超体积闸门 / 失败时返回 1，调用方自动退回空目录模式。 |
| `codev_bg_native <agent> <cmd…>` | 原生只读 agent（codex/gemini）：同上但**不建沙盒**、在当前 cwd（仓库根）跑（只读性由调用方 argv `-s read-only`/`--approval-mode plan` 保证，函数不校验）。 |
| `codev_report <agent> <rc> <errfile>` | 完成行 + **非零退出显式上报**（124→超时跳过；≠0→`⚠️ exit=N`+stderr 头 5 行；0→`✔`）。防"无输出"被误判成模型卡死。 |
| `codev_auth_codex` | codex 多信号鉴权（env 或 `~/.codex/auth.json`）→ `AUTH_OK`/`AUTH_FAILED`。**已被 `codev_probe` 调用**：codex 命中时其 OK 行附带该结论。 |
| `codev_sbox_gc` | 清理残留：`codev-sbox.*` 超 **60 分钟**（沙盒天生短命，上限 600s，不会误删并发 run 的活沙盒）、会话目录 `codev.*` 超 **24 小时**（里面有母本，几十 MB；24h 这档够长，不会撞上"用户慢慢看输出"或并发 run，且显式跳过本次会话自己的目录）。**已被 `codev_probe` 调用**，Step 0 顺带清。 |
| `codev_probe` | Step 0 探测：先 `codev_sbox_gc` 回收残留沙盒，再列 OK/MISS agent（codex 附鉴权）+ timeout 状态。 |

要传环境变量给库函数：`codev_bg_native gemini env VAR=val gemini …`（`env` 作为命令的一部分传入）。
600s 只兜底真正卡死的进程——**慢模型靠后台执行**（Bash `run_in_background`）跑完，不受前台工具超时约束。
库的卫生规则见文件头注释（不 `set -e/-u`、不改 IFS/PATH、`umask` 收进子 shell、前缀 `codev_`/`CODEV_`、
bash/zsh 通用——注意 `local` 非 POSIX，仅保证这两个 shell）。下文各 agent 用 `codev_bg_*` 一行式给出精确命令。

**提示词一律走文件，禁止内联进命令行**——把完整提示词写入临时文件，命令里用
`"$(cat "$PROMPT")"` 引用。**绝不**把 `git diff`/用户需求原文直接拼进 `"<完整提示词>"`：
diff 里的 `$(...)`、反引号会被 shell 展开（注入）。
```bash
PROMPT="$CODEV_DIR/codev-prompt-<agent>.txt"   # 放会话目录；用 cat > "$PROMPT" <<'EOF' 写入（单引号 EOF 防展开）
```
> 提示词文件放 `$CODEV_DIR`（会话目录）内、按 agent 命名，与库写的 out/err 同处，收尾 `rm -rf "$CODEV_DIR"` 一并清。
> 若临时另建文件，注意 macOS/BSD `mktemp` 只替换**结尾**的 X（`mktemp /tmp/foo-XXXXXX.txt` 原样生成、并行相撞），
> 一律用 `mktemp -t codev-<role>` 形式。
> **注意**：`"$(cat "$PROMPT")"` 只解决注入，**不能**避免 `ARG_MAX`（内容仍作 argv）。防 ARG_MAX 要靠
> 阈值：发送前 `wc -c "$PROMPT"`，超大（如 > 100KB）就按文件筛选/缩小范围，或改用支持 stdin 的 CLI。

**输出路径由库统一管理**：`codev_bg_*` 把 stdout/stderr 写到**会话目录内字面路径**
`$CODEV_DIR/codev-out-<agent>.txt` / `$CODEV_DIR/codev-err-<agent>.txt`（后台独立 shell 靠字面路径读，
不用随机 `mktemp` 变量——否则收到完成通知时不知去哪读；`CODEV_DIR` 每次调用用字面值重设）。提示词文件
`PROMPT` 放同一会话目录（`$CODEV_DIR/codev-prompt-<agent>.txt`）。
收尾清理：完成呈现后直接 `rm -rf "$CODEV_DIR"`（整个会话目录一并删，不用通配 glob，故不会误删并发 run 的文件；或告知用户保留）。
失败/空输出判定综合 **exit code + stdout + stderr** 三者（`codev_report` 已据此翻牌）；若 stdout 为空但
stderr 含有效正文（非鉴权/报错），也逐字呈现并标注"来源 stderr"。

非原生只读 agent（reasonix / qoderclicn / opencode / codebuddy）的只读保障按运行位置三选一：
- **(a) 默认 & 首选：隔离沙盒 + 只读仓库副本**——cwd 是 `mktemp -d` 出来的沙盒，里面有 `./repo`
  （工作区副本，`chmod -R a-w`）。**真实仓库根本不在 cwd 里**，agent 的任何写入都只能落到副本上、
  随沙盒一起删掉 → 免掉快照/归因/污染问题，同时 agent **能读到全部代码**。这是 (a') 的严格升级版。
- **(a') 隔离空目录只喂文本**（`CODEV_SANDBOX_MODE=text`）——旧默认。仅在不想让 agent 看到仓库
  其余部分（如只想要纯粹的 diff 意见）、或副本超体积闸门时用。
- **(b) 确需在真实仓库 cwd 跑**：则**必须逐 agent 前后快照核对 + 串行**（并行无法归因、会互相污染）。
  有了 (a) 之后基本没有理由再走 (b)。

### 为什么默认改成"只读仓库副本"（重要设计决策）

早期为消灭越界写入风险，把这四个 agent 扔进**空目录**、只喂提示词文本。风险是消灭了，代价是
它们变成了**瞎子**，实测两个后果：
1. **diff 评审**：能看全改动本身，但看不到 diff 之外的既有代码——"这个不变量在别处是否成立"
   "这个函数真实调用方是谁"只能标存疑。
2. **spec 评审**（无 diff 可喂）：Claude 得手工从仓库摘代码片段塞进提示词（出现过 53KB 的巨型
   提示词），容易漏、也可能与仓库当前状态脱节。实测导致 agent 给出"conditional FAIL /
   unverifiable premise"——**不是真发现 bug，是看不到代码造成的假阳性**。

**给副本而不是给真仓库**同时拿到两边：视野恢复了，物理隔离也还在（写入落在副本、真仓库不在 cwd）。
比"把它们升级成原生只读、放进真仓库跑"更安全——后者要赌各家 CLI 的只读旗标真的是沙盒级保证，
而实测（见下方各 agent 条目）**没有一家做到 codex `-s read-only` 那种级别**。

**边界说明（别高估它）**：副本是**纵深防御**，不是硬隔离。若 agent CLI 有 shell/tool 能力，
它仍可用**绝对路径**读写沙盒外的东西（`cat /etc/...`、`cd ~/Project/...`）——空目录时代也一样挡不住。
所以副本要**叠加**各 agent 的禁工具/只读旗标 + 提示词边界，三层一起用。

### 为什么不用 `git worktree` / `git clone`（都实测过，别再走回头路）

**`git worktree` 不行，两个硬伤**（实测确认）：
1. **看不到未提交改动**。worktree 检出的是一个**提交**：把 `tracked.txt` 改成 `UNCOMMITTED EDIT`、
   新建 `untracked.txt` 后建 worktree，里面是旧的 `committed` 内容、且**没有** untracked 文件。
   而 `/codev review` 的默认场景恰恰是评审**未提交的工作区改动** → agent 会对着一份和被评审内容
   不一致的代码下结论，比"看不到"更糟（自信地错）。要修就得先帮用户提交 WIP，那正是铁律禁止的副作用。
2. **可写 + 共享真实 `.git`**。worktree 的 `.git` 文件指向 `<真仓库>/.git/worktrees/<name>`，
   对象库是共享的。实测 agent 在 worktree 里 `git commit` 成功、该提交进了**真仓库**的对象库；
   `branch -f` 当前分支被 git 拦住了，但**实测 agent 成功 `git branch -D` 删掉了真仓库里另一个
   未被检出的分支**。对四个"无沙盒级只读保证、又有 shell 能力"的 agent，这是一条真实的写入通路。
   现在的副本**不含 `.git`**，`git` 命令根本跑不起来，这条路不存在。

**`git clone --no-hardlinks --local` 安全但同样只看得到已提交状态**（实测：clone 里是 `v1`、
无 untracked 文件；agent 在 clone 里删分支/删文件，真仓库的分支、未提交改动、untracked 全部完好）。
它的好处是 agent 能跑 `git log`/`git blame` 做历史考古 —— 若将来需要那个能力，可以作为**可选模式**
补进来，但**不适合当默认**（看不到 WIP，且更慢更占地方）。

一句话：worktree/clone 适合"让 agent 在某个提交上构建或跑测试"，不适合"让不可信 agent 评审脏状态"。

**必须在提示词里告诉 agent 副本存在**（prompts.md 的「工作副本」段落），否则它不知道能读 `./repo`，
副本白铺。

体积闸门：默认 `CODEV_MAX_COPY_KB=102400`（100MB，只统计将被拷的文件，`.gitignore` 排除的
`node_modules`/构建产物天然不计入）；超了自动退回空目录模式并在 `▶` 行标出。

**副本里被主动剔除的两类东西**（都是实测出的真实逃逸通道，不是防御性冗余）：

1. **tracked 符号链接** —— `find -type l -delete`。tar 原样保留链接，若仓库有指向仓库外绝对路径的
   tracked symlink，agent 经 `./repo/link` 就能读到沙盒外的真实文件；更糟的是**能写穿**：实测
   `chmod -R a-w` 之后 `echo X > repo/link` 仍然成功改掉了链接目标的真实文件（`chmod` 只改 symlink
   自身的权限位，不保护目标）。那会直接击穿"写入只落在副本上"这条主防线。
2. **submodule 的内部文件** —— `tar --no-recursion`。`git ls-files` 对 submodule 只输出一个
   mode 160000 的**目录路径**，tar 收到目录默认会递归整个已初始化 submodule，连 submodule 自己的
   untracked、以及被它 `.gitignore` 忽略的文件都一起打包（实测 `sub/untracked_secret.txt` 进了包）。
   加 `--no-recursion` 后目录项只建空目录、不下钻；普通文件因 `ls-files` 已逐个列出，不受影响。

密钥过滤是**两道**：tar 的 `--exclude`（大小写敏感）+ 解包后一轮 `find -type f -iname` 大小写
不敏感清扫（挡 `.ENV`、`UPPER.PEM` 这类变体，实测 `--exclude` 确实漏它们）。两道都只认**文件名**，
挡不住硬编码在源码里的密钥 —— Step 2B 的 secret 扫描仍然必须做。

**过滤模式的两条硬约束**（都是踩过的坑，改清单前务必先看）：

1. **tar 的 `--exclude` 按【路径分量】匹配，会连目录一起挡掉。** 所以宽通配是禁区：
   `*credentials*`（甚至光秃秃的 `credentials`）会整体吃掉 `src/credentials/` 整棵子树，
   连里面不含密钥的文件一起消失，`--exclude=./credentials` 锚定也无效。无扩展名的凭证文件
   （`credentials`、`credentials.json`）只在**后置 `find -type f -iname`** 里挡——
   `-type f` 天然匹配不到目录，正好只删真的凭证文件。
2. **后置 `find` 必须带 `-type f`。** 不加会匹配到目录，`-delete` 虽拒删非空目录，
   但空目录/单文件目录仍会连带整棵子树消失。

**已知的假阳性（security-first 的有意取舍，非 bug）**：`*.key` 和 `*.env` 会连带挡掉
`src/keymap.key`、`config/test.env` 这类合法文件。判断标准是"宁可漏挡一个少见的密钥文件名
（secret 扫描仍会兜底），也绝不删用户的源码"——所以**只对确定是密钥载体的模式用通配**。
若某仓库确实因此丢了关键文件、导致 agent 评审失真，用 `CODEV_SANDBOX_MODE=text` 或临时调整清单。

### 母本 + clone：每会话只 tar 一次

N 个 agent 各自全量 tar 一遍很浪费。现在改成**母本 + 写时复制 clone**：
- `codev_repo_master` 把工作区铺成母本 `$CODEV_DIR/codev-master-repo`，**每会话只做一次**；
- `codev_repo_copy` 用 `cp -c`（APFS **clonefile**）从母本给每个 agent clone 一份。

实测（55MB / 2000 文件，6 个 agent）：旧的"每 agent 全量 tar" 5.06s → 新的"1 次 tar + 6 次 clone" 2.72s。
APFS clone 共享数据块：额外 5 份副本的**真实**磁盘增量仅 6MB（`df` 实测；`du` 会虚报 ~280MB，
它数不出共享块，所以别用 `du` 判断副本占了多少盘）。

**为什么是 clone 而不是硬链接共享同一份**：硬链接是同一个 inode，任一 agent 若绕过 `chmod a-w`
改了文件，会**串到所有 agent 和母本**；clonefile 是写时复制，改动只落在自己那份。
实测：a4 把自己副本的 `SKILL.md` 从 344 行覆盖成 1 行后，a5 拿到的仍是 344 行、母本也完好。
不支持 `cp -c` 的平台（非 APFS）自动退回 `cp -R`，语义一样、只是不共享块。

**并发正确性**：fan-out 时 N 个 agent 是 N 个独立 shell、会同时进 `codev_repo_master`。
用 `mkdir` 原子锁（抢到的铺、其余等着复用）+ `.partial` 目录原子改名（中途被杀不会留下半个仓库
被下次误当"已铺好"）+ 陈旧锁回收（持锁进程被杀时不至于让后续 agent 白等满 300s）：先用 `kill -0` 判持锁者是否存活，**活锁不回收**（否则会偷走仍在写母本的进程的锁，两个 builder 同时解 tar → 母本交错/截断，波及全部 agent）；mtime 只作 PID 丢失时的兜底，`-mmin +2` 实际语义是 **≥3 分钟**（find 按整分钟截断）。
实测 6 个真并发 agent 全部读到正确内容、只生成一个母本、无锁/半成品残留。

无论哪种，核对只**检测并如实上报**，**绝不自动 `git checkout`/`reset`**——review 模式下工作区正是用户
待评审的未提交改动，自动回滚会连用户自己的工作一起抹掉（未跟踪文件 checkout 也删不掉）。下面片段用于 (b)：
```bash
SNAP=$(git status --porcelain)          # 调用前快照（含未跟踪文件）
# … 调用 agent …
if [ "$(git status --porcelain)" != "$SNAP" ]; then
  echo "⚠️ <agent> 疑似改动了工作区，违反只读约定。变化如下："
  git status --porcelain
  echo "→ 停下，把差异逐字告知用户，由用户决定如何处置（不要自动回滚）。"
  exit 1                                 # 非零退出，强制 Claude 停下、不静默继续
fi
```
- **必须有 `exit 1`**：只 echo 不退出，Bash 调用仍返回 0，Claude 可能无视警告继续，把"停下"架空。
- **并行归因问题**：多个非原生只读 agent 同时跑时，快照交叠无法归因到某一个，且 A 的写入会污染
  B 读到的状态。因此非原生只读 agent **要么串行**（各自前后核对），**要么走沙盒 (a)**。隔离由库函数
  `codev_bg_sandboxed` 实现（`umask 077` + `mktemp -d` 沙盒 + 只读仓库副本 + 捕 agent 退出码 + 无 timeout 跳过）：
  ```bash
  CODEV_DIR=<会话目录>; source "$CODEV_DIR/codev-lib.sh"
  PROMPT="$CODEV_DIR/codev-prompt-reasonix.txt"
  codev_bg_sandboxed reasonix reasonix run "$(cat "$PROMPT")" --effort high -p
  ```
  （`--effort high` 不是笔误：reasonix 拒绝 `medium`，见下方 reasonix 条目。）
  这样 agent 的 cwd 是沙盒（真实仓库不在里面），从根本上免掉快照/污染问题。**但沙盒只是纵深防御的
  一层，不是硬隔离**：若 agent CLI 自身有 tool-use / shell 执行能力，它能用**绝对路径**读写沙盒外的
  文件（`cat /任意路径`、`cd ~/Project/...`）——空目录时代也一样挡不住。所以对有工具能力的 agent 必须
  **叠加只读/禁工具旗标 + 提示词约束**（见下方各 agent 条目的精确旗标）。
- **快照盲区**：`git status --porcelain` 检测不到**已存在的未跟踪文件的内容**被改（前后都是 `??` 同名）。
  这也是沙盒优先于"在仓库里跑再快照"的原因；确需在仓库跑时，可额外记录
  `git ls-files --others --exclude-standard -z | xargs -0 shasum` 的前后 hash。
- 原生只读的 codex/gemini 可放心并行（`-s read-only` / `--approval-mode plan` 是沙盒级保证）。

---

## codex — OpenAI GPT

- **咨询 / 头脑风暴 / 挑战 / 通用提问**（默认纯文本，便于逐字呈现）：
  ```bash
  CODEV_DIR=<会话目录>; source "$CODEV_DIR/codev-lib.sh"; cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  codev_bg_native codex codex exec "$(cat "$PROMPT")" -s read-only -c 'model_reasoning_effort="medium"'
  ```
  （`codex exec` 接受 `-C`/`-s`；因已 `cd` 进仓库根，`-C` 可省。）默认**不加 `--json`**——JSONL（推理
  轨迹/工具调用事件流）不适合"逐字呈现"；仅当明确要解析 token/事件时才加。若目录非受信 git 仓库报
  "Not inside a trusted directory"，加 `--skip-git-repo-check`。
- **代码评审（原生，gstack 式）**：⚠️ `codex review` 的接口与 `exec` **完全不同**，实测三个坑：
  ① **不接受 `-C`**（`error: unexpected argument '-C'`，exit 2）→ 须先 `cd` 进仓库根；
  ② **不接受 `-s`**（review 本就只读）；
  ③ **自定义 `[PROMPT]` 与 `--base`/`--commit` 互斥**（`error: the argument '[PROMPT]' cannot be used
     with '--commit'`，exit 2）。
  **解法（借 gstack）：丢 `--base`，把 diff 范围写进 prompt** 让 codex 自己跑 `git diff`——这样既避开
  argv 互斥、又**保住自定义关注点**（比"无 prompt"版强）。prompt 里含文件系统边界 + 一句
  "请运行 `git diff <base>...HEAD`（拿不到就 `git diff <base>`）只评审这些改动 + <关注点>"：
  ```bash
  CODEV_DIR=<会话目录>; source "$CODEV_DIR/codev-lib.sh"; cd "$(git rev-parse --show-toplevel)"
  # PROMPT 内含边界 + “跑 git diff <BASE>...HEAD 只评审这些改动”（<BASE> 写字面值，如 HEAD~1）
  codev_bg_native codex codex review "$(cat "$PROMPT")" -c 'model_reasoning_effort="medium"'
  ```
  实测已验证：`codex review [PROMPT]` 确会读取仓库/执行 `git diff` 并产出**带真实文件:行号**的 diff-grounded
  评审（本 skill 自评时 codex 精确引用了改动行，非幻觉），故 gstack 式取范围可行、无需退回 `--base`。
  （若无需自定义关注点，也可退回选择器式 `codex review --base <字面值>`——但那样不能再带 `[PROMPT]`。）
- **推理强度**：默认 `medium`（防慢/防超时）；复杂任务或用户要更深升 `high`；`--xhigh` 才用
  `-c 'model_reasoning_effort="xhigh"'`。升档前提醒会更慢。
- **鉴权**：需 `codex login`，或环境变量 `$CODEX_API_KEY` / `$OPENAI_API_KEY`，或
  `~/.codex/auth.json` 存在。缺失时提示：`codex login`。
- **成本**：`grep -i "tokens used" "$CODEV_DIR/codev-err-codex.txt"`（大小写不敏感）。
- **角色**：严谨、对抗式挑刺、深度代码审查（"200 IQ 直男工程师"式第二意见）。

## gemini — Google Gemini

- **调用**（原生只读，用 `codev_bg_native`；环境变量走 `env`）：
  ```bash
  CODEV_DIR=<会话目录>; source "$CODEV_DIR/codev-lib.sh"; cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  codev_bg_native gemini env GEMINI_CLI_TRUST_WORKSPACE=true gemini -p "$(cat "$PROMPT")" --approval-mode plan
  ```
  可选 `-m <model>` 指定模型（建议显式指定以固定评审质量，如 `-m gemini-2.5-pro`）。
- **只读保证**：`--approval-mode plan` 为**原生只读模式**（不改文件）。
- **非受信目录**：非交互模式在未信任目录会报 "not running in a trusted directory" 直接失败；
  用 `GEMINI_CLI_TRUST_WORKSPACE=true`（或 `--skip-trust`）。
- **鉴权**：`gemini`（首次交互登录）或 `$GEMINI_API_KEY`。
- **角色**：超大上下文、架构/方案发散、跨领域联想。

## reasonix — DeepSeek

- **调用**（非原生只读，用 `codev_bg_sandboxed`；沙盒内有 `./repo` 只读副本）：
  ```bash
  CODEV_DIR=<会话目录>; source "$CODEV_DIR/codev-lib.sh"
  codev_bg_sandboxed reasonix reasonix run "$(cat "$PROMPT")" --effort high -p
  ```
  可选 `--budget <usd>` 设美元上限、`-m <id>` 指定模型（如 deepseek-v4-flash）。
  `-p` 只打印最终回答（省掉工具调用流水，逐字呈现更干净）。
- **⚠️ `--effort medium` 在 DeepSeek thinking 模型上会直接报错退出**（实测 exit=1：
  `provider "deepseek-pro" uses DeepSeek thinking; effort must be high, max, or disabled`）。
  **reasonix 是全局"默认 medium"规则的例外**：给它 `high`（或 `max`/不传）。传 medium 等于白跑一轮。
- **⚠️ `--permission-mode plan` 非交互不可用**（实测 exit=2：`requires an interactive session`），
  别照搬 gemini 的 plan 模式思路。非交互下用默认 `ask` 模式（无人应答即不放行写操作）。
- **只读保证**：**无可用的非交互只读旗标** → 靠 `codev_bg_sandboxed` 沙盒（真仓库不在 cwd、
  `./repo` 副本 `chmod a-w`）+ 提示词强约束，且不给它 auto-approve / `bypassPermissions`。
- **推理强度**：`--effort low|high|max`（**跳过 medium**，见上）；`--xhigh` 用 `max`。
- **鉴权**：`reasonix setup` 配置 API key。
- **角色**：低成本、高性价比推理，适合快速多方案头脑风暴。

## qoderclicn — Qoder

- **调用**（非原生只读，用 `codev_bg_sandboxed`；沙盒内有 `./repo` 只读副本）：
  ```bash
  CODEV_DIR=<会话目录>; source "$CODEV_DIR/codev-lib.sh"
  codev_bg_sandboxed qoderclicn qoderclicn --reasoning-effort medium --tools "Read,Glob,Grep" -p "$(cat "$PROMPT")"
  ```
  可选 `-m <model>`。注意 `--tools` 是变长参数，**必须用 `-p` 把它与 query 隔开**（把 `-p …` 放最后）。
- **只读保证：`--tools "Read,Glob,Grep"`（只读工具白名单）——推荐默认带上。**
  这是 harness 级强制：模型手里根本没有写工具。实测让它建文件，它答"我可用的工具只有
  Read、Glob、Grep，没有写入工具或 Bash，因此无法创建"——且**读 `./repo` 正常**。
  ⚠️ **不要再用 `--tools ""`**：那是把**包括读文件在内**的全部工具都禁掉，沙盒里的 `./repo` 副本
  就白铺了，agent 重新变瞎。`--tools ""` 只在刻意要"纯文本问答、不给任何代码视野"时才用。
  不要用 `--dangerously-skip-permissions` / `--permission-mode bypass_permissions`。
- **推理强度**：`--reasoning-effort`；默认 `medium`，`--xhigh` 用 `max`。
- **鉴权**：Qoder 账号登录。`--list-models` 可查可用模型。
- **角色**：代码理解、评审。

## opencode — 多供应商

- **调用**（非原生只读，用 `codev_bg_sandboxed`；沙盒内有 `./repo` 只读副本）：
  ```bash
  CODEV_DIR=<会话目录>; source "$CODEV_DIR/codev-lib.sh"
  codev_bg_sandboxed opencode opencode run --agent plan "$(cat "$PROMPT")"
  ```
  默认纯文本便于逐字呈现；`--format json` 输出事件流（可读性差，仅需解析时用）。
  可选 `-m <provider/model>`（如 `openai/gpt-5.4`；避免选 Anthropic 模型，否则失去跨模型
  多样性的意义）。
- **⚠️ 本机实测极慢/疑似挂起**：给它一个"读一个文件、列出函数名"的最小任务，**15 分钟仍未返回**
  （同样的任务 reasonix / qoderclicn / codebuddy 都是秒级完成）。原因未查清（可能是沙盒 cwd 下
  初始化慢、或等某个交互）。→ **必须后台执行**，并预期它经常撞 600s 安全网被判超时跳过。
  把它当"有则加分、没有也不影响"的可选 agent，别放进默认推荐组合、也别让它阻塞综合。
- **只读保证**：`--agent plan` + 沙盒。
  ⚠️ **`--agent plan` 不够格当"原生只读"，别把它移到 `codev_bg_native` 去真仓库里跑。**
  实测 `opencode agent list` 里 plan agent 的权限表是：`edit` → `deny *`（只放行
  `.opencode/plans/*.md`），但**没有任何 `bash` 条目**，于是 `bash` 落到兜底的 `* → allow` 上——
  也就是说 plan agent **能执行任意 shell**，`edit` 禁令一条 `sh -c 'echo x > f'` 就绕过去了。
  这不是 codex `-s read-only` 那种沙盒级保证。而且这张权限表来自**用户本地 opencode 配置**
  （实测里含用户自定义的 `external_directory` 放行项），不是 CLI 的固有不变量，随配置漂移。
  → 结论：opencode 留在 `codev_bg_sandboxed`，`--agent plan` 只当**纵深防御的一层**。
  另注：`--auto`（auto-approve）默认关闭，**绝不要加**。
- **鉴权**：`opencode auth`（providers）。`opencode models` 查可用模型。
- **角色**：灵活切换多家模型，做交叉对比很方便。

## codebuddy — 腾讯（Claude Code 分支）

- **调用**（非原生只读，用 `codev_bg_sandboxed`；沙盒内有 `./repo` 只读副本）：
  ```bash
  CODEV_DIR=<会话目录>; source "$CODEV_DIR/codev-lib.sh"
  codev_bg_sandboxed codebuddy codebuddy --effort minimal --max-turns 12 --tools "Read,Glob,Grep" -p "$(cat "$PROMPT")"
  ```
- **只读保证**：`--tools "Read,Glob,Grep"`（只读工具白名单，同 qoderclicn 的 harness 级强制）
  + `-p` 非交互 + 沙盒 + 提示词强约束。不要用 `-y` / `--dangerously-skip-permissions` /
  `--permission-mode bypassPermissions`。同样**别用 `--tools ""`**（会连读文件也禁掉）。
- **⚠️ 空输出/超时问题（历史）**：过去实测 `codebuddy -p` 常无 stdout 或撞 timeout。
  **实测加上 `--effort minimal --max-turns 12 --tools "Read,Glob,Grep"` 后恢复正常**（秒级返回、
  正确读了 `./repo` 里的文件）——此前很可能是**放开全部工具 + 默认高 effort 导致 agent 无限兜圈**，
  而非登录/API 问题。所以**这三个旗标当作 codebuddy 的必备参数**，别省。
- **控制提示词体积**：codebuddy 对大提示词最敏感。给它的 prompt 建议**压到 30KB 以内**
  （比全局 100KB 阈值更严）——有了 `./repo` 副本，本来也不必再把大段代码内联进去，让它自己读。
- 仍然空输出/超时时：判定本次不可用，**跳过它**并如实告诉用户
  "codebuddy 无输出/超时（可能原因：未登录 / API 异常 / 上下文超限），已跳过；可运行
  `codebuddy` 交互登录后重试"。
- **鉴权**：`codebuddy`（交互登录）。
- **角色**：中文语境下的代码评审。

---

## 失败 / 超时 / 空输出处理（统一话术）

- **超时**（timeout 返回 124，即撞到 600s 安全网）：先确认是否**已用后台执行**——前台短超时误杀是
  最常见原因。仍超时则告知"<agent> 超过 600s 未返回，已跳过。可降推理强度到 medium/精简提示词后重试。"
- **鉴权失败**：给出对应登录命令，跳过该 agent，继续其余。
- **空输出**：跳过并说明（见 codebuddy 条）。
- **任一 agent 失败都不阻塞其它**；最终综合时注明"本轮实际参与的 agent：X、Y（Z 已跳过）"。

## 只读风险总结

| agent | 只读保障级别 | 实测旗标 | 运行位置 |
|---|---|---|---|
| codex | **沙盒级**（进程被限制） | `-s read-only`（`review` 子命令天然只读，不吃 `-s`） | 真实仓库 `codev_bg_native` |
| gemini | **沙盒级** | `--approval-mode plan` | 真实仓库 `codev_bg_native` |
| qoderclicn | **harness 级**（模型无写工具） | `--tools "Read,Glob,Grep"` ✅实测拒绝建文件 | 沙盒 `codev_bg_sandboxed` |
| codebuddy | **harness 级** | `--tools "Read,Glob,Grep"` | 沙盒 `codev_bg_sandboxed` |
| opencode | **弱**（`edit` 禁了但 `bash` 没禁，可绕过；且权限表随用户配置漂移） | `--agent plan` | 沙盒 `codev_bg_sandboxed` |
| reasonix | **无**（非交互下无可用只读旗标） | — （`--permission-mode plan` 非交互报错） | 沙盒 `codev_bg_sandboxed` |

三层纵深防御，下面四个 agent **三层都要上**，不能只靠其中一层：
1. **沙盒**（`codev_bg_sandboxed`）——真实仓库不在 cwd，只有 `./repo` 只读副本。**这是主防线**：
   即使前两层全被绕过，写入也只落在副本上，随沙盒删掉。
2. **旗标**（上表"实测旗标"列）——能拿到 harness 级的就拿（qoderclicn / codebuddy）；
   拿不到的（reasonix / opencode）如实承认只有第 1、3 层。
3. **提示词边界**（prompts.md 的「文件系统边界」段落）——最弱的一层，只防"顺手"不防"故意"。

**不要**因为某个 agent 有个看起来像只读的旗标就把它挪到 `codev_bg_native` 去真仓库里跑——
除非确认那是**沙盒级**（进程/内核层面限制），而非"框架答应不调用写工具"。opencode `--agent plan`
就是典型反例（见上方 opencode 条目：`bash` 未被禁）。

若确需在真实仓库 cwd 跑这四个中的任何一个（应当极少），**必须**按本文件顶部的快照片段在调用前后
`git status --porcelain` 核对 + 串行，发现改动即**停下、逐字上报差异交用户处置（`exit 1`，绝不自动
回滚**，以免误删用户未提交的工作）。
