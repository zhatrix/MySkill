# codev-lib.sh — codev skill 的共享 shell 函数库
#
# 用法：本文件由 SKILL.md 的各 Bash 调用【source】，不直接执行。
#   Step 0 先建【会话专属目录】并把它拷进去：
#     CODEV_DIR=$(mktemp -d -t codev.XXXXXX); cp <SKILL_DIR>/bin/codev-lib.sh "$CODEV_DIR/codev-lib.sh"
#   此后每个（含后台）Bash 调用开头（<会话目录> = Step 0 打印的字面路径）：
#     CODEV_DIR=<会话目录>; source "$CODEV_DIR/codev-lib.sh"
#   —— 因为后台是独立 shell，变量/函数都不继承，靠每次 source 重新拿到这些函数；
#      CODEV_DIR 也必须每次用字面值重设（否则退回默认 /tmp）。
#
# 卫生规则（务必遵守，否则 source 进调用方 shell 会污染/中断它）：
#   - 不要 set -e / set -u / trap / 改 IFS / 改 PATH（umask 已收进各函数的子 shell，不外泄）。
#   - source 时【不执行任何命令】，只做函数定义 + CODEV_TO / CODEV_DIR 两个赋值。
#   - 所有函数前缀 codev_、所有全局变量前缀 CODEV_。
#   - bash/zsh 通用：用 local/[ ]/"$@"，不用 bash 数组下标（注意 local 非 POSIX，仅保证 bash/zsh）。

# timeout 二进制探测（macOS 原生无 timeout，装 coreutils 才有 gtimeout）。
CODEV_TO=$(command -v timeout || command -v gtimeout || true)

# 输出/库文件的基目录 = 本次会话专属目录（Step 0 用 mktemp -d 建，每个后台调用开头用字面值
# `CODEV_DIR=<会话目录>` 前置）。好处：并发的两个 /codev run 不互相覆盖 out/err，收尾
# `rm -rf "$CODEV_DIR"` 也不会误删对方文件。
# ⚠️ 【不再默认 /tmp】。原来写 `${CODEV_DIR:-/tmp}`，漏设时三个后果都很严重（均实测）：
#   1) 母本变成固定的 /tmp/codev-master-repo，而 codev_repo_master 开头是【无条件复用】——
#      在 repoA 跑完再去 repoB 跑，repoB 的 agent 看到的是 repoA 的代码（实测 repoB 的
#      agent 只看到 secret_a.js、自己的 only_in_b.js 一个都没有）。既外泄 A 的代码，
#      又让 B 的评审整个建立在错误的树上，而 ▶ 行仍显示"只读仓库副本"，完全静默。
#   2) 文档里的收尾命令 `rm -rf "$CODEV_DIR"` 展开成 `rm -rf "/tmp"`（实测展开结果）。
#   3) /tmp 是 1777，任何本地用户都能预先建好 /tmp/codev-master-repo 决定所有 agent 读到什么。
# 故改为【未设置就报错退出】：宁可让调用方立刻失败，也不能静默走上以上任一条。
if [ -z "${CODEV_DIR:-}" ]; then
  echo "FATAL: codev-lib.sh 需要先设 CODEV_DIR（本次会话专属目录，见 SKILL.md Step 0）" >&2
  echo "  正确用法：CODEV_DIR=<Step 0 打印的字面路径>; source \"\$CODEV_DIR/codev-lib.sh\"" >&2
  return 1 2>/dev/null || exit 1
fi

# 沙盒模式：repo（默认，给只读仓库副本）| text（旧行为，纯空目录只喂提示词文本）。
CODEV_SANDBOX_MODE="${CODEV_SANDBOX_MODE:-repo}"
# 仓库副本体积闸门（KB）。超过就退回 text 模式，免得把巨型仓库整份拷进 /tmp。
# 必须校验成纯数字：闸门判断是 `[ "$sz" -gt "$CODEV_MAX_COPY_KB" ] 2>/dev/null`，非数字会让
# test 语法失败 → 整个 && 链为假 → 闸门【静默失效】，把任意大的仓库整份拷走（实测 abc 与空串
# 都直接放行）。故非法值一律退回默认并告警，不静默接受。
case "${CODEV_MAX_COPY_KB:-}" in
  '' ) CODEV_MAX_COPY_KB=102400 ;;
  *[!0-9]* )
    echo "⚠️ CODEV_MAX_COPY_KB='$CODEV_MAX_COPY_KB' 不是纯数字，已退回默认 102400 KB" >&2
    CODEV_MAX_COPY_KB=102400 ;;
esac

# codev_run <cmd...> — 超时封装。取代 `$TP <cmd>` 变量前缀：
# zsh 不对无引号变量做词拆分，`$TP cmd`（TP="/path/timeout 600"）会被当成名为
# 「timeout 600」的单个文件执行而失败；用函数 + "$@" 传参，bash/zsh 都对。
# 600s 只兜底真正卡死的进程——慢模型靠【后台执行】跑完，不受此约束。
codev_run() {
  if [ -n "$CODEV_TO" ]; then "$CODEV_TO" 600 "$@"; else "$@"; fi
}

# codev_report <agent> <rc> <errfile> — 打印完成行 + 【非零退出显式上报】。
# 关键：让调用方（Claude）不会把"无输出"误判成模型卡死；超时(124)/报错都清楚标注。
codev_report() {
  local agent="$1" rc="$2" err="$3"
  if [ "$rc" = "124" ]; then
    echo "⏭ $agent 跳过（超时 124，撞 600s 安全网）→ 可降强度/精简提示词后重试"
  elif [ "$rc" != "0" ]; then
    # 用 printf %s 传 $rc（不要写 "exit=$rc："——UTF-8 locale 下 bash 会把紧跟的全角字符与
    # 变量展开一起误扫，吞掉退出码；ASCII 冒号 + printf 稳）。stderr 只印一次头 5 行，空文件显式提示。
    printf '⚠️ %s 非零退出 exit=%s（stderr 头 5 行）:\n' "$agent" "$rc"
    if [ -s "$err" ]; then head -n 5 "$err" 2>/dev/null | sed 's/^/  /'; else echo "  (无 stderr)"; fi
  else
    echo "✔ $agent 完成 exit=0"
  fi
}

# codev_repo_copy <sbox> — 在沙盒里铺一份【只读仓库副本】到 <sbox>/repo。
# 解决"非原生只读 agent 是瞎子"：空目录让它们只能吃提示词里的文本，看不到 diff 之外的既有代码，
# 遇到"这个不变量在别处成立吗""这个函数真实调用方是谁"只能标存疑 → 假阳性。给一份【副本】既恢复
# 视野、又保住物理隔离：它们的任何写入都落在副本上，真仓库根本不在 cwd 里，也就不需要快照/归因。
# 布局：<sbox> 本身可写（当 cwd，免得某些 CLI 往 cwd 写日志/会话就崩），<sbox>/repo 只读。
# 副本内容 = tracked + 未被 .gitignore 忽略的 untracked（即工作区当前状态，含待评审的未提交改动），
# 不含 .git（省体积；agent 跑不了 git 命令，diff 由提示词提供），且过滤掉明显的密钥文件（见下 --exclude）。
# ⚠️ 隐私边界变了：以前空目录只发提示词里那点文本，现在【整个工作区都可能被 agent 读取并发给它的模型】。
# 凡进副本的内容都要当作"已经发出去了"。--exclude 只挡常见密钥文件名，挡不住硬编码在源码里的密钥——
# Step 2B 的 secret 扫描仍然必须做。仓库确实敏感就用 CODEV_SANDBOX_MODE=text 退回只喂文本。
# 返回 0=已铺好，1=跳过（非 git 仓库 / 超体积闸门 / 拷贝失败），由调用方退回 text 模式。
# 【每会话只 tar 一次】：母本铺在会话目录里，各 agent 的沙盒从母本 clone（见 codev_repo_copy）。
# 否则 N 个 agent = N 次全量 tar，大仓库上很浪费。实测 55MB / 2000 文件 / 6 agent：
# 「6 次全量 tar」5.06s → 「1 次 tar + 6 次 clone」2.72s；且 APFS clone 共享数据块——
# 额外 5 份副本的真实磁盘增量仅 6MB（df 实测；du 会虚报 ~280MB，它数不出共享块）。
CODEV_MASTER="$CODEV_DIR/codev-master-repo"

# codev_master_path — 把母本路径【按仓库根 + 工作区状态】区分开，回填 CODEV_MASTER。
# 为什么需要：codev_repo_master 开头是无条件复用「母本已存在就直接用」。只要 CODEV_DIR 被复用
# （漏设时的固定路径、或用户在同一会话里换仓库/改完代码再评一轮），复用就会给出【错的树】：
#   - 跨仓库：repoB 的 agent 拿到 repoA 的母本（实测只看到 A 的文件、B 的一个都没有）；
#   - 同仓库二轮：改完代码再 review，agent 仍读第一轮的快照，把已修的问题当现存报、
#     新代码的缺陷全看不见（agents.md 里正是用这条理由否掉 git worktree 的）。
# 做法：哈希「仓库根 + HEAD + 工作区改动摘要」。任一变化 → 换一个母本目录 → 自然重铺；
# 没变化 → 命中同一个目录 → 保住"每会话只 tar 一次"的收益。
codev_master_path() {
  local root sig h
  root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$root" ] || return 1
  # 工作区签名：HEAD + `git status --porcelain` 摘要（含未跟踪/已暂存），足以捕捉"改了代码再评一轮"。
  sig="$root|$(git rev-parse HEAD 2>/dev/null)|$(git status --porcelain --untracked-files=all 2>/dev/null | cksum)"
  # cksum 是 POSIX、bash/zsh/macOS/Linux 都有（不用 md5/sha1sum：前者 macOS 无 -r 之外差异、后者 macOS 没有）。
  h=$(printf '%s' "$sig" | cksum | tr -cd '0-9')
  CODEV_MASTER="$CODEV_DIR/codev-master-repo.${h:-0}"
  return 0
}

# codev_repo_master — 把工作区铺成【母本】 $CODEV_MASTER（只做一次，已存在就直接复用）。
# 返回 0=可用，1=不可用（非 git / 超闸门 / 失败）。
codev_repo_master() {
  codev_master_path || return 1     # 先按仓库+工作区状态定母本路径，避免复用到别的树
  [ -d "$CODEV_MASTER" ] && return 0        # 已铺好，复用
  # holder 必须在这里【一次性】声明：写成循环体内的 `local holder` 会在 zsh 下每轮打印
  # 「holder=<pid>」污染输出——zsh 未设 TYPESET_SILENT 时，对【已存在】的变量再执行不带赋值的
  # local/typeset 会显示它的当前值（实测等待循环每秒吐一行）。bash 无此行为。
  local root sz holder lock="$CODEV_MASTER.lock" waited=0
  # 【并发护栏】fan-out 时 N 个 agent 是 N 个独立 shell、会同时进到这里。没有锁的话它们会
  # 同时往同一个母本目录 tar，解出交错/截断的文件（agent 读到半个文件比读不到更糟）。
  # mkdir 是原子的：抢到的铺母本，没抢到的等它铺完再复用。
  until mkdir "$lock" 2>/dev/null; do
    [ -d "$CODEV_MASTER" ] && return 0      # 别人铺好了，直接用
    # 【陈旧锁回收】持锁进程可能已被杀（前台超时/Ctrl-C），锁却留着。不回收的话本会话
    # 后续每个 agent 都要白等满 300s 再退回 text 模式（等于副本功能静默失效）。
    # 判活【先看 PID 再看 mtime】：只凭 mtime 会偷走活锁——铺母本在慢盘/接近闸门的大仓上
    # 可能真的超过阈值，此时持锁者还在写，回收方却删掉它的锁和 .partial，两个进程同时往
    # 同一个 .partial 解 tar → 母本交错/截断（波及全部 agent）。`kill -0` 判进程是否还在。
    # 注意 -mmin +2 因 find 按整分钟截断，实际语义是【≥3 分钟】，仅作为 PID 丢失时的兜底。
    if [ -n "$(find "$lock" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then
      holder=$(cat "$lock/pid" 2>/dev/null)
      # 持锁者还活着就不回收，继续等——宁可等满 300s 退回 text，也不能让两个 builder 并存。
      if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
        :
      else
        # 确认已死：把 .partial 改名再删，避免旧持锁者的 mv 恰好发布半成品。
        mv "$CODEV_MASTER.partial" "$CODEV_MASTER.partial.dead.$$" 2>/dev/null
        rm -rf "$CODEV_MASTER.partial.dead.$$" "$lock"
        # 【不能 continue】：回收失败时（如会话目录不可写）锁还在，continue 会跳过下面的
        # sleep 与 waited++ → 变成无 sleep 的忙等，把一个核吃满且永不退出（实测 timeout 124、
        # spins 上万）。故这里【不跳过】计时与休眠，让它照常走满 300s 再退回 text 模式。
        mkdir "$lock" 2>/dev/null && break     # 回收成功就立刻抢到锁，进入铺母本
      fi
    fi
    waited=$((waited+1))
    [ "$waited" -gt 300 ] && return 1       # 等超过 ~300s 判失败（母本再大也该好了），退回 text 模式
    sleep 1
  done
  echo $$ > "$lock/pid" 2>/dev/null   # 记下持锁者，供上面的 kill -0 判活
  # 拿到锁了。下面用子 shell 包住全部工作，出口统一放锁——
  # 【不能】在中途直接 return：那样锁不会被删，同会话后续 agent 全卡死在上面的 until。
  local rc=0
  (
    root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 1
    [ -n "$root" ] || exit 1
    # 体积闸门：只统计将被拷的文件（已被 .gitignore 排除的 node_modules/build 产物天然不计入）。
    # BSD xargs 无 -r，用 `|| true` 吞空输入；du 可能被 xargs 分批多次调用，awk 累加即可。
    # ⚠️ cd 必须在【整条管道之外】（即命令替换的子 shell 里）：若写成 `{ cd "$root" && git ls-files; } | xargs du`，
    # cd 只作用于管道左段的子 shell，右段的 du 仍在原 cwd 解析相对路径 → 全部 No such file → 恒得 0，闸门形同虚设。
    sz=$( cd "$root" 2>/dev/null && { git ls-files -z; git ls-files --others --exclude-standard -z; } \
          | { xargs -0 du -sk -- 2>/dev/null || true; } | awk '{s+=$1} END{print s+0}' )
    # 注：本机 xargs 空输入不执行命令（实测），故空仓库不会让 du 误measure整个 cwd；
    # 但【别指望 `|| true` 挡这个】——它只吞退出码，不阻止命令被空跑。若移植到会空跑的
    # xargs 版本上，需改成先判文件列表是否为空。
    [ "${sz:-0}" -gt "$CODEV_MAX_COPY_KB" ] 2>/dev/null && exit 1
    # 先解到 .partial 再原子改名：万一进程在解压中途被杀，留下的是 .partial，
    # 下次不会被 `[ -d "$CODEV_MASTER" ]` 误判成"已铺好"而让 agent 读到半个仓库。
    rm -rf "$CODEV_MASTER.partial"
    mkdir -p "$CODEV_MASTER.partial" || exit 1
    # tar 按 cwd 相对路径打包，故必须先 cd 进仓库根；--null -T - 读 NUL 分隔文件名（含空格/换行也安全）。
    # --exclude 过滤明显的密钥载体：副本会被外部模型读取，凡进副本的内容都视同已发送出去。
    # （不用 grep 过滤文件名列表：本机 grep 可能是 ugrep，其 -z 是"解压"而非 NUL 分隔，行为不一致；
    #   tar 的 --exclude 在 GNU tar / bsdtar 上都支持，更稳。）
    # ⚠️ --no-recursion 是【必须的】：git ls-files 对 submodule 只输出一个 mode 160000 的
    # 目录路径（如 `sub`），tar 收到目录默认会【递归整个已初始化 submodule】——连 submodule
    # 自己的 untracked / 被它 .gitignore 忽略的文件一起打包（实测 sub/untracked_secret.txt
    # 进了包）。那既违反"tracked + 未忽略 untracked"的内容约定，也可能把私密数据发给外部模型。
    # 加了它，目录项只建空目录、不下钻；普通文件因 ls-files 已逐个列出，不受影响（实测）。
    # ⚠️ 必须把列表过滤成【当前真实存在的路径】再喂给 tar：`git ls-files` 列的是索引内容，
    # 已删未提交的 tracked 文件（`git rm` 前的 ` D` 状态，review 场景最常见的改动之一）仍在列表里，
    # tar 对它报 "Cannot stat" 并【整体退出非零】。配合上面的 pipefail，母本构建就此判失败 →
    # 每个沙盒 agent 静默退回 text 模式、`./repo` 功能全废（实测：删一个 tracked 文件即触发，
    # codev_repo_master rc=1、母本不存在）。bsdtar 不支持 --ignore-failed-read（实测 "not supported"），
    # 故只能在管道里先筛。-e 对 broken symlink 为假，补 -L 保住它（symlink 稍后统一 -delete）。
    ( set -o pipefail 2>/dev/null   # 让左段 git/tar 的失败也能传出去，不被右段 tar -xf 的 0 掩盖
      cd "$root" && { git ls-files -z; git ls-files --others --exclude-standard -z; } \
        | { while IFS= read -r -d '' f; do
              { [ -e "$f" ] || [ -L "$f" ]; } && printf '%s\0' "$f"
            done; } \
        | tar -cf - --null -T - --no-recursion \
            --exclude='.env' --exclude='*.env' --exclude='.env.*' --exclude='.envrc' \
            --exclude='*.pem' --exclude='*.key' --exclude='*.p12' --exclude='*.pfx' \
            --exclude='id_rsa*' --exclude='id_dsa*' --exclude='id_ecdsa*' --exclude='id_ed25519*' \
            --exclude='*.keystore' --exclude='*.jks' --exclude='.netrc' --exclude='.npmrc' \
            --exclude='*.tfvars' --exclude='*.tfstate' --exclude='*.tfstate.*' \
            --exclude='.git' \
        | ( cd "$CODEV_MASTER.partial" && tar -xf - ) ) 2>/dev/null \
      || { rm -rf "$CODEV_MASTER.partial"; exit 1; }
    # 【P1 修复：symlink 穿透】tar 原样保留 tracked symlink。若仓库含指向仓库外的绝对路径
    # 链接，agent 经 ./repo/link 就能读到沙盒外的真实文件；更糟的是【能写穿】——实测
    # `chmod -R a-w` 之后 `echo X > repo/link` 仍成功改掉了真实目标（chmod 只改 symlink
    # 自身权限位，不保护目标）。那会击穿"写入只落在副本上"这条主防线，故一律删掉链接。
    find "$CODEV_MASTER.partial" -type l -delete 2>/dev/null
    # 大小写盲区：--exclude 的 fnmatch 大小写敏感（实测 UPPER.KEY / .ENV 不被排除），
    # 故再用 -iname 做一轮大小写不敏感清扫兜底。
    # ⚠️ 必须加 -type f：不加会匹配到目录，`-delete` 虽拒删非空目录，但空目录/单文件目录仍会
    # 连带整棵子树消失。
    # 【这一轮必须覆盖 tar --exclude 的【全部】文件名模式】，否则该项的大小写变体就成了裸奔——
    # tar 那边大小写敏感，这里是唯一的兜底。改动任一边都要同步另一边（`*.key`/`*.env`/`*.jks`/
    # `id_*` 曾在一次修 credentials 的提交里被漏掉，导致 SERVER.KEY / PROD.ENV / ID_RSA 直接进副本）。
    # credentials* 不在这一轮里，它有自己的一轮（见下），因为需要额外的源码扩展名白名单。
    find "$CODEV_MASTER.partial" -type f \( -iname '.env' -o -iname '*.env' -o -iname '.env.*' \
         -o -iname '.envrc' -o -iname '*.pem' -o -iname '*.key' -o -iname '*.p12' \
         -o -iname '*.pfx' -o -iname '*.keystore' -o -iname '*.jks' -o -iname '.netrc' \
         -o -iname '.npmrc' -o -iname 'id_rsa*' -o -iname 'id_dsa*' \
         -o -iname 'id_ecdsa*' -o -iname 'id_ed25519*' \
         -o -iname '*.tfvars' -o -iname '*.tfstate' -o -iname '*.tfstate.*' \) -delete 2>/dev/null
    # credentials 单独一轮：宽通配能挡住 gcp-credentials.json / aws_credentials /
    # credentials.yml.enc 这类前缀后缀变体（实测 8/8），但会连 credentials.go /
    # credentials_manager.dart / CredentialsProvider.kt 这类【合法源码】一起删（实测 9/9 全中）。
    # 故先按名字宽匹配、再用 ! -iname 把常见源码扩展名摘出来（实测 8/8 挡住、0/9 误删）。
    # 只在这里挡、不进 tar --exclude：tar 按路径分量匹配会整体吃掉 src/credentials/ 目录。
    find "$CODEV_MASTER.partial" -type f -iname '*credentials*' \
         ! -iname '*.go' ! -iname '*.dart' ! -iname '*.ts' ! -iname '*.tsx' ! -iname '*.js' \
         ! -iname '*.jsx' ! -iname '*.py' ! -iname '*.rs' ! -iname '*.java' ! -iname '*.kt' \
         ! -iname '*.swift' ! -iname '*.rb' ! -iname '*.php' ! -iname '*.cs' ! -iname '*.c' \
         ! -iname '*.h' ! -iname '*.cpp' ! -iname '*.hpp' ! -iname '*.sh' ! -iname '*.vue' \
         ! -iname '*.md' ! -iname '*.txt' -delete 2>/dev/null
    # mv 前守卫：目标已存在时 `mv dir existingdir` 会把源【移进】目标里（实测 rc=0，
    # 得到 M/codev-master-repo.partial），`||` 分支根本不触发 → 母本里留个嵌套垃圾目录。
    [ -e "$CODEV_MASTER" ] && { rm -rf "$CODEV_MASTER.partial"; exit 0; }   # 别人已铺好，复用
    mv "$CODEV_MASTER.partial" "$CODEV_MASTER" || { rm -rf "$CODEV_MASTER.partial"; exit 1; }
  ); rc=$?
  # 放锁：无论上面成败都执行。用 rm -rf 而不是 rmdir——锁目录里有 pid 文件（非空），
  # rmdir 会静默失败（实测：锁泄漏 → 同会话后续每个 agent 白等 300s 再退回 text 模式，
  # 副本功能静默失效）。空值守卫防 CODEV_MASTER 意外为空时 rm -rf 打到 ".lock" 之外的东西。
  [ -n "$lock" ] && rm -rf "$lock" 2>/dev/null
  return $rc
}

codev_repo_copy() {
  local sbox="$1"
  codev_repo_master || return 1              # 母本（每会话只 tar 一次）
  # 从母本给这个 agent 拷一份【独立】副本：`cp -c` 在 APFS 上走 clonefile（写时复制）——
  # 秒级完成、几乎不占额外磁盘，但各 agent 之间【互不影响】（实测改 clone1 不影响母本和 clone2）。
  # 非 APFS / 不支持 -c 的平台自动退回普通 cp -R（-c 失败时重试一次）。
  # 为什么不用硬链接共享一份：硬链接是【同一个 inode】，任一 agent 若绕过 chmod 改了文件，
  # 会串到所有 agent 和母本；clone 是写时复制，改动只落在自己那份。
  # ⚠️ 回退前【必须】清掉残缺目标：`cp -c` 若在建好 $sbox/repo 之后才失败（ENOSPC、跨卷、
  # 个别 inode 不支持 clonefile），紧接着的 `cp -R src dst`【dst 已存在】语义变成"拷进 dst 内部"
  # → $sbox/repo/codev-master-repo/…，且 rc=0（实测）。agent 看到的 ./repo 布局全错、
  # 提示词里承诺的路径全部失效，而 ▶ 行仍显示"只读仓库副本"，故障完全静默。
  cp -c -R "$CODEV_MASTER" "$sbox/repo" 2>/dev/null \
    || { rm -rf "$sbox/repo"; cp -R "$CODEV_MASTER" "$sbox/repo" 2>/dev/null; } \
    || { rm -rf "$sbox/repo"; return 1; }   # 失败也自清理：否则 text 模式下会残留半个 repo
  chmod -R a-w "$sbox/repo" 2>/dev/null   # 纵深防御：误写立即报错，而不是静默改副本
  return 0
}

# codev_bg_sandboxed <agent> <cmd...> — 非原生只读 agent
# （reasonix / qoderclicn / opencode / codebuddy）：在【隔离沙盒】里跑，cwd 够不到真实仓库
# → 从根本上免掉快照/污染问题。默认沙盒里带一份只读仓库副本（见 codev_repo_copy），
# 设 CODEV_SANDBOX_MODE=text 可退回旧的"空目录只喂文本"。
# 输出走会话目录字面路径 $CODEV_DIR/codev-out-<agent>.txt。
# 用法：codev_bg_sandboxed reasonix reasonix run "$(cat "$PROMPT")" --effort high -p
#       （首个参数是 agent 标签，其后是要执行的完整命令 argv；"$(cat)" 由调用方先展开成单个 arg。）
codev_bg_sandboxed() {
  local agent="$1"; shift
  local out="$CODEV_DIR/codev-out-$agent.txt" err="$CODEV_DIR/codev-err-$agent.txt"
  # 【任何提前返回之前就清空】：Claude 按字面路径读 $out，若本轮没跑成而文件还留着上一轮的
  # 评审正文，那份陈旧内容会被当成本轮结论逐字呈现（最坏情况：上一轮说 FAIL 的问题已修好，
  # 这轮却又拿旧文本判一次 FAIL）。所以清空必须在 timeout 缺失、mktemp 失败等所有出口之前。
  : > "$out"; : > "$err"
  if [ -z "$CODEV_TO" ]; then     # 无 timeout：后台裸跑会永久挂起 → 跳过，不阻塞其它
    echo "⏭ $agent 跳过（无 timeout，后台无兜底）→ 改前台串行或先 brew install coreutils"
    return 0
  fi
  local sbox rc mode
  sbox=$(mktemp -d -t codev-sbox.XXXXXX) || { echo "⚠️ $agent mktemp 失败"; return 1; }
  if [ "$CODEV_SANDBOX_MODE" = repo ] && codev_repo_copy "$sbox"; then
    # 副本可能【建成了但里面没东西】：空仓库、或全部文件都命中密钥过滤（实测两种都 rc=0、0 文件）。
    # 此时提示词还在承诺"可以读 ./repo 核实"，agent 找不到任何代码 → 又回到"瞎子"状态，
    # 而 ▶ 行却显示副本就绪，用户无从察觉。故实测文件数，为 0 就如实标出。
    if [ "$(find "$sbox/repo" -type f 2>/dev/null | head -1)" ]; then
      mode="隔离沙盒 + 只读仓库副本 ./repo"
    else
      mode="隔离沙盒 + ./repo（⚠️ 副本内 0 个文件：空仓库或全被密钥过滤挡下，agent 无代码视野）"
    fi
  else
    # 兜底清残留：copy 失败路径已自清理，这里再保一手——否则 agent 被告知"空目录"，
    # cwd 里却躺着半个 repo，它若发现了就会基于残缺代码评审（比看不到更糟）。
    rm -rf "$sbox/repo" 2>/dev/null
    mode="隔离空目录（只喂提示词文本）"
  fi
  # 用 printf 传 $mode：变量展开【紧邻全角字符】时 bash 在 UTF-8 locale 下会误扫、吞掉后半行
  # （实测 echo "…（$mode）" 只输出到"启动（"就截断）。同 codev_report 里 $rc 的处理。
  printf '▶ %s 启动: %s\n' "$agent" "$mode"
  # umask 077 放进子 shell：输出含 diff/可能密钥仅本人可读，且【不把 umask 泄漏给调用方 shell】。
  ( umask 077; cd "$sbox" && codev_run "$@" < /dev/null > "$out" 2>"$err" ); rc=$?
  # 副本被 chmod a-w，rm 需要先恢复目录写权限；空值守卫防 mktemp 失败时 rm -rf ""
  [ -n "$sbox" ] && { chmod -R u+w "$sbox" 2>/dev/null; rm -rf "$sbox"; }
  codev_report "$agent" "$rc" "$err" # 捕【agent】退出码，不是 rm 的
}

# codev_bg_native <agent> <cmd...> — 原生只读 agent（codex `-s read-only` / gemini `--approval-mode plan`）：
# 无需沙盒（沙盒级只读保证），在【当前 cwd（应为仓库根）】跑。输出同样走字面路径。
# 用法：codev_bg_native codex codex review "$(cat "$PROMPT")" -c 'model_reasoning_effort="medium"'
codev_bg_native() {
  local agent="$1"; shift
  local out="$CODEV_DIR/codev-out-$agent.txt" err="$CODEV_DIR/codev-err-$agent.txt"
  : > "$out"; : > "$err"          # 同 sandboxed：所有提前返回【之前】就清空，防呈现上一轮陈旧评审
  echo "▶ $agent 启动（原生只读，真实仓库 cwd）"
  if [ -z "$CODEV_TO" ]; then
    echo "⏭ $agent 跳过（无 timeout，后台无兜底）→ 改前台串行或先 brew install coreutils"
    return 0
  fi
  local rc
  # umask 077 放进子 shell：不把 umask 泄漏给调用方 shell（前台/内联退化场景会残留 0600）。
  ( umask 077; codev_run "$@" < /dev/null > "$out" 2>"$err" ); rc=$?
  codev_report "$agent" "$rc" "$err"
}

# codev_sbox_gc — 清理【残留沙盒】。正常路径下 codev_bg_sandboxed 收尾会删掉自己的沙盒，但
# 进程被杀时（前台工具超时、Ctrl-C、机器重启）收尾跑不到，沙盒就漏在 TMPDIR 里。
# 空目录时代漏了无所谓，现在沙盒里有整份仓库副本 → 会堆磁盘、也留代码残迹，所以要定期扫。
# 只删【60 分钟前】的：codev_run 上限 600s，超过 60 分钟的必然是死掉的，不会误删并发 run 的活沙盒。
codev_sbox_gc() {
  local t="${TMPDIR:-/tmp}" d n=0
  # -mmin 是 BSD/GNU find 都有的；-maxdepth 1 防递归进副本内部。副本被 chmod a-w，rm 前先恢复写权限。
  # 只扫【沙盒】：沙盒天生短命（单次 agent 调用，最长 600s），超 60 分钟必是死掉的。
  # ⚠️ 【不要】把会话目录 codev.* 也按 60 分钟扫：会话目录是长命的（用户看完输出、讨论、再跑一轮
  #    很容易超过 1 小时），且并发的另一个 /codev run 的会话目录同样匹配 —— 那样会删掉别人正在用的
  #    母本/提示词/输出。会话目录由 skill 收尾的 `rm -rf "$CODEV_DIR"` 负责（母本就在里面，一并清）；
  #    进程被杀漏下的由下面 24 小时那轮兜底。
  # 用 -print0 + read -d '' 而不是 `for d in $(find …)`：后者依赖词拆分，$TMPDIR 含空格/换行时
  # 会把一个路径拆成多个删除目标（如 `/tmp/work dir/codev-sbox.x` → 试图删 `/tmp/work`）。
  # （注：命令替换在 bash 和 zsh 下【都会】词拆分，这不是 zsh 特有问题——别被"zsh 不拆分"
  #   的说法误导，那条只适用于未加引号的【变量】展开。）
  while IFS= read -r -d '' d; do
    chmod -R u+w "$d" 2>/dev/null; rm -rf "$d" 2>/dev/null && n=$((n+1))
  done < <(find "$t" -maxdepth 1 -type d -name 'codev-sbox.*' -mmin +60 -print0 2>/dev/null)
  # 会话目录（含母本，可能几十 MB）用 24 小时这档兜底：够长，不会撞上"用户慢慢看输出"或并发 run；
  # 且显式跳过【本次会话】自己的目录。
  while IFS= read -r -d '' d; do
    [ "$d" = "$CODEV_DIR" ] && continue
    chmod -R u+w "$d" 2>/dev/null; rm -rf "$d" 2>/dev/null && n=$((n+1))
  done < <(find "$t" -maxdepth 1 -type d -name 'codev.*' -mmin +1440 -print0 2>/dev/null)
  [ "$n" -gt 0 ] && echo "已清理 $n 个残留沙盒/会话目录（沙盒超 60 分钟、会话目录超 24 小时）"
  return 0
}

# codev_auth_codex — codex 多信号鉴权检查（env 或 auth.json）。输出 AUTH_OK / AUTH_FAILED。
# 避免只查文件对 env-auth 用户（CI/平台）误报。
codev_auth_codex() {
  local home="${CODEX_HOME:-$HOME/.codex}" k1 k2
  k1=$(printf '%s' "${CODEX_API_KEY:-}" | tr -d '[:space:]')
  k2=$(printf '%s' "${OPENAI_API_KEY:-}" | tr -d '[:space:]')
  if [ -n "$k1" ] || [ -n "$k2" ] || [ -f "$home/auth.json" ]; then
    echo "AUTH_OK"; return 0
  fi
  echo "AUTH_FAILED"; return 1
}

# codev_probe — Step 0 探测：列出 OK/MISS 的 agent CLI + timeout 状态。
# codex 命中时顺带跑 codev_auth_codex 附上鉴权结论（AUTH_OK/AUTH_FAILED），
# 便于 Claude 把未鉴权的 codex 提前剔出可选项，不浪费一轮后台任务。
codev_probe() {
  local c
  codev_sbox_gc          # 顺手回收上一轮被杀进程漏下的沙盒（含仓库副本，会堆磁盘）
  for c in codex gemini reasonix qoderclicn opencode codebuddy; do
    if command -v "$c" >/dev/null 2>&1; then
      if [ "$c" = codex ]; then echo "OK   codex ($(codev_auth_codex))"; else echo "OK   $c"; fi
    else
      echo "MISS $c"
    fi
  done
  echo "timeout -> ${CODEV_TO:-MISSING}"
}
