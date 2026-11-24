# opencode-issue-trigger

监听项目 `./issues/` 目录。发现新的 issue 文件后，向当前 opencode 会话注入一条处理提示词，让 agent 分析 issue、制定 plan 并逐步实施。

## 功能

- `fs.watch` 实时监听 `./issues/`，每 30 秒低频扫描已落地的文件。
- 每个 issue 文件在进程生命周期内只提醒一次；状态仅保存在内存，不落盘。重启后会对 `issues/` 现有文件重新提醒一次。
- `issues/` 下所有 `.md` 文件都会处理，不做流程产物、自反馈或终态过滤；启动时立即扫描并注入。
- 同时支持 opencode v1 与 v2 插件加载方式。
- 注入词：

  ```text
  请分析./issues/<文件名>的内容，制定plan，写入到./plan并逐步实施
  ```

- 无运行时依赖，只用 Node/Bun 内置模块。

## 从用户输入创建 issue

在会话中发送以 `issue` 开头的消息，插件会把它写成 `issues/` 下的新文件，随后按正常监听链路注入处理提示词。

```text
issue 记录：编译时缺少 zstd 头文件
```

行为约定：

- 以首个非空行判断是否为命令；`issue` 后可跟空格或冒号，正文保留全部行。
- 宿主把 prompt 作为 JSON 字符串传入时（例如 `opencode run`），外层成对的单/双引号会先剥离再解析。
- 正文为空时不创建文件，只记录一条 warn 日志。
- 文件名为 `<YYYYMMDD_HHMMSS>_<slug>.md`：slug 取正文首行前 24 个字符，非 `[A-Za-z0-9_-]` 折叠为 `-`；同秒同名追加 `_2`、`_3`。
- 先写 `issues/.<name>.md.tmp-<pid>`，再用硬链接原子发布；临时文件不以 `.md` 结尾，监听器不会拾到半成品，同名时追加 `_2` 而不覆盖。
- `issues/` 不存在时只记录 warn，不自动创建目录。
- 写入失败只记录 error，不影响用户消息本身。
- 同一 `messageID` 只处理一次，防止流式重试重复创建。

消息过滤：

- 宿主生成的合成消息（part 带 `synthetic`）不处理。
- 以注入词 `请分析./issues/`、`请严格遵守./plan/` 开头的文本不处理；注入词本身不以 `issue` 开头，因此不会自激。
- 不按 agent 名过滤：宿主可能让所有会话都运行在 `ulw-pm` 等非默认 agent 下，此时用户输入与插件注入的 agent 相同，按 agent 过滤会把用户消息一并丢弃。

实现路径：

- v1：宿主调用 `server()`，注册 `chat.message` hook，读取 `output.parts` 中的文本片段。
- v2：宿主调用 `setup(ctx)`。用户输入没有 `chat.message` 等价 hook，改用 `session.hook("context")` 读取每次模型调用前的消息列表；同一 `messageID` 只处理一次。监听注入链路使用 `ctx.session.list/prompt` 与 `ctx.event.subscribe`。
- 共享库安装在 `~/.config/opencode/issue-trigger-lib`，不放在 `plugin/` 或 `plugins/` 下：两代宿主都会把这两个目录的子目录当作独立插件加载。

## 单入口双导出

默认导出是一个普通对象，同时携带两代加载器各自识别的字段：

- `server(input)`：opencode 1.x 识别并调用，返回 v1 hook 表。
- `id` + `setup(ctx)`：opencode 2.x 识别并调用，`setup` 返回清理函数。

约束与已验证事实：

- 两套 hook 不互转：v1 用返回的 hook 表，v2 用 `ctx.session.hook` / `ctx.event.subscribe` 注册；业务核心共用，注册层各自适配。
- 只安装一份到 `~/.config/opencode/plugin/issue-trigger.ts`，不同时写入 `plugins/`。
- 已实测版本：opencode 1.19.5、opencode 1.18.14、opencode 2.2.5。对象入口的官方支持下限为 1.18.29，更老的 v1 宿主未验证。
- 不提供 `tui` 字段：v1 加载器拒绝 `tui` 与 `server` 共存。
- 代际判别只看注册面，不读版本号：`server` 要求 `directory|worktree` + `client.session`；`setup` 要求 `location.directory` + 顶层 `session.list/prompt`。缺注册面的上下文（如 v1 的配置回调）直接不动作，v1 会话由 `server` 承担。
- 同一目录按引用计数只保留一个 watcher；即使较新 v1 宿主同时运行 v1/v2 两套 pass，也不会重复注入。
- v2 加载失败可能静默：验证时检查项目 `log/issue-trigger.YYYYMMDDTHH.log` 出现 `issue-trigger loaded`，并实际放入一个 issue 文件确认注入，不能只看进程是否启动。
- 入口使用普通对象，不依赖 `@opencode/plugin`：v2 的 `define()` 是恒等函数。

## 注入会话的选择

服务端插件拿不到 TUI 当前显示的会话：官方插件 API 只有 `client` 与事件流，事件列表中没有会话焦点/切换事件，`tui.*` 也只是推送类端点。因此按「工作正在发生的会话」推断，优先级如下：

1. **同目录根会话中用户最近一次发言的会话**：只认 `message.updated` 且 `role=user`，assistant 的流式事件不改变目标，避免目标随 token 输出漂移。
2. **目标会话忙时等待**：`session.status` 为 `busy`/`retry` 时不注入，等 `session.idle` 再投递（idle 事件即时唤醒，另有每 5 秒兜底重试），不打断当前回合，也不把提醒转到别的会话来分散工作。
3. **无用户发言记录时（如刚启动）**：选同目录最近更新的空闲根会话，保证重启后 `issues/` 现有文件仍能被提醒。
4. **全部会话都忙**：保持排队，每 5 秒重试，直到出现空闲会话。

约束与边界：

- 只考虑同一 `directory` 的根会话；子会话（subagent）永不作为注入目标。
- 多个会话并行时，提醒只投给一个会话；其他会话的输出不会抢走目标。
- 注入是向目标会话提交一条 user 消息，由该会话的 agent 执行；空闲时立即开始，忙碌时按上述规则等待。
- 进程内每个 issue 只提醒一次；重启后对现有文件重新提醒一次（状态仅存内存）。
- 已知限制：无法得知用户眼前显示哪个会话，多客户端连接时也不存在唯一的「当前会话」；超过 30 分钟仍未投递只记一条 warn 并继续排队，不丢弃。

选择依据：opencode 官方插件文档只提供 `session.status`、`session.idle`、`message.updated` 等事件，没有会话焦点事件；同类注入型插件（如 `opencode-sessions`）同样采用「等目标会话 idle 后再作为 user 消息投递」的回合制做法。

## goal 暂停后的恢复

goal 处于 paused 时，会话处理完提醒就会停下，原 objective 不再推进，表现为「注入不起作用」。插件在提醒投递成功后自动恢复该 goal，使提醒与后续推进落在同一轮执行：

- 提醒照常投递；恢复失败不影响提醒，也不会重发。
- 恢复不需要先判定 goal 状态：`goal resume` 对「没有 goal / goal 仍在运行」只返回提示且不改变任何状态，对暂停中的 goal 则改为运行并续跑一轮。
- 仅 opencode 2.x 支持；1.x 没有 goal 功能，行为不变。

goal 会在宿主进程重启时被暂停（原因记为「The server restarted while the goal was active」），而安装本插件正是重写插件文件、触发宿主重启的动作，所以「装完插件后的第一条提醒」通常正处在 goal 暂停状态。

已知边界：恢复只重启 objective，不改变 goal 自身的判定。若 goal 的 reviewer 判定「未达成且无进展」，仍会按 goal 规则再次暂停。

## 运行前提：目录监听不被宿主卸载

opencode 2.x 默认在项目目录 60 分钟无会话活动后执行 `location services evicted`，把该目录的插件整体 unload。插件被卸载后 `fs.watch` 与 30 秒轮询一起消失，期间落盘的 issue 不会触发注入，直到下次打开该目录才由启动扫描补投。

```json
{
  "experimental": {
    "location_idle_timeout": false
  }
}
```

- `false` 表示永不因空闲卸载；也可填时长字符串（如 `"4 hours"`），但超过该时长仍会出现同样的延迟。
- 该键写在 `~/.config/opencode/opencode.json`（全局配置）。插件是全局安装的，逐项目改只能覆盖单个目录。
- `install.sh` 会幂等写入该键：缺失时补 `false` 并回读校验；已显式配置其他值时保留并记 `WARN`；配置文件无法解析或目录不可写时只记 `WARN`，不改文件。
- 每日审计 `scripts/audit-injection.sh` 校验所有已安装本插件的配置是否带该键，缺失或非 `false` 时记 `LOCATIONTTL` 并写 `issues/`。

自查：

```bash
grep -c 'location services evicted' ~/.local/share/opencode-workspaces/*/sessions/*/opencode/log/opencode.log
grep -n 'location_idle_timeout' ~/.config/opencode/opencode.json
```

## 运行日志

v2 宿主没有 `app.log` 接口，standalone 服务的 stderr 指向 `/dev/null`，`console.error` 会被丢弃。插件把日志写入项目内的：

```text
<project>/log/issue-trigger.YYYYMMDDTHH.log
```

关键事件：`issue-trigger loaded`（加载）、`startup scan dispatched existing issues`（启动扫描计数）、`injected issue prompt`（投递完成，含 sessionID 与路径）、`issue reminder still waiting for an idle session`（排队等待）。日志目录不可写时回退 stderr，写日志失败不影响注入。每日审计脚本 `scripts/audit-injection.sh` 同时读取宿主 `opencode.log`（v1）与项目内插件日志（v2）。

## 本地安装流程

```bash
git clone https://github.com/xxmawhu/opencode-issue-trigger.git
cd opencode-issue-trigger
bash install.sh
```

`install.sh` 会：

1. 把插件入口安装到 `~/.config/opencode/plugin/issue-trigger.ts`，同一文件内的 `server()` 与 `setup()` 分别服务 v1 与 v2。
2. 把共享库安装到 `~/.config/opencode/issue-trigger-lib`。
3. 删除旧布局（`plugin/issue-trigger-lib`、`plugins/issue-trigger`），避免重复加载与加载失败。
4. 用平台 `pre-commit`（`/opt/miniconda3/bin/pre-commit`）注册 `pre-commit` 与 `post-merge` git hooks。
5. 幂等写入 `experimental.location_idle_timeout: false` 到 `~/.config/opencode/opencode.json`，避免宿主空闲卸载目录监听。

安装选项：

- `bash install.sh`：复制安装，并做静态自检（已装文件与仓库逐文件比对；宿主为 1.x 时再核对插件列表包含 issue-trigger，2.x 无 `debug info` 子命令则跳过该断言）。
- `bash install.sh --link`：开发期符号链接安装，入口与共享库指向当前仓库，改代码无需重装。
- `bash install.sh --verify`：在静态自检之外追加加载断言——启动一次宿主进程，要求日志出现 `issue-trigger loaded` 且无 `failed to load plugin`。

安装完成后重启 opencode 即可生效。此后更新只需在属主侧 `git pull`：`post-merge` hook 自动执行 `install.sh`，不需要手工重装。

安装目录固定为执行 `install.sh` 时的 `$HOME/.config/opencode`，宿主只读取其启动进程 HOME 下的配置。同一台机器存在两份内容不同的安装时，`install.sh` 记 `WARN` 并输出两个路径。

## 回归验证

`scripts/verify-regression.sh` 在隔离 HOME 中复现完整链路：安装（复制 + 符号链接）→ 启动 → 断言无 LoadError → 放入 issue → 断言注入一次 → 重启再跑 → 断言同一 issue 每进程仅注入一次。v2 轮次的激活断言取自沙箱项目内的 `log/issue-trigger.*.log`，不依赖宿主 `opencode.log`（v2 无 `app.log`，standalone stderr 指向 `/dev/null`）。

```bash
bash scripts/verify-regression.sh                      # v1，默认 3 轮
OPENCODE_V2=/path/to/opencode2 bash scripts/verify-regression.sh   # 追加 v2 轮次
OPENCODE_V1=/path/to/opencode bash scripts/verify-regression.sh     # 覆盖 v1 路径
```

脚本把完整过程写入 `log/verify-regression.YYYYMMDDTHH.log`（按小时一个文件），屏幕只输出每步 ✅/❌。

## 自动更新

仓库已配置 `.pre-commit-config.yaml`。`git pull` 触发 `post-merge` hook，自动执行 `install.sh`，把最新插件文件重新安装到 opencode 配置目录。