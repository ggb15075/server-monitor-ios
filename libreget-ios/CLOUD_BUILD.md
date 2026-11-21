# LibreGet iOS 解析版云构建

这是 LibreGet 的独立 iOS 应用，位于已授权仓库的 libreget-ios 目录。
对应工作流为 Build LibreGet Lite TrollStore IPA。

0.2.2（4）针对真机后台临时文件权限错误，加入自动切换到应用自有流式下载，并预签精确的应用与容器身份。保留0.2.1点击记录下载/小窗播放。0.2.0 新增本机网页解析、格式选择、请求头传递、分轨音视频合并与 HLS 离线播放。
源码以 LibreGetLite-source.zip 归档保存；内含工程、解析桥接、依赖准备脚本、
原生与 Python 测试以及发布说明。Python 与 yt-dlp 依赖在构建时按固定版本和 SHA-256 获取。

构建先运行原生解析、真实HTTP流式下载和iOS模拟器生产下载状态机故障恢复测试，再准备 Python 运行库，运行 yt-dlp 集成测试，然后编译
iOS 16+ arm64 App，并检查应用标识、最低版本、解析引擎资源和 Python 链接。
输出 LibreGetLite-iOS16-TrollStore artifact，解压后使用 IPA 在 TrollStore 安装。

构建末尾以ad-hoc签名写入精确application-identifier与正常container-required标识，验证签名并核对entitlements；不增加全盘访问权限。后台权限错误时的应用内兼容下载需要保持App在前台，不能保证进程被挂起后继续。

原生解析覆盖抖音、B站、TikTok、X 的公开单作品；更多网页交给内嵌 yt-dlp。
登录、地区与网站访问限制仍适用。分轨使用系统框架合并为 MP4／MOV；HLS 为系统离线包，
可在应用内播放，不能视为可通用分享的 MP4。暂不包含 FFmpeg、DRM、直播或频道批量下载。

云编译、测试通过与实际 iPhone 行为分别验证。新包构建成功前，0.1.0 仍是旧直链版。
项目与图标来源：OpenSelena/libreget。GPL-3.0 许可见本目录 LICENSE。
