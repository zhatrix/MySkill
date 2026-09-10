# Changelog

本文件记录 codev 自身的实际变更；目标项目的 spec / 计划回流历史保存在对应项目。记录从本次接入起建立，
更早版本可通过 Git 历史及 `reports/2026-09-10-ntms-usage-audit.md` 追溯，不在此虚构历史版本。

## [Unreleased]

### 🚀 Added

- 2026-09-10 [C001] `SKILL.md`、`references/synthesis.md` 与 `references/changelog.md` 的 prowler-changelog 调用协议，每项实际变更记录对象、阶段、关联发现及验证状态，修复提交显式包含日志；skill 结构及文案一致性已核对，现有库测试 bash/zsh 各 137 项通过，实际编排器调用待真机验证
- 2026-09-10 [C002] `reports/2026-09-10-ntms-usage-audit.md` 的 ntms 使用审计，核对 9 月 5 日至 10 日的调用记录、缓存统计口径及回流缺陷；引用路径和统计加总已核对
- 2026-09-10 [C003] `specs/2026-09-10-review-protocol-v2.md` 的评审协议草案，定义角色选择、一致判断、固定版本、完整差异交付、修复后验收、旧账本兼容及自动本地提交；文档自审、章节与本地引用检查完成，人数上限作用范围待确认，协议实现尚未开始
