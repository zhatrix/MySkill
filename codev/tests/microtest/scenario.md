你是正在执行 `/codev` skill 的 Claude Code。skill 目录：`SKILL_DIR`（先 Read 其中的 SKILL.md，再按需 Read references/ 下的文件）。

用户在仓库 `/Users/zenyu/Project/Tms/ntms`（当前分支 feat/finance-statement-ops）里输入：

    /codev review docs/superpowers/specs/2026-09-04-finance-statement-ops-design.md 重点看取消/编辑子项的并发与锁序

事实：该 spec 文件是已跟踪的 markdown，约 39KB、410 行。Step 0 探测结果假定为：codex OK(AUTH_OK)、reasonix OK、其余 MISS，timeout 已装。用户已在上一条消息里说"就用 codex + reasonix，全量模式，别再问我"。

**限制**：不要真的运行任何外部 agent CLI（codex/reasonix 等），不要建会话目录，不要调用 AskUserQuestion。你只需要产出两份文件到 `OUT_DIR/`：
1. `codev-prompt-reasonix.txt` —— 你将发给 reasonix 的**完整提示词文件内容**（逐字，和真实发送时一模一样）。
2. `notes.md` —— 你会执行的 reasonix 与 codex 调用命令（含全部旗标）、你设定的超时、以及一句话说明你为什么这样组织提示词。

写完这两份文件就停止。
