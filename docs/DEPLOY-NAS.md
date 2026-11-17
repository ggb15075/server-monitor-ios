# NAS 部署 Komari，VPS 安装探针

这个部署包让 NAS 的 Docker 运行 Komari 面板、数据库和历史记录；每台 VPS 只安装 Komari Agent。iPhone App 连接 NAS 面板读取数据。面板容器不会自动监控 NAS 宿主机；需要显示 NAS 本身时，再单独为它安装 Agent。

```text
VPS 上的 Agent ──主动上报──▶ NAS 上的 Komari Docker
                                  ▲
                         iPhone App 读取监控数据
```

模板不包含任何真实服务器 IP、账号、密码、面板地址或 Token。已按极空间 Z4Pro 准备不依赖 `.env` 的 Compose 编辑器版本，同时保留通用版本用于其他 NAS。

## 版本与文件

2026-11-17 核实的正式版本为 [Komari 1.6.1](https://github.com/komari-monitor/komari/releases/tag/1.6.1)，发布于 2026-10-26。Compose 固定官方镜像 `ghcr.io/komari-monitor/komari:1.6.1` 及其多架构摘要，不使用会自动变化的 `latest`：

```text
sha256:68df57a235d0d9d631f73a6c95466d1acc4220e9cae6ab2c5e009a51318937e0
```

已通过 GHCR manifest 核实 `linux/amd64` 和 `linux/arm64` 均存在。32 位 ARM NAS 不能直接使用这个镜像。Agent 独立发布，本次核实的正式版本是 [1.5.11](https://github.com/komari-monitor/komari-agent/releases/tag/1.5.11)，不需要与面板版本号相同。

| 文件 | 用途 |
| --- | --- |
| `deploy/docker-compose.yml` | 面板容器、端口、数据持久化、健康检查 |
| `deploy/docker-compose.zspace.yml` | 极空间 Compose 编辑器使用的完整内联版本，不需要 `.env` |
| `deploy/.env.example` | NAS 监听地址、端口、镜像版本模板 |
| `deploy/agent-config.example.json` | 可选的 VPS Agent 配置文件模板 |
| `deploy/data/` | 启动后保存数据库和其他持久化数据 |

模板已静态检查；尚未在你的 NAS 或 VPS 上实际部署。

## 1. 在 NAS 启动面板

### 极空间 Z4Pro 图形界面

你已经登录的极空间 Docker 支持 Compose，因此优先使用 `docker-compose.zspace.yml`：

1. 在文件管理器中创建一个持久化的项目文件夹，例如 `Docker/komari`，并在里面新建 `data`。
2. 进入 Docker 的 Compose 管理，新建项目，把项目目录选到刚才的 `Docker/komari`。
3. 将 `docker-compose.zspace.yml` 的全部内容粘贴进编辑器。它的镜像、端口和时区全部写在文件里，不需要额外上传 `.env`。
4. 确认存储映射：NAS 上刚才的 `data` 文件夹映射到容器 `/app/data`。模板使用 `./data`；如果当前编辑器不支持相对路径，用极空间文件夹选择器提供的真实宿主路径替换 `./data`，不要自行猜测 `/volume1` 等路径。
5. 保存并启动，等待镜像拉取完成，查看容器的健康状态与日志。
6. 用同一局域网的浏览器访问 `http://NAS的局域网IP:25774`，完成安装向导。

若宿主机 25774 端口已经占用，只修改 `"25774:25774"` 左侧，例如 `"25775:25774"`，此时访问端口改为 25775；容器内部端口和健康检查保持 25774。这个文件是独立的完整配置，不要与通用 Compose 同时创建两套容器。

极空间自带“远程访问”可以方便打开网页，但是否能作为第三方 App 和 VPS Agent 的长期 API 地址，要以实际连通测试为准。需要极空间账号交互登录的网页入口不能直接替代 Agent endpoint；这种情况下使用下文的 VPN 或 HTTPS 反代。

### 通用 Compose / SSH 方法

先在 NAS 应用中心安装它提供的 Docker / Container Manager，再创建一个持久化目录，例如共享文件夹里的 `docker/komari`。将 `deploy` 目录中的 `docker-compose.yml`、`.env.example` 上传到该目录，将 `.env.example` 复制为 `.env`，并新建 `data` 子目录。所有相对路径都以 Compose 文件所在目录为基准。

使用 NAS 的 Compose / 项目 / Stack 功能导入配置并启动即可。如果可以用 SSH，则进入该目录执行：

```sh
cp .env.example .env
mkdir -p data
docker compose config
docker compose pull
docker compose up -d
docker compose ps
```

只在第一次部署时执行复制 `.env` 的命令；已改过配置时不要覆盖它。旧版 NAS 如果仅提供 `docker-compose`，将命令中的 `docker compose` 换为 `docker-compose`。

默认映射 `25774:25774`，在局域网访问 `http://NAS的局域网IP:25774`。容器需要对 `data` 目录有写入权限。若提示 `permission denied`，在 NAS 的共享文件夹权限中授权容器使用的用户，保留原有其他文件的权限。

按首次启动的网页安装向导创建管理员并完成初始化。日后账号和设置保存在 `data` 中，重建容器不会清空。初始化完成后，私人监控可在面板开启私有站点，并在 API Key 设置中创建供 App 使用的 Key。

## 2. 让 VPS 和手机都能访问 NAS

VPS 必须能主动连接面板；手机在外面也需要一条访问 NAS 的路径。只填写家里的 `192.168.x.x` 地址，外面的 VPS 或蜂窝网络无法直接访问。

| 网络方式 | 面板地址示例 | 配置要点 |
| --- | --- | --- |
| 同一局域网 | `http://NAS局域网IP:25774` | 适合先验证本地访问；不能单独解决外部 VPS 上报 |
| 私有 VPN | VPN 内 NAS 的地址 | NAS、VPS、iPhone 都加入可互通的 VPN，允许 VPS 和手机访问 NAS 的 25774 端口 |
| 域名 + HTTPS 反向代理 | `https://monitor.example.com` | 域名、证书、外部入口和 NAS 代理均配置好；代理目标为 Komari 的 25774 |

已有可用的 Tailscale / WireGuard 等私有网络时，可以复用它。若使用域名反向代理，推荐采用 NAS 自带反向代理或已有 Nginx / Caddy；无需再在本 Compose 中运行一个重叠的代理服务。

反代必须保留 `Host`、`X-Forwarded-Proto`，并支持 WebSocket 升级。代理在 NAS 宿主机上时，目标通常为 `http://127.0.0.1:25774`，同时可在 `.env` 设置 `KOMARI_BIND_IP=127.0.0.1`。**代理在另一个容器里时，127.0.0.1 指向代理容器自己**，应改用双方共享 Docker 网络中的 `komari:25774`，或者 NAS 可访问地址。

使用独立域名根路径，避免部署到 `/komari/` 子路径。公网访问使用有效的 HTTPS 证书。若外层代理额外设置交互式登录或验证码，Agent 和 App 的 API 请求也会被拦截；应按已有代理的机器访问方案配置，或改用 VPN 内直连。WebSocket 来源受限时将实际域名加入面板允许列表。

官方参考：[Nginx 反向代理](https://www.komari.wiki/faq/nginx)。先从 VPS 和手机各访问一次面板地址，确认两端都通，再安装探针。

## 3. 在 VPS 安装 Agent

1. 在 NAS 面板的节点管理页面新增服务器，填写显示名称。
2. 打开该节点的 Agent 安装命令，将上报地址设置为 VPS 实际可达的 NAS 面板地址。
3. 在这台 VPS 的 SSH 终端执行面板生成的官方安装命令。命令里的节点 Token 只用于这一个节点，不要提交到 GitHub。
4. 只需要监控时，在官方安装脚本参数后追加 `--disable-web-ssh`，关闭探针的远程控制功能。要与本次固定版本一致，可同时追加 `--install-version 1.5.11 --disable-auto-update`。
5. 返回面板，确认节点上线，CPU、内存、磁盘、网络速率均开始更新。

官方 Agent 安装脚本和参数说明：[komari-agent](https://github.com/komari-monitor/komari-agent)。服务端口无需在 VPS 新开放，Agent 主动连接面板；ICMP 三网探测则需要 VPS 允许发出 ICMP。

`agent-config.example.json` 提供另一种配置方式：复制到 VPS 的受限目录后，填入 endpoint 和该节点的 Token，再让 Agent 以 `--config /实际路径/agent-config.json` 启动。文件须允许实际运行 Agent 的服务用户读取；不要把有真实 Token 的文件回传到公开仓库。配置文件支持 `disable_web_ssh`、`month_rotate` 和 `include_nics` 等字段。现有 systemd 服务可用以下命令查看状态与近期日志：

```sh
systemctl status komari-agent --no-pager
journalctl -u komari-agent -n 50 --no-pager
```

如果安装时改过服务名，替换命令中的 `komari-agent`。OpenRC、NAS 容器等非 systemd 环境使用各自的服务管理工具。

## 4. 设置电信、联通、移动探测

在 Komari 后台的 Ping / 延迟任务中分别创建“电信”“联通”“移动”任务，选择要检测的 VPS，选择协议并填写该运营商中你实际希望检测的目标。最好选同一地区的稳定目标，任务名称可加地区，例如“上海电信”。初次建议 60 秒一个样本，随后按所需精度调整。

三条线路表示 **VPS 到所选三网目标** 的结果，不是 iPhone 到 VPS 的延迟，也不能代表全国所有用户的线路。目标需要事先验证可以稳定响应；运营商会限速或屏蔽部分地址，没有任何固定公网 IP 可以永久保证适用，因此模板不硬编码公共目标。

- ICMP 任务可以展示采样期间的丢包比例。
- TCP / HTTP 任务展示连接或请求失败比例，不能当作 ICMP 丢包率。
- 刚创建时历史为空是正常的；按 60 秒间隔，需要积累几十分钟才能形成有意义的历史条。
- App 读取真实任务和记录；未配置任务就没有该线路数据。

官方 [API 文档](https://www.komari.wiki/dev/api) 说明了任务列表、历史记录与协议。面板提供的 Ping 汇总按查询时间窗口计算；App 的历史区间和后台应保持一致后再比较。

## 5. 流量、价格与到期信息

节点的价格、币种、计费周期、到期日、套餐流量和标签由你在面板填写。Agent 无法自动知道商家的套餐和账单。截图中的线路标签、带宽和到期天数，分别来自节点标签与套餐元数据。

Komari 的 `traffic_limit_type` 支持 `up`（上传）、`down`（下载）、`sum`（双向相加）、`max`（双向取较大值）、`min`（双向取较小值）。按商家的计费规则选择，App 据此计算用量和剩余量。

Agent 的 `month_rotate` 是每月重置日，`0` 表示不启用月重置；不是“多少天后重置”。可在安装参数里设置 `--month-rotate 1` 表示每月 1 日，或在配置 JSON 中设置 `"month_rotate": 1`。请使用商家真实结算日与时区；重置由 Agent 所在系统的设置和实际版本实现决定，NAS 的 `TZ` 不会替 VPS 修改时区。

若未启用周期重置，累计流量不能标成“本月已用”。App 不会凭空补齐装探针前的数据；商家账单与探针统计也可能因采集起点、单位（GB/GiB）、网卡范围而不同。VPS 同时有物理网卡、Docker 和 VPN 网卡时，按真实计费出口设置 `include_nics`，避免把同一流量在多个接口重复相加。网卡名可先用 `ip -br link` 查看，不要假定必然叫 `eth0`。

## 6. 在 iPhone App 中连接

安装 IPA 后打开 App 的连接设置，选择 Komari，填入手机能访问的面板基础地址（如 `https://monitor.example.com`，不加 `/api/rpc2`）。私有站点填写在面板创建的 API Key；公开站点允许匿名读取时可留空。这里需要 **面板 API Key**，不是节点 Agent Token，也不是 VPS 的 SSH 密码。

先在 iPhone Safari 中验证同一地址可达。使用局域网地址时允许 App 访问本地网络；使用 VPN 地址时先连接 VPN。保存后读取真实数据，退出演示模式。没有接入后端前，演示节点仅用于查看界面。

## 7. 备份与升级

极空间图形界面可以先停止这个 Compose 项目，再复制或备份项目的 `data` 文件夹和 Compose 文本到另一个备份位置，完成后启动。升级则在编辑器中替换镜像版本与摘要，保存后重新拉取并启动。下面的命令用于通用 SSH 部署；如果你的文件名仍是 `docker-compose.zspace.yml`，各命令添加 `-f docker-compose.zspace.yml`，例如 `docker compose -f docker-compose.zspace.yml stop komari`。

数据库和历史记录都在 `data` 中。升级前在 NAS 建立备份目录，并短暂停止容器以取得一致的 SQLite 及指标数据备份。在 Compose 目录执行：

```sh
mkdir -p backups
docker compose stop komari
tar -czf "backups/komari-data-$(date +%Y%m%d-%H%M%S).tar.gz" data docker-compose.yml .env
docker compose start komari
```

确认 `tar` 成功再依赖该备份；即使备份失败，也应手动执行最后一条启动命令恢复服务。备份含账号与 Token，应保存在自己的 NAS 备份位置，不提交到 GitHub。

升级时先阅读目标正式版本的 release notes，备份后把 `.env` 的 `KOMARI_IMAGE` 改为目标版本的完整 tag（如需继续固定摘要，也同时替换为该版本摘要），然后执行：

```sh
docker compose pull
docker compose up -d
docker compose ps
docker compose logs --tail 80 komari
```

确认网页可以登录、VPS 已上线、手机可以刷新。Agent 固定版本需单独升级。新版本可能迁移数据库，回滚时应停止容器，保留当前 `data` 为另一个目录，再恢复升级前备份的整个 `data` 和原镜像配置；不要让旧程序直接打开已经迁移的新数据库，也不要在运行中覆盖数据库文件。

## 常见故障

| 现象 | 检查项 |
| --- | --- |
| NAS 网页打不开 | 容器是否启动、端口冲突、映射地址、NAS 防火墙 |
| 面板正常但 VPS 离线 | VPS 能否访问 endpoint、Token 是否属于该节点、代理是否拦截请求 |
| 手机在家能用，外面不能用 | 使用了局域网地址；改用可达的 VPN 地址或 HTTPS 域名 |
| 返回 401 / 403 | 私有站点需要有效面板 API Key；不能使用 Agent Token |
| 返回 HTML 或验证码 | 填错了基础地址，或外层反代登录 / 防护页面阻挡了 API |
| 三网显示空白 | 未创建任务、未选中节点、没有积累样本、目标不响应 |
| 流量看起来翻倍 | 检查双向计费模式和物理 / VPN / 容器网卡重复统计 |
| `no matching manifest` | 检查 NAS CPU 架构；模板支持 amd64 / arm64 |

参考：[官方 Docker 部署](https://www.komari.wiki/install/docker)、[固定版本源码](https://github.com/komari-monitor/komari/tree/1.6.1)、[Agent 参数](https://github.com/komari-monitor/komari-agent/tree/1.5.11)。
