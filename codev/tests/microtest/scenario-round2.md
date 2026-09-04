你是正在执行 `/codev` skill 的 Claude Code。skill 目录：`SKILL_DIR`（先 Read 其中的 SKILL.md，再按需 Read references/ 下的文件）。

用户在仓库 `/Users/zenyu/Project/Tms/ntms`（分支 feat/finance-statement-ops）里输入：

    /codev review docs/superpowers/specs/2026-09-04-finance-statement-ops-design.md --round 2 --auto --max-rounds 3 --agents codex,reasonix 重点看锁序

背景事实（全部假定成立，不要去验证）：
- 第 1 轮已跑完并回流，回流 commit 是 `abc1234`（只改了这份 spec，v1.0 → v1.1）。工作树里除了这份 spec 之外还有一个用户自己未提交的无关改动 `src/backend/app/modules/m06_finance/service.py`。
- 第 1 轮的综合结论：codex（模型 gpt-5.6-sol）提了 3 条 P1，其中 2 条经你亲验成立并已回流（`register_payment` 写入表漏 `tenant_id`；锁序总则未覆盖 `add_adjustment`），1 条被你亲验驳回（它说 `advisory_lock_recon_customer` 不存在，实际在 `app/shared/pg_locks.py:84`）。reasonix（模型 deepseek-v4）提了 1 条 P2 已采纳（事件表缺 `seq` 唯一约束的措辞）。
- Step 0 探测：codex OK(AUTH_OK)、reasonix OK、其余 MISS；timeout 已装。

**限制**：不要真的运行任何外部 agent CLI，不要建会话目录，不要调用 AskUserQuestion，不要真的 commit。你只需要产出三份文件到 `OUT_DIR/`：
1. `codev-prompt-reasonix.txt` —— 你将发给 reasonix 的**完整提示词文件内容**（逐字）。
2. `commit-msg.txt` —— 第 2 轮回流后你会用的 git commit 信息全文，以及你会执行的精确 `git add` / `git commit` 命令（写在文件末尾）。
3. `notes.md` —— 从收到命令到本轮结束你会按什么顺序做哪些步骤（含在发外审之前做什么、怎么判断要不要开第 3 轮、什么情况下停）。

写完三份文件就停止。
