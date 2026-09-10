# codev 全库自审：2026-09-11

本次以 `dc14c10` 为审前版本，逐段检查 `bin/codev-lib.sh` 全部函数、`tests/test-lib.sh`、文案微测试脚本及主要调用说明。确认并修复六类问题；新增 21 项回归，最终 bash、zsh 均为 `pass=197 fail=0`。

验证使用一次性 Git 仓库、临时账本、假 CLI 与结构化输出夹具，没有调用真实外部模型、修改 ntms 或执行 push。最初新增夹具在旧库上出现 15 项失败，随后补充 textconv 与 JSON 解包权限检查。没有把库测试通过视为整个评审协议迁移完成。

## 已修复问题

| ID | 级别 | 触发及原行为 | 最终行为与验证 |
|---|---|---|---|
| lib-01 | P1 | 未跟踪文件 `a=ab,b=c` 改成 `a=a,b=bc`，文件列表和拼接内容均未变，签名相同，可能复用旧母本；初始仓库缺 HEAD、textconv 隐藏差异、上游哈希失败也会削弱签名 | 未跟踪文件纳入路径与长度；初始仓库以空树为基线；禁用 textconv；读取与哈希失败向上传播。分别用内容边界、初始已暂存文件、恒定 textconv、失败哈希夹具验证 |
| lib-02 | P1 | `codev_commit_round '*.md' ...` 中的 `--` 只终止选项，仍会展开 Git pathspec，把多个未指定文件一起提交 | 所有暂存检查、add、commit、失败撤回统一使用 `git --literal-pathspecs`。无对应字面文件时不提交；真实名为 `*.md` 的文件可以单独提交，其它改动不入库 |
| lib-03 | P2 | `find -exec cp` 的单文件失败没有成为归档失败，仍显示“已归档”；slug `..` 和包含路径分隔符的轮次可改变目标路径 | 使用 NUL 文件清单逐个检查复制状态；失败返回非零并标目标可能不完整；拒绝点路径 slug 和非数字轮次。既有 worktree 忽略规则测试继续通过 |
| lib-04 | P2 | 同一 agent 再次调用只清 stdout/stderr，上一轮 metrics 仍在；第二轮无计量时继续报告旧 token 和成本 | native、sandboxed 共用调用准备函数，启动或提前跳过前删除旧 metrics；文件准备失败则不启动。夹具预置 910 tokens、2 USD 后调用不产计量的 CLI，最终账本两项均为缺失值 |
| lib-05 | P2 | stdout/stderr 在 `umask 077` 子 shell 之前创建，调用者 umask 为 022 时实际是 0644；JSON 解包原子替换也会重新扩大权限 | 调用准备在独立子 shell 中创建并显式 chmod 600；解包临时文件按 0600 创建并校验设置。普通和 JSON 输出均验证权限，不改变调用者 umask。此处修正的是文件权限承诺，不宣称原临时目录保护已被突破 |
| lib-06 | P1 | 结构化结果 `is_error=true`、`subtype=error_max_turns`，正文包含 `# Partial / PASS` 且进程 rc=0，会被报告为成功；坏 usage 在解析失败前已覆盖原正文 | report 优先采用结构化失败状态，超时仍优先；空错误结果用 subtype 表明失败；usage 形状先校验再写入。分别验证 turn 耗尽、其它错误、空错误结果及坏 usage 保留原文；最后补修进一步验证坏 usage、metrics 写入和正文替换失败均不丢失已识别的错误状态 |

## 其它检查与边界

- 上一批意见回放修复继续通过：最新判断计票、任务/仓库/对象/轮次隔离、P1 级别分歧、缺失修法及旧账本保守回放
- 原有并发母本构建、只读副本、扫描后漂移、失败提交恢复索引、超时和 GC 回归均继续通过
- 文案微测试的生成和打分脚本已阅读；未执行 Claude 的完整 3+3 文案实验或真实外部 agent 流程
- spec 的固定版本、任务状态持久化、角色选择及取消固定 G1/G2 仍是独立迁移工作；本次未把 `codev_prev_round_commit` 当成已实现的审前/审后快照机制
- token 字段仍保留各 CLI 当前口径，本次解决的是旧 metrics 串轮，没有宣称完成跨模型缓存计量统一

## 验证记录

```text
bash tests/test-lib.sh  → pass=197 fail=0
zsh  tests/test-lib.sh  → pass=197 fail=0
bash -n bin/codev-lib.sh → 通过
zsh  -n bin/codev-lib.sh → 通过
git diff --check        → 通过
```

修复及最后补修均已重新检查实际差异；变化逐项记录在 [CHANGELOG](../CHANGELOG.md)。
