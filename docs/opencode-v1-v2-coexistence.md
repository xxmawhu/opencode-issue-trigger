# OpenCode v1 / v2 插件共存要点

适用：本机需同时用 opencode 1.18.14 与 opencode 2.2.5 加载同一份插件安装。
以下结论均由隔离 HOME 实测得出，不是推断。

## 宿主加载范围

| 宿主 | `plugin/` 散文件 | `plugin/` 一级子目录 | `plugins/` 散文件 | `plugins/` 一级子目录 |
|------|------------------|----------------------|-------------------|------------------------|
| 1.18.14 | 加载 | 忽略 | 加载 | 忽略 |
| 2.2.5 | 加载 | 加载 | 加载 | 加载 |

含义：安装目录里**任何**散文件与子目录都会被至少一代宿主当作插件，没有“某一代看不到”的保险位。

## 默认导出契约

- 两代都只读 `default`。
- v1：必须是对象且带 `server()`（`must default export an object with server()`）；带 `tui` 字段会被拒。
- v2：必须是对象且带 `id` + (`setup` | `effect`)；函数默认导出报 `Expected object at ["default"]`，无默认导出报 `Missing key at ["default"]`。
- 通用写法：单对象 `{ id, server, setup }`，两代各自取用，互不干扰。

## `setup` 可能收到 v1 形态的 input

实测：`opencode 1.18.14` 只调用 `server(input)`；但存在 1.x 宿主会调用 `setup(ctx)`，传入的是经典 input：

- 1.18.14 `server(input)` 的 input 键：`client, project, worktree, directory, experimental_workspace, serverUrl, $`
- 这类 input 有 `client.session`，没有 v2 的 `ctx.session.prompt`、`ctx.event.subscribe`

后果（均有实测复现）：

- 未做形态识别：`setup` 判定「session client 不可用」并自禁用（`[issue-trigger] error ... disabled`）
- 直接访问 `ctx.event.subscribe`：抛 `Cannot read properties of undefined (reading 'subscribe')`（bun/JSC 下文案为 `undefined is not an object (evaluating 'ctx.event.subscribe')`）

写法：`setup` 开头判断 `typeof ctx.client?.session === "object"`，命中则转交 v1 路径并返回其 `dispose`；v2 路径的所有 ctx 接口（`event.subscribe`、`session.hook`、`session.list`）都要先判 `typeof === "function"`。

## 共享库位置

- 共享库必须放在 `plugin/`、`plugins/` 之外（如 `~/.config/opencode/<name>-lib/`）。
- 放在 `plugin/` 子目录的代价：v2 会把它当独立插件加载。
  - 无默认导出 → v2 加载失败并告警（plan-trigger 的失败根因）。
  - 有默认导出 → 多一次加载，靠 v2 的 **id 去重** 才不重复激活；这是隐式耦合，宿主去重策略变化即失效。
- 库放在 `plugins/` 子目录时 v1 看不到，但 v2 仍会当插件加载。

## 安装布局

- 入口只装一份：`~/.config/opencode/plugin/<name>.ts`。
- 库装到 `~/.config/opencode/<name>-lib/`，入口用 `../<name>-lib/index.mjs` 导入。
- 不要同时装 `plugin/<name>.ts` 与 `plugins/<name>/index.ts`：两代都会各加载一次。若必须双入口，两者必须导入同一对象且 `id` 一致。

## 激活次数

- v2 按 `id` 去重：同一 `id` 多次加载只调用一次 `setup`（实测同 id 3 次加载 → 1 次 `setup`；不同 id 3 次加载 → 3 次 `setup`）。
- v1 不去重：`plugin/` 与 `plugins/` 的散文件各调一次 `server()`。
- 因此业务状态需要跨加载共享时（如目录级 watcher），按目录做引用计数，避免多入口重复注入。

## 验证方法（两代各 ≥3 次）

```bash
# v2：应为 0 行
HOME=<sandbox> <opencode2> --standalone --print-logs --log-level debug debug agents 2>&1 | grep -c 'failed to load plugin'
# v2：确认只加载期望的入口（排查子目录误加载）
HOME=<sandbox> <opencode2> --standalone --print-logs --log-level debug debug agents 2>&1 | grep 'loading plugin'
# v1：应列出入口
HOME=<sandbox> <opencode> debug info | grep <name>
# v1：真实加载检查（要在目标项目目录内执行，插件目录取 cwd）
cd <project> && HOME=<sandbox> <opencode> run "hi" --model nonexistent/nonexistent --print-logs --log-level DEBUG 2>&1 | grep -E 'failed to load plugin|<name> loaded'
```

只查 `failed to load plugin` 为 0 不够：多入口/库误加载在没有默认导出时才会报错，有默认导出时静默多加载一次。