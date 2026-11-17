# 开源复用说明

本项目使用已有开源监控系统提供采集、存储、节点管理和网络探测。iOS 客户端根据参考图片自行实现 SwiftUI 卡片，最低系统目标为 iOS 16。它不是哪吒、Komari 或 ServerBox 的官方客户端。

调研日期：2026-11-17。

| 项目 | 协议 / 系统要求 | 本项目的选择 |
| --- | --- | --- |
| [Komari](https://github.com/komari-monitor/komari) | MIT；服务器软件 | 复用官方 Docker 镜像，NAS 部署，客户端通过公开 API 连接 |
| [Komari Agent](https://github.com/komari-monitor/komari-agent) | MIT；服务器探针 | 在 VPS 采集资源和执行指定 Ping 任务 |
| [哪吒监控](https://github.com/nezhahq/nezha) | 主后端仓库 WTFPL；独立监控系统 | 已调研；用户既有哪吒面板可以作为后续适配来源 |
| [ServerBox](https://github.com/lollipopkit/flutter_server_box) | AGPL v3；主 App 最低 iOS 15，当前小组件最低 iOS 17 | 官方有未签名 IPA，但完整客户端是 Flutter / Rust 等组成的综合工具，未复制它的代码 |
| [Nezha Mobile](https://github.com/hiDandelion/Nezha-Mobile) | GPL v3；当前最低 iOS 17 | 不适合直接套用于 iOS 16.6.1，未复制其代码 |
| [PurCarte](https://github.com/Montia37/komari-theme-purcarte) | MIT；Komari 网页主题 | 参考调研对象，未打包其主题或复制 UI 源码 |

参考图呈现的是常见服务器监控卡片：地区、标签、资源占用、实时速率、累计流量、到期信息和三网历史。仅凭这张裁剪图片不能可靠认定它来自哪个具体开源主题，因此不宣称复刻某一官方主题。

## 实际复用边界

- 后端和探针使用 Komari 官方项目，保留其自身许可证及发布包内容。
- 客户端通过 HTTP JSON-RPC 读取数据，不内嵌 Komari 服务端、ServerBox 或 Nezha Mobile 的实现。
- iOS UI 与网络适配代码在本仓库维护；协议字段依据官方文档和接口定义实现。
- `deploy` 中固定版本的 Docker Compose 和部署说明是本项目交付内容，不会把服务器地址或凭据编译进 IPA。

Komari 的 MIT 许可证来源：[服务端 LICENSE](https://github.com/komari-monitor/komari/blob/1.6.1/LICENSE)、[Agent LICENSE](https://github.com/komari-monitor/komari-agent/blob/1.5.11/LICENSE)。若以后复制第三方代码、图标或主题，应同时保留相应版权与许可文件，并在这里补充具体文件来源。

## 核实来源

- [Komari 1.6.1 正式发布](https://github.com/komari-monitor/komari/releases/tag/1.6.1)
- [Komari API 文档](https://www.komari.wiki/dev/api)
- [Komari 实时节点与 Ping 汇总实现](https://github.com/komari-monitor/komari/blob/1.6.1/web/rpc/jsonrpc/common.go)
- [Komari 历史记录实现](https://github.com/komari-monitor/komari/blob/1.6.1/web/rpc/jsonrpc/common.record.go)
- [ServerBox 最低系统配置](https://github.com/lollipopkit/flutter_server_box/blob/main/ios/Runner.xcodeproj/project.pbxproj)
- [ServerBox 官方未签名 IPA](https://github.com/lollipopkit/flutter_server_box/releases)
- [Nezha Mobile 平台要求](https://github.com/hiDandelion/Nezha-Mobile/blob/main/README.md)
- [TrollStore 支持系统范围](https://github.com/opa334/TrollStore)

iOS 16.6.1 在 TrollStore 官方支持范围内。TrollStore 负责 IPA 安装；它不会让使用 iOS 17 专属 API 的程序自动兼容 iOS 16，因此客户端本身仍按 iOS 16 进行开发和编译。
