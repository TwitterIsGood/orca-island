# Orca Island

把 Orca 的智能体状态融入 MacBook 摄像头刘海，两侧显示状态，点击后向下展开。对话按工作区分组，高度随内容自动伸缩，点击对话即可跳回对应的 Orca 终端；无刘海显示器使用顶部居中模式。

![Orca Island](https://github.com/user-attachments/assets/bcf71c77-1a1d-4699-b69f-aefb964c9b83)

[查看原图](https://github.com/user-attachments/assets/bcf71c77-1a1d-4699-b69f-aefb964c9b83)

## 怎么用

需要 macOS 13+、Orca 1.4.245+ 和 Xcode Command Line Tools（提供 Swift 编译器）。

1. 下载、构建并启动：

   ```bash
   git clone https://github.com/TwitterIsGood/orca-island.git
   cd orca-island
   ./scripts/build-companion.sh
   open dist/OrcaIsland.app
   ```

2. 点击刘海两侧展开工作区和对话列表，列表较长时可滚动。应用每 2 秒读取本机 Orca 的终端状态。
3. 启用实时更新：Orca → Settings → Plugins → 打开插件系统 → 从 Git URL 安装 `https://github.com/TwitterIsGood/orca-island` → Review & Enable **Orca Island**。

这是 Orca 插件 + macOS 原生伴侣，原生伴侣需要保持运行。仅显示状态和跳转会话，暂不支持在灵动岛内审批工具。
