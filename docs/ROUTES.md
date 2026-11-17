# VPS 回程线路检测

云哨在服务器名称下方、系统与 IPv4 / IPv6 标记之后显示三网线路标签。标签来自 VPS 发起的实际 IPv4 traceroute；没有报告时显示“线路未检测”，无法识别时显示“无法判断”。这与 CPU、网速和三网 ICMP 延迟探测是不同的数据。

## 采集

`scripts/detect_routes.py` 使用 Python 3 标准库、curl 和官方 [NextTrace 1.7.6](https://github.com/nxtrace/NTrace-core/releases/tag/v1.7.6)，不读取 SSH 密码或管理员 API Key。默认只测量；指定 `--agent-config` 时，使用该节点已经存在的 Agent endpoint / token，将线路报告上报到自己的节点。先安装并验证该版本的官方 NextTrace 二进制，再在被监控 VPS 上执行：

```sh
sudo python3 scripts/detect_routes.py \
  --nexttrace /opt/yunshao-route/nexttrace \
  --agent-config /opt/yunshao-agent/config.json \
  --output-dir /opt/yunshao-route/results > /opt/yunshao-route/report.json
```

stdout 只输出一个 JSON 报告，运行诊断输出到 stderr。`--output-dir` 可选，指定后会创建以 UTC 时间命名的新目录，保存三个目标的原始 JSON、stderr 和最终报告；不会覆盖已有测量。新目录权限为 0700，原始文件为 0600。

测量固定使用三个目标：电信广东深圳 `202.96.134.133`、联通广东深圳 `210.21.196.6`、移动广东 `211.136.192.6`。这些是当前选定目标，不能代表整个运营商。每跳采样 2 次、最多发 4 个探针、最多 30 跳、单探针超时 1500ms；每个目标的程序运行最多 150 秒，顺序运行三个目标。脚本可按需重复运行，也可交给系统定时器每天测量；它自身不会创建定时任务。

## 识别含义

脚本读取 NextTrace 传统 JSON 的 `Hops[][]`。仅采纳成功响应、IPv4 公网跳点的 `Geo.asnumber`；其他运营商、失败响应、非公网地址、IPv6 跳点、空 ASN 或损坏 JSON 都不能生成当前目标运营商的线路标签。

| 可见 ASN | 标签 |
| --- | --- |
| AS4134 | 电信163 |
| AS4809 | 电信CN2 |
| AS4837 | 联通169 |
| AS9929 | 联通9929 |
| AS58453 | 移动CMI |
| AS58807 | 移动CMIN2 |

同时看到增强骨干与普通国内骨干时，优先展示增强骨干，例如可见 AS4809 和 AS4134 时显示“电信CN2”。这仅表示本次路径中观察到相应 ASN，**不能据此证明 CN2 GIA / GT、商业套餐、三网优化或全程直连**。不会根据延迟、服务器名称、手工标签或商家宣传猜测线路。

NextTrace 的 ASN 信息依赖其数据服务，受服务可用性、数据库准确性及路由器回应策略影响。目标不回应仍可能观察到骨干 ASN；App 会分别显示“未确认到达目标”，保留这项限制。程序退出码 0 或 `StopReason` 都不能替代目的 IP 的实际成功响应。

检测方向为 **VPS → 中国大陆目标（通常称回程）**，不代表中国用户到 VPS 的去程，也不代表 IPv6 线路。运营商可能按目标、时间、协议或负载均衡改变路径。App 详情会显示检测时间、方向、IP 协议、目标和可见 ASN；需要最新路径时重新检测并更新报告。

## 保存到 Komari

报告放入对应节点的 `public_remark`，App 从以下版本标记读取；上报时外层用可折叠的 `details` 包装，减少网页备注的占用：

```text
[yunshao-route-v1]
这里是 detect_routes.py 输出的 JSON 文档
[/yunshao-route-v1]
```

指定 `--agent-config /opt/yunshao-agent/config.json` 后，脚本调用 Komari 1.6.1 的 `/api/clients/v2/rpc`，使用该节点既有 Token 和 `agent.basicInfo`，只更新自己的 `public_remark`。Token 通过 curl stdin 的 JSON 请求体提交，不出现在 URL、进程参数或脚本日志中。HTTPS 保留证书校验，不跟随重定向；优先尝试 IPv6，失败再尝试系统默认路径。网络或 RPC 错误使脚本非零退出，已测量报告仍会保留。

如果节点还有其他公开备注，安装时将不含线路块的原文保存为 UTF-8 文件，并添加 `--remark-prefix-file /opt/yunshao-route/remark-prefix.txt`。脚本会保留该前缀，再追加更新的线路块。**后续在网页修改其他公开备注时，也需同步这个前缀文件**，否则下一次定时上报会以原前缀重写公开备注。前缀最多 32 KiB，最终公开备注最多 64 KiB。不要将完整旧线路块放进前缀文件。

云哨通过既有 `common:getNodes` 读取公开备注，不新增手机端写接口。采集端不需要管理 API Key、网页 SSH 或通用远程命令功能。

公开备注会随节点元数据返回给有权查看该节点的访问者。此处只应保存经过筛选的报告，不放 SSH 凭据、API Key 或不希望公开的原始日志。私有面板的现有访问控制仍由 Komari 管理。

官方结构参考：[NextTrace Result / Hop](https://github.com/nxtrace/NTrace-core/blob/v1.7.6/trace/trace.go)、[IPGeoData](https://github.com/nxtrace/NTrace-core/blob/v1.7.6/ipgeo/ipgeo.go)、[Komari Client 模型](https://github.com/komari-monitor/komari/blob/1.6.1/database/models/models.go)、[Komari 节点编辑](https://github.com/komari-monitor/komari/blob/1.6.1/web/rpc/jsonrpc/admin.client.go)。
