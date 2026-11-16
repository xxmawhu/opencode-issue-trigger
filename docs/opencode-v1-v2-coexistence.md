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
- 对象必须直接作为默认导出：不包 `define()`（当前是恒等函数，无收益）、不做对象展开（会丢掉未来版本可能附加的不可枚举品牌标记）。

## 入口判别：认注册面，不认版本号

实测：`opencode 1.18.14` / `1.19.5` 的 `server(input)` 携带 `directory` 与 `client.session`；TUI 会把配置形状对象传给 `setup`（`options/agent/catalog/...`，无 client、无 location、无 session）。

判别规则（两代各查自己的注册面）：

- `server`：`directory|worktree` 是字符串，且 `client.session.list` 与 `client.session.prompt|promptAsync` 是函数 → 执行 v1 接线；否则返回空钩子表，不做事。
- `setup`：`location.directory` 是字符串，且顶层 `session.list`、`session.prompt` 是函数 → 执行 v2 接线；否则返回 `undefined`，不做事。
- 全程不读版本号：版本是宿主可给可不给的弱信号，注册面有无是强事实。v1 配置回调、未知形态上下文都因缺 v2 注册面自然落入不动作分支。

v2 路径的所有 ctx 接口（`event.subscribe`、`session.hook`、`session.list`）仍要先判 `typeof === "function"`。

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

## 配置层

- 不要在同一份 `opencode.json(c)` 里同时写 `plugin` 与 `plugins` 键：v1 不认 `plugins`，双写会导致 v1 启动失败。
- 本项目不依赖配置键，靠目录发现（`plugin/` + 库目录），无需按版本写键。

## 事件订阅写法（v2）

- `ctx.event.subscribe({ signal })` 返回 `AsyncIterable`，用 `for await` 消费；循环体里**不要 `return`** 跳过事件（会永久结束订阅），用 `continue` 或把单事件处理封成函数。
- 订阅必须异步启动（`void (async () => { ... })()`），`setup` 要尽快返回清理函数；在 `setup` 里 `await for await` 会让宿主认为初始化卡死。
- 清理函数里 `controller.abort()`；循环异常仅在未 abort 时告警。
- 入口文件不要顶层静态导入宿主 SDK，保持零运行时依赖。

## 版本口径

- 本项目实测：opencode 1.18.14 接受对象默认导出并调用 `server()`；2.2.5 读取 `id` + `setup`。
- 外部建议口径为「对象入口需 v1 ≥ 1.18.29」。两者不冲突：1.18.14 实测可用，更老版本未验证；面向未知 v1 版本分发时按 ≥1.18.29 声明更稳妥。

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