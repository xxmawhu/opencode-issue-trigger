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