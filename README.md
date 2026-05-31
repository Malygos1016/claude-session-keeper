# claude-session-keeper

> 重启 / 断电后，一键把之前开着的所有 Claude Code CLI 窗口 `resume` 回来 —— 各自回到原工作目录、原会话、上下文还在。

每次电脑重启，所有 Claude Code 终端窗口都消失了，要一个个手动开终端、`cd` 到目录、再 `claude --resume` 挑会话，很烦。这个小工具把这件事变成开机后敲一个 `ccr`。

适用：**Windows 10 / 11**。

---

## 它是怎么工作的

Claude Code 自己维护着一份"正在运行的会话"注册表，每个交互窗口一份 JSON：

```
~/.claude/sessions/<PID>.json   →  { sessionId, cwd, kind, status, ... }
```

干净退出会删掉对应文件，**但硬关机 / 断电不会删**。问题是：Claude Code **下次启动时会清理掉这些死进程记录** —— 这正是"重启后窗口就找不回来了"的根因。

所以本工具的做法是：

1. **`snapshot.ps1`** —— 一个计划任务**每 2 分钟**把当前的会话注册表存档一份到 `~/.claude/session-keeper/snapshots/`（带开机时间戳，不会被 Claude 清理）。
2. **`restore.ps1`（`ccr`）** —— 读取"本次开机**之前**最后一份存档"，那就是断电那一刻还开着的窗口集合，然后逐个 `claude --resume <id>`，开成 Windows Terminal 的多个标签页，每个回到它原来的工作目录。

```
        平时（每 2 分钟）                          重启后（敲 ccr 一次）
  ┌──────────────────────────┐             ┌──────────────────────────────┐
  │ ~/.claude/sessions/*.json│  ──存档──▶  │ snapshots/<ts>.json          │
  │ (Claude 自带,重启会被清)  │             │ (本工具维护,重启后还在)        │
  └──────────────────────────┘             └──────────────┬───────────────┘
                                                          │ ccr 读"开机前最后一份"
                                                          ▼
                                          wt 多标签：claude --resume <每个 id>
                                          各自回到原 cwd、原会话
```

---

## 依赖

| 依赖 | 必需？ | 说明 |
|---|---|---|
| **PowerShell 7（`pwsh`）** | ✅ 必需 | `restore.ps1` 用了 PS7 语法。没有就 `winget install Microsoft.PowerShell` |
| **Claude Code CLI**（`claude.cmd`） | ✅ 必需 | 装在 `%APPDATA%\npm` 或 PATH 上 |
| **Windows Terminal**（`wt`） | ⭕ 可选 | 没有则退回"每个会话一个独立窗口"，功能不受影响 |

---

## 安装

```powershell
# 1) 克隆（或下载 zip 解压）到任意位置，推荐放在 .claude 下
git clone https://github.com/Malygos1016/claude-session-keeper.git "$env:USERPROFILE\.claude\session-keeper"

# 2) 运行安装器（幂等，可反复跑）
pwsh -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\session-keeper\install.ps1"

# 3) 重开一个终端，验证
ccr -WhatIf
```

`install.ps1` 会做三件事（都幂等）：

- 把 `ccr` 别名写进 **PowerShell 7 和 Windows PowerShell 5.1 两个 `$PROFILE`**（不管你默认开哪个都能用）；
- 在桌面建快捷方式 **「恢复Claude会话」**（双击即恢复）；
- 注册计划任务 **`ClaudeSessionKeeper-Snapshot`**，每 2 分钟存档一次（无权限时自动退回"登录启动项 VBS"，免管理员）。

> 放哪都行 —— 安装器按脚本所在位置自动接线，不写死路径。

---

## 用法

重启后，开任意终端敲：

```powershell
ccr
```

（或双击桌面「恢复Claude会话」。）

| 命令 | 作用 |
|---|---|
| `ccr` | 恢复"本次开机前"那批窗口 |
| `ccr -WhatIf` | 只预览要开哪些，不真开 |
| `ccr -Pick` | 列出来手动勾选 |
| `ccr -Last` | 误关窗口后立刻找回（读**最近**一份存档，不限开机时间） |
| `ccr -History 15` | 还没攒下存档时，从历史对话里挑最近 15 个 |
| `ccr -Layout windows` | 用独立窗口而不是多标签 |

### ⚠️ 有一步需要你手动

大 / 老会话在进入前，Claude 会问 **"从摘要恢复 / 完整原样恢复 / 别再问"**。这步**无法自动**（Claude 官方没有提供跳过的开关）：

- 想要**完整原样**恢复上下文 → 按 **`2`** 回车；
- 小会话不会问这一步，直接进。

至于前面那个**"是否信任此文件夹"**的弹窗，工具会在启动前自动答掉（写 `~/.claude.json` 的 `hasTrustDialogAccepted`，带备份和校验），不用你管。

---

## 卸载

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\session-keeper\uninstall.ps1"
```

加 `-Purge` 连脚本目录和存档一起删。已经开着的窗口不受影响。

---

## 文件说明

| 文件 | 职责 |
|---|---|
| `restore.ps1` | 恢复引擎（`ccr` 调它） |
| `snapshot.ps1` | 存档器（计划任务每 2 分钟调它） |
| `install.ps1` | 幂等安装：别名 + 快捷方式 + 计划任务 |
| `uninstall.ps1` | 卸载（`-Purge` 连存档一起删） |
| `snapshots/`、`latest.json` | 运行时数据，**不进版本库** |

---

## 设计说明 / 已知坑

- **为什么按 `sessionId` 精确恢复**，而不是 `claude --continue`？因为同一个工作目录下可能有多个会话，`--continue` 只能恢复最近一个。
- **会话强绑定工作目录**：`claude --resume` 必须在原 `cwd` 启动，否则上下文里的相对路径会错乱，所以每个标签都用 `-d <原cwd>` 启动。
- **计划任务重复时长不能用 `[TimeSpan]::MaxValue`**（Windows 会拒绝 `P99999999D...`），本工具用 3650 天。
- **存档的"近期聚类"**：`ccr` 默认取"开机时间之前最后一份"存档，所以即使你关机好几天，整批窗口也能一起回来；几周前的崩溃残留不会混进来。
- "摘要 / 完整原样"弹窗目前确认**没有**任何 CLI 开关或配置键可跳过（Claude Code v2.1.x，原生 exe 构建）。如果未来官方加了，会更新这里。

---

## License

MIT
