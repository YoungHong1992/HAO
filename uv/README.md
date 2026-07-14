# uv — Python 环境管理器

系统级安装 [uv](https://docs.astral.sh/uv/)（Astral 出品的 Python 包与环境管理器），并把「Python 项目一律使用 uv」的约定写入本机 AI 编程助手的全局指令文件,让 AI agent 在跑用户项目或第三方项目时统一走 uv 虚拟环境,而不是全局 pip / `--break-system-packages` / `apt install python3-*` 乱装。

## 背景

Debian 12+ 与 Ubuntu 24.04+ 的系统 Python 是 externally-managed（PEP 668）,全局 `pip install` 默认被系统拒绝。AI agent 碰壁后的典型退化行为是改用 `apt` 装应用依赖、加 `--break-system-packages`,或者手动下载解释器——污染系统且不可复现。本模块从两端解决:

1. **机器上有 uv** —— 系统级安装到 `/usr/local/bin`,所有用户可用。
2. **agent 知道要用 uv** —— 约定写入 agent 会自动读取的全局指令文件。

## 用法

```bash
# 通过 hao 编排（推荐）
./hao plan --services uv
sudo ./hao apply --services uv --yes

# 单独运行
sudo ./install.sh                # 交互式
sudo ./install.sh --no-prompt    # 非交互式
```

## 配置变量

| 变量 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `HAO_UV_ACTION` | 否 | `ensure` | `ensure`:uv 已安装则保持现有版本,只更新约定;`upgrade`:显式升级 uv |
| `HAO_UV_PYTHON` | 否 | 空（不预装） | 预装的 Python 版本,逗号分隔,如 `3.12` 或 `3.11,3.12`。预装后 agent 建 venv 时无需现场下载解释器 |
| `HAO_UV_USER` | 否 | `SUDO_USER` 或当前用户 | agent 约定写入的目标用户;预装的 Python 解释器也归属该用户 |
| `HAO_UV_AGENT_FILES` | 否 | 自动检测 | 显式指定约定写入的文件（逗号分隔绝对路径）,设置后跳过自动检测 |
| `HAO_UV_SKIP_AGENT_CONVENTION` | 否 | `0` | 设为 `1` 时只装 uv,不写任何 agent 约定 |

## agent 约定的写入位置

脚本按下表自动检测目标用户已安装（命令存在或配置目录已存在）的 AI 助手,只写命中的:

| AI 助手 | 全局指令文件 |
|---|---|
| Claude Code | `~/.claude/CLAUDE.md` |
| Pi | `~/.pi/agent/AGENTS.md` |
| Codex CLI | `~/.codex/AGENTS.md` |
| OpenCode | `~/.config/opencode/AGENTS.md` |

一个助手都没检测到时脚本会告警并跳过（uv 本身照常安装）;之后装好助手再重跑一次,或用 `HAO_UV_AGENT_FILES` 显式指定。

写入的内容用标记块包裹:

```
<!-- HAO-UV BEGIN (managed by HAO, do not edit inside) -->
...约定内容...
<!-- HAO-UV END -->
```

- **幂等**:重复执行时原地替换标记块,文件其余内容原样保留。
- 文件不存在时创建;已存在时追加,不覆盖用户已有指令。

约定内容要点:`uv sync`/`uv add`/`uv run` 管理 pyproject 项目、`uv venv` + `uv pip install -r` 兼容 requirements 项目、`uv python install` 管理解释器、`uvx` 跑一次性工具;禁止全局 pip、`--break-system-packages`、`apt install python3-*` 装应用依赖。

## 幂等性

- uv 已安装:默认（`ensure`）保持现有版本不动,仅刷新 agent 约定;`HAO_UV_ACTION=upgrade` 时执行 `uv self update`,不支持 self update 则通过官方脚本原地重装。
- Python 解释器:`uv python install` 本身幂等,已装版本直接跳过。
- agent 约定:标记块原地更新。

## 安全说明

- 本模块不涉及任何 secret。
- 不修改系统 Python 与 PEP 668 的 EXTERNALLY-MANAGED 标记——它是防线,保留。
- 不写 shell 级 pip 拦截 hook,只做「安装 + 约定」,行为可审计。

## 卸载

```bash
sudo rm /usr/local/bin/uv /usr/local/bin/uvx
# agent 指令文件中删除 HAO-UV BEGIN/END 标记块即可
# 用户级解释器与缓存: rm -rf ~/.local/share/uv
```
