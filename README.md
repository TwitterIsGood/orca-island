# Orca Island

把 Orca 的智能体状态融入 MacBook 摄像头刘海，两侧显示状态，点击后向下展开。对话按工作区分组，高度随内容自动伸缩，点击对话即可跳回对应的 Orca 终端；无刘海显示器使用顶部居中模式。

![Orca Island](https://github.com/user-attachments/assets/bcf71c77-1a1d-4699-b69f-aefb964c9b83)

[查看原图](https://github.com/user-attachments/assets/bcf71c77-1a1d-4699-b69f-aefb964c9b83)

## 怎么用

需要 macOS 13+、Orca 1.4.260+ 和 Xcode Command Line Tools（提供 Swift 编译器）。

1. 下载、构建并启动：

   ```bash
   git clone https://github.com/TwitterIsGood/orca-island.git
   cd orca-island
   ./scripts/build-companion.sh
   open dist/OrcaIsland.app
   ```

2. 点击刘海左侧 **Orca** 或右侧**数字**展开，点击外部收起。列表可滚动，点击对话跳转终端。任务从进行中变为完成时会自动展开并标出对应对话；启动时已有的完成任务不会弹出。
3. 启用实时更新：Orca → Settings → Plugins → 打开插件系统 → 从 Git URL 安装 `https://github.com/TwitterIsGood/orca-island` → Review & Enable **Orca Island**。

插件收到首次事件或运行命令时，会在后台检查并启动 Orca Island。首次安装伴侣时从 GitHub Release 下载并校验 `SHA256SUMS`；也可以从命令面板运行 **Orca Island: Install & Start** 手动重试。插件只在 macOS 上安装伴侣，下载和启动不会阻塞 Orca。

这是 Orca 插件 + macOS 原生伴侣。仅显示状态和跳转会话，暂不支持在灵动岛内审批工具。

## 发布

```bash
./scripts/package-release.sh
```

生成 Universal macOS `.zip`、`.dmg` 和 `SHA256SUMS`。推送与 `orca-plugin.json` 版本一致的 `v*` tag 后，GitHub Actions 会自动构建并发布。

显示本机和已配对远程环境的智能体状态。远程断连会标注“暂未连接”，保留上次成功读取的记录。直接 SSH、部分原生聊天和休眠布局不能完整覆盖。

## 公开接口与兼容性

实时更新使用官方插件事件 `agent.status.changed`；工作区归属通过公开 Host API `workspace.list` 确认。启动、重连和定期校准使用官方 CLI 的 `environment list`、`worktree ps`、`terminal list`、`agent list`。原生伴侣不再加载 Orca 内部 JavaScript、不读取 Orca 的 SQLite 或配置文件，也不依赖 Orca 自带的 Electron/Node。

官方 [Host API 1](https://github.com/stablyai/orca/blob/main/docs/reference/plugin-host-api.md#stability-and-deprecation) 承诺只增不改；事件 payload 仍属实验接口，因此保留字段校验与公开 CLI 校准。接口异常、列表截断或远程离线不会被当作“成功的空列表”。

与旧实现的区别：

1. **已读归 Island 自己管理。** 点击已完成卡片或“清除已完成”会记住该次完成；不读取或修改 Orca 的已读状态，也不跟随 Orca 的“显示空闲”偏好。
2. **只跳转能重新核验的活终端。** 使用公开 `terminal switch`，严格匹配主机、工作区和完整 pane identity；不按标题猜测，也不重新启动智能体。
3. **原生 Chat、休眠或关闭的终端可能只能查看状态。** 无公开精确跳转接口的卡片会注明原因，不伪造可点击路由；历史会话列表不等于完整休眠布局。

迁移设计及验证说明见 [公开接口迁移](docs/public-api-migration.md)。
