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

- 只解析消息首个非空行；`issue` 后可跟空格或冒号，其余内容为正文。
- 正文为空时不创建文件，只记录一条 warn 日志。
- 文件名为 `<YYYYMMDD_HHMMSS>_<slug>.md`：slug 取正文首行前 24 个字符，非 `[A-Za-z0-9_-]` 折叠为 `-`；同秒同名追加 `_2`、`_3`。
- 先写 `issues/.<name>.md.tmp-<pid>` 再 `rename` 原子发布；临时文件不以 `.md` 结尾，监听器不会拾到半成品。
- `issues/` 不存在时只记录 warn，不自动创建目录。
- 写入失败只记录 error，不影响用户消息本身。
- 同一 `messageID` 只处理一次，防止流式重试重复创建。

消息过滤：

- 宿主生成的合成消息（part 带 `synthetic`）不处理。
- `ulw-pm` agent 的宿主注入不处理。
- 以注入词 `请分析./issues/` 开头的文本不处理；注入词本身不以 `issue` 开头，因此不会自激。

实现路径：

- v1：注册 `chat.message` hook，读取 `output.parts` 中的文本片段。
- v2：注册 `ctx.session.hook("prompt", ...)`（官方迁移表对应 `chat.message`）。旧宿主没有该 hook 时，退化为订阅 `message.updated` / `message.part.updated`，等 `session.idle` 后用完整文本处理。

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
- 已知限制：无法得知用户眼前显示哪个会话，多客户端连接时也不存在唯一的「当前会话」；超过 30 分钟仍未投递则会丢弃，下一轮扫描会重新排队。

选择依据：opencode 官方插件文档只提供 `session.status`、`session.idle`、`message.updated` 等事件，没有会话焦点事件；同类注入型插件（如 `opencode-sessions`）同样采用「等目标会话 idle 后再作为 user 消息投递」的回合制做法。

## 本地安装流程

```bash
git clone https://github.com/xxmawhu/opencode-issue-trigger.git
cd opencode-issue-trigger
bash install.sh
```

`install.sh` 会：

1. 把 v1 入口安装到 `~/.config/opencode/plugin/issue-trigger.ts`。
2. 把 v2 入口安装到 `~/.config/opencode/plugins/issue-trigger/index.ts`。
3. 把共享库安装到上述两个入口旁边。
4. 用 `pre-commit` 注册 `pre-commit` 与 `post-merge` git hooks。

安装完成后重启 opencode 即可生效。

## 自动更新

仓库已配置 `.pre-commit-config.yaml`。`git pull` 触发 `post-merge` hook，自动执行 `install.sh`，把最新插件文件重新安装到 opencode 配置目录。