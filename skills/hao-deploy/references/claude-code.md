# claude-code —— Claude Code CLI 安装与网关配置

装 Claude Code CLI，并可选地为目标用户写 `~/.claude/settings.json`
（自定义网关 / 模型 / 超时）。

## 1. 安装

需要 Node.js ≥ 18。先按 `references/node.md` 确保 `/usr/bin/node` 就绪，
然后：

```bash
if command -v claude >/dev/null 2>&1; then
    claude --version        # 已装：默认保持现有版本
else
    npm install -g @anthropic-ai/claude-code
fi
```

用户明确要求升级时才 `npm install -g @anthropic-ai/claude-code`。

只配置不安装（机器上已有 CLI）时跳过这一步；为当前用户写配置不需要 root。

## 2. 写 settings.json

只在用户提供了网关地址 / token / 模型之类配置时才写。没有就跳过——
装完 CLI 用官方端点直接可用。

**必须深合并，不能整体覆盖。** `settings.json` 里可能有用户的
`permissions`、`hooks`、MCP 配置，覆盖会静默丢掉它们。

```bash
TARGET_HOME="$(getent passwd "$CC_USER" | cut -d: -f6)"
SETTINGS="$TARGET_HOME/.claude/settings.json"
mkdir -p "$TARGET_HOME/.claude"
chmod 700 "$TARGET_HOME/.claude"

# 先备份
[ -f "$SETTINGS" ] && cp -a "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d_%H%M%S)"
```

### token 绝不能进上下文

token 是密钥，走 `hao-secret.sh`，不要读出来拼进 JSON：

```bash
# 用户给的 token 从文件读入，值不经过命令行也不经过对话
"$SKILL/scripts/hao-secret.sh" write /etc/hao/claude-code.env \
    ANTHROPIC_AUTH_TOKEN=@file:/path/to/token.txt
```

然后用 node 深合并。敏感值通过**环境变量**传给合并器（不进 argv，argv 对
同机任意用户可见）：

```bash
CC_TOKEN="$(sed -n 's/^ANTHROPIC_AUTH_TOKEN=//p' /etc/hao/claude-code.env)" \
CC_BASE_URL="$BASE_URL" CC_MODEL="$MODEL" SETTINGS_FILE="$SETTINGS" \
node -e '
  const fs = require("fs");
  const f = process.env.SETTINGS_FILE;
  let s = {};
  if (fs.existsSync(f)) {
    try { s = JSON.parse(fs.readFileSync(f, "utf8") || "{}"); }
    catch (e) {
      process.stderr.write("已有 settings.json 不是合法 JSON，拒绝覆盖（备份已生成）\n");
      process.exit(1);
    }
  }
  if (typeof s !== "object" || s === null || Array.isArray(s)) s = {};
  if (typeof s.env !== "object" || s.env === null || Array.isArray(s.env)) s.env = {};
  const set = (k, v) => { if (v !== undefined && v !== "") s.env[k] = v; };
  set("ANTHROPIC_BASE_URL", process.env.CC_BASE_URL);
  set("ANTHROPIC_AUTH_TOKEN", process.env.CC_TOKEN);
  if (process.env.CC_MODEL) {
    const m = process.env.CC_MODEL;
    for (const k of ["ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL",
                     "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL"]) set(k, m);
  }
  set("API_TIMEOUT_MS", process.env.CC_API_TIMEOUT_MS || "3000000");
  process.stdout.write(JSON.stringify(s, null, 2) + "\n");
' > /tmp/cc-settings.json

install -m 600 /tmp/cc-settings.json "$SETTINGS"
rm -f /tmp/cc-settings.json
chown -R "$CC_USER:$(id -gn "$CC_USER")" "$TARGET_HOME/.claude"
```

已有 `settings.json` 不是合法 JSON → **拒绝写入**，把备份路径告诉用户。
不要试图修好用户的 JSON。

### 一个反直觉的坑

`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`、`DISABLE_TELEMETRY`、
`DISABLE_ERROR_REPORTING` 这几个开关**只看有没有被设置**。
设成 `"0"` 等于**打开**它，不是关闭。要关闭就把这个键整个删掉。
用户说"我要关掉遥测"时，写 `"1"`；说"我不想禁用"时，删键，不要写 `"0"`。

自建网关部署建议设 `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`
（关掉自更新/遥测/错误上报这些发往官方端点的流量）。

## 3. 验证

```bash
claude --version
node -e "JSON.parse(require('fs').readFileSync(process.env.F,'utf8'))" # F=settings 路径
```

JSON 校验不过就是失败，停下来。

## 4. 记录状态

```bash
"$SKILL/scripts/hao-state.sh" record claude-code installed \
    secret:"$TARGET_HOME/.claude/settings.json" \
    secret:/etc/hao/claude-code.env
"$SKILL/scripts/hao-state.sh" handoff
```

`settings.json` 记 `secret`：里面有 token，只登记路径不记哈希。

## 汇报给用户

配了网关就说"配置已写入（token 未打印），改完配置要重启 Claude Code 生效"。
不要复述 token，不要复述 base URL 里可能夹带的凭据。

用户想自己了解各项配置的含义时，指给他 `docs/claude-code-guide.md`
（在 skill 所在仓库根的 `docs/` 下）。
