---
name: vcs-recent-changes
triggers: ["昨天", "最近", "最后一次", "上一笔", "提交", "修改", "变更", "git log", "svn log", "commit", "branch", "分支", "审查", "diff", "搜提交"]
tools: [lastCommit, commitDiff, commitFiles, recentCommits, dailyReview, searchCommits, reviewChangeImpact, reviewPackage, listFiles, searchCode, readFile, getSymbolSource]
---

## 技能：VCS 变更查询（先选对工具）

### 选工具（强制）

| 用户说法 | 用 | 不要用 |
|---------|----|--------|
| 最后一次 / 最近一次 / 上一笔提交 / 刚提交了什么 | `lastCommit` | `dailyReview`、大 `days` |
| 最近 10 条 / 最近几次 | `recentCommits` limit=10 | `dailyReview days=30` |
| 昨天改了什么 / 按天审查 | `dailyReview` days=**1** | 臆造 days=30 |
| 最近 7 天/一个月汇总 | `dailyReview` days=用户说的数字 | — |
| message 里搜关键词 | `searchCommits` | — |
| 看某 hash 改了什么 | `commitDiff` / `commitFiles` | — |
| 影响面 + 是否改对 | 先有 ref，再 `reviewChangeImpact` | 一上来就 dailyReview |

### 流程

1. **先对齐意图**：是「一条」还是「一段时间」？没说天数就不要加 `days`。
2. **最后一次** → 只调 `lastCommit`，读完再决定要不要 `reviewChangeImpact`。
3. **按天** → `dailyReview`；默认 1 天；只有用户明确说 N 天/一周/一个月才加大 `days`。
4. **下钻** → 对感兴趣的 ref 用 `commitDiff` / `readFile` / `reviewChangeImpact`。

### 注意

- git/svn 自动识别；进程内 `open_port`，不是 runMfa 黑名单问题
- `notVcsRepo` 时看 hint（PATH / projectRoot / safe.directory）
