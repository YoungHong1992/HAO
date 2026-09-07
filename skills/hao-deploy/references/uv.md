# uv —— Python 环境管理器 + agent 约定

装 uv，并把「本机 Python 项目一律用 uv」写进本机 AI 助手的指令文件。

## 为什么要写约定

Debian 12+ / Ubuntu 24.04+ 的系统 Python 是 externally-managed（PEP 668），
全局 `pip install` 默认被拒。AI agent 碰壁后经常退化成
`apt install python3-*` 或 `pip install --break-system-packages`，把系统弄脏。
这个约定块就是拦住那个退化路径的。

## 1. 安装 uv

```bash
if command -v uv >/dev/null 2>&1; then
    uv --version        # 已装：默认保持现有版本，不要擅自升级
else
    curl -fsSL --connect-timeout 30 https://astral.sh/uv/install.sh \
        | env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh
fi
command -v uv >/dev/null || { echo "uv 装完仍不在 PATH，中止"; exit 1; }
```

`UV_INSTALL_DIR=/usr/local/bin` 是为了系统级可见（同 `node` 模块的理由）。
`UV_NO_MODIFY_PATH=1` 避免脚本去改用户的 shell 配置文件。

用户明确要求升级时：先试 `uv self update`，不可用（发行版打包的 uv 不支持）
再用官方脚本重装覆盖。

## 2. 预装 Python 解释器（可选）

只在用户指定版本时做。**装到目标用户目录**，这样 agent 以该用户运行时能直接用：

```bash
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" uv python install 3.12
```

版本号格式必须是 `3.x` 或 `3.x.y`，其他一律拒绝。
目标用户是 root 时直接执行，不用 runuser。

## 3. 写 agent 约定

```bash
"$SKILL/scripts/hao-state.sh" convention HAO-UV --user "$TARGET_USER" <<'EOF'
## Python 环境约定（uv）

本机 Python 项目一律使用 [uv](https://docs.astral.sh/uv/) 管理环境和依赖：

- 新项目 / 有 `pyproject.toml` 的项目：`uv sync` 安装依赖，`uv add <pkg>` 添加依赖，`uv run <cmd>` 执行命令。
- 只有 `requirements.txt` 的第三方项目：`uv venv` 创建 `.venv`，然后 `uv pip install -r requirements.txt`。
- 需要独立 Python 版本时：`uv python install 3.12`，`uv venv --python 3.12`。
- 运行一次性工具：`uvx <tool>`（等价 pipx）。

禁止事项：

- 禁止系统级 `pip install`，禁止 `pip install --break-system-packages`（本系统 Python 是 externally-managed，PEP 668）。
- 禁止用 `apt install python3-*` 安装项目应用依赖（系统工具依赖除外）。
- 禁止手动下载/编译 Python，统一用 `uv python install`。
EOF
```

约定块用 `HAO-UV` 标记，重复执行原地替换，块外的用户内容一律保留。
用户不想写就加 `--skip-agent-files`；要指定文件就用 `--agent-file PATH`。

## 4. 验证并记录

```bash
uv --version
"$SKILL/scripts/hao-state.sh" record uv installed \
    observed:/usr/local/bin/uv \
    observed:/usr/local/bin/uvx
"$SKILL/scripts/hao-state.sh" intent uv \
    target_user="$TARGET_USER" python_version="${PY_VERSION:-未预装}"
"$SKILL/scripts/hao-state.sh" handoff
```

两个二进制都要记：官方脚本同时装 `uv` 和 `uvx`，只记一个的话另一个成了无主文件。
两者都记 `observed`——升级会换掉它们，记 `managed` 会让 `drift` 天天误报。
**旧机器上可能被记成了 `managed`**（早期版本如此），碰到就重跑上面这条 `record`
纠正过来，否则 uv 一升级 `drift` 就永久报漂移。

约定块写在用户的指令文件里，那些文件属于用户，也不记 managed。

## 汇报给用户

```
uv --version
uv venv                              # 当前目录创建 .venv
uv add <package>                     # pyproject 项目加依赖
uv pip install -r requirements.txt   # 兼容 requirements 项目
uvx <tool>                           # 跑一次性工具
```
