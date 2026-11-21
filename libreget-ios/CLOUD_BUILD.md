# LibreGet Lite 云编译

构建仓库：`ggb15075/server-monitor-ios`，源码位于 `libreget-ios/LibreGetLite`。
独立工作流：`.github/workflows/build-libreget-lite-ipa.yml`，名称为
**Build LibreGet Lite TrollStore IPA**。原来的 **Build iOS TrollStore IPA**
构建的是服务器监控 App，不能作为 LibreGet 编译成功的依据。

工作流在 GitHub macOS runner 使用 Xcode 编译 arm64 真机包，最低支持 iOS 16.0，
不需要 Apple 开发者证书。修改本目录或该工作流并推送 `main` 时自动构建，
也可以在 Actions 页面选择 **Run workflow** 手动触发。

构建会验证包标识 `com.openselena.libreget.ioslite`、最低系统版本、arm64 架构和
IPA ZIP 完整性，然后上传 `LibreGetLite-iOS16-TrollStore` artifact，保留 14 天。
下载 artifact 并解压，使用 TrollStore 打开其中的
`LibreGetLite-iOS16-TrollStore.ipa`；同目录附有 SHA-256 校验文件。

当前通过 GitHub 网页上传 `LibreGetLite-source.zip`，内含本次更新的 Swift 源码、
工程、共享 scheme、图标和资源元数据。工作流兼容归档内的 Windows 路径分隔符，
校验解压路径及图标 SHA-256，再编译解压后的工程。修改本地 `ios/LibreGetLite`
后应重新打包该归档并上传，归档是云构建使用的源码版本。

当前是原生 SwiftUI Lite 版，支持 HTTPS 文件直链、后台下载、进度、取消、
重试和“文件”App／分享菜单导出。桌面版的网站解析、yt-dlp、FFmpeg、课程插件
及种子功能尚未移植。TrollStore 安装和真机下载仍需设备实测。

项目与图标来源：OpenSelena/libreget。GPL-3.0 许可见本目录 `LICENSE`。
