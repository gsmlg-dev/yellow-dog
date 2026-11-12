# Worker WebSocket 连接与递归/转发 DNS（云上第一版）设计

日期：2026-11-12
状态：已确认（2026-11-12）

## 1. 意图

把 Yellow Dog 从“Management 能配置、Worker 能跑权威 DNS 的骨架”推进到“云上四个节点真正提供 DNS 服务”。

- Management 已用 podman 部署在 vultr-01。
- 在 vultr-01、vultr-02、vultr-03、vultr-04 上各运行一个 Worker，通过内网 VPN 用 WebSocket 连接 Management。
- Management 管理数据并下发给 Worker；每个 Worker 可选择启动哪些服务。
- 第一个服务是 DNS。第一版提供**递归解析（可开关）和转发区**，只给所有者自己的电脑和云上服务使用。

后续路线（不在本版范围内，但设计不能堵死）：权威区（gsmlg.net / gsmlg.dev / gsmlg.org / gsmlg.app / gsmlg.com）、存根区、RPZ，家庭和办公网络接入 Worker。

## 2. 目标

1. **连接**：Worker 使用 Hex `phoenix_socket_client` 通过 WebSocket 连接 Management，替换现有 HTTP 轮询（`POST /api/worker/connect`）。不保留两套连接方式。
2. **下发**：Management 发布（`confirm_target`）后，经 WebSocket 推送给在线 Worker；Worker 应用后通过同一连接回报结果。Worker 上线或重连时，Management 主动推送当前 Target。
3. **DNS 递归**：Worker 从根服务器开始做迭代递归，并带缓存。可按服务开关。
4. **DNS 转发区**：按域名后缀把查询转发到指定上游，可配置多个上游（地址和端口）。
5. **访问控制**：按来源 IP/CIDR 的允许列表。不在列表里的来源返回 REFUSED。
6. **部署**：四台 NixOS 主机用 podman 运行 Worker 容器。
7. **离线可用**：Management 不可达或 Worker 重启时，Worker 用本地最后一次应用的快照继续服务（现有 LocalStore 行为保留）。

## 3. 非目标

- 存根区、RPZ、DNSSEC 验证、DoT/DoH/DoQ、ECS、多 View/GeoIP 分流。
- 对公网提供 gsmlg.* 权威解析（现有的权威区能力保留，但本版不做扩展和验收）。
- 家庭/办公网络节点接入。
- Worker 网络暴露控制：外层已有防火墙，外部不可访问。DNS 监听地址可配置即可。
- VPN 内的 TLS：VPN 内使用 `ws://`，认证依靠 Worker 令牌（**我的决定**，所有者可改为 `wss://`；现有 bootstrap 的 TLS 文件字段保留可用）。
- 兼容旧的 HTTP 轮询协议、旧 `server_agent` 的 socket 协议，以及旧的 legacy DNS 应用。

## 4. 反目标（技术上能跑但算失败）

- 递归服务变成开放解析器：没有 ACL 配置时默认拒绝所有来源，而不是允许所有来源。
- 慢的递归查询阻塞其他查询。现在 UDP handler 每个包都 `GenServer.call` adapter，递归不能沿用这种串行方式。
- 断开 Management 后 DNS 停止服务，或 Worker 因连不上 Management 而启动失败。
- 为了递归引入 legacy 的 Store/Concord/Telemetry 依赖，或在产品代码里直接使用 `:gen_udp`。

## 5. 约束（来自仓库）

- 只有 `yellow_dog_config_spec`、`yellow_dog_management`、`yellow_dog_worker`、`ex_dns` 等在根构建中。legacy 应用（`yellow_dog_dns`、`yellow_dog_resolved`、`yellow_dog_server_agent`）不参与构建，只能作为参考源码，可以复制代码过来改写。
- UDP 只能走 Abyss。上游查询使用 `Abyss.Client.send_recv/5`：它为每次查询使用临时端口，并校验响应的来源地址和端口。
- WorkerPlan 对未知字段直接报错，所以新增 DNS 字段要在 ConfigSpec 中同时为两端定义，并补齐共享 fixtures。
- `phoenix_socket_client`：mix.lock 里的 0.8.2 依赖 `http_web_socket ~> 0.11`，与 Worker 的 `http_fetch`（`http_core 1.0.0-rc.13`）冲突，必须使用 0.9.x（依赖 `http_web_socket ~> 1.0.0-rc.4`）。该库属于 gsmlg-dev 组织，遇到库的问题按 upstream-issue-routing 处理，不在本地绕过。
- Management 的 HTTP 层是 Gaoxy。新增的 Worker socket 路径必须加入 `config/config.exs` 的 `websocket_paths`，否则 Gaoxy 不会做 WebSocket 升级。
- Worker 凭据边界保持独立（`management-integration-security.md`）：Worker socket 不经过 UI 的网关断言，也不接受 Management JWT。Worker 令牌只在 Worker socket 上有效。
- `default.nix` 的 `fetchMixDeps` 哈希会随依赖变化，需要更新。

## 6. 已确定的做法

### 6.1 连接协议（Worker ↔ Management）

- **Management 端**：新增 `Phoenix.Socket`，WebSocket 路径固定为 `/api/worker/connect`（与 Caddy 规则一致，见 6.7）。注意 Phoenix 默认会在 socket 路径后追加 `/websocket`，所以要写成 `socket "/api/worker", ..., websocket: [path: "/connect"]`，同时把该路径加入 Gaoxy 的 `websocket_paths`和 channel `worker:<worker_id>`。
  - `connect/3` 用 `worker_id` 和 `token` 认证，复用 `WorkerConnections` 的哈希比对（`secure_compare`）和匿名注册逻辑。
  - 认证失败时拒绝连接，不泄露原因。
- **Worker 端**：用 `phoenix_socket_client` 0.9.x 连接。
  - 重连由 Worker 自己负责，采用指数退避加上限，可参考 `server_agent` 的 `schedule_rejoin`。
  - 令牌不进入可被 `format_status` 打印的状态。
- **消息**（具体事件名留给实现者）：
  - Worker → Management：`report`，内容沿用现有报告结构（`capabilities`、`services` 状态、`applied_revision`、`applied_digest`、`apply_error`），并在 `capabilities` 中加入新能力。加入频道后立即发送一次，应用完成后发送一次，之后定期发送作为心跳。
  - Management → Worker：`target`，内容为 `{revision, digest, plan}`。在加入频道时推送一次，`confirm_target` 时通过 PubSub 推送给对应的 Worker。
  - Worker 侧校验（worker_id、revision、digest、拒绝过期 Target）和 `submit_plan` 应用流程保持不变。
- **在线状态**：以频道是否在线为准，同时更新 `last_seen_at`。UI 现有的 5 秒刷新可以保留。
- **Bootstrap**：
  - `management_url` 改为 ws/http 源地址，由 Worker 自己推导出 socket 地址。
  - `poll_interval_ms` 改为心跳和重连参数，或者删除。
  - 本地模式（只有 TOML、没有 connection 段）保持不变。
- **删除**：`ConnectionHTTP`、`WorkerAPI` 的 `POST /connect`，以及 Worker 的 `http_fetch` 依赖（前提是没有其他用途）。

### 6.2 WorkerPlan / ConfigSpec 扩展

扩展 `dns` 服务的 `config` 字段。字段名留给实现者，但语义固定如下：

- `listen_addresses`（替换现有单个 `listen_address`）、`port`：监听地址改为列表，使回环地址、VPN IP 和 podman 网桥地址可以同时监听（**我的决定**）。是否支持 IPv6 地址由实现者决定。
- `recursion`：是否开启递归，布尔值。
- `forward_zones`：列表，每项为 `{name, forwarders: [{address, port}]}`。匹配域名后缀，最长后缀优先。
- `allow_query`：CIDR 列表，支持 IPv4 和 IPv6。为空表示拒绝所有来源。
- 缓存上限和 TTL 上下限：可选，有默认值。

所有字段都要有上限（参照现有的 1024/256/64 风格），要进入 digest 和 TOML 编解码，并补齐共享 fixtures。

### 6.3 Worker DNS 查询处理顺序

1. 来源 IP 不在 `allow_query` 中：返回 REFUSED。
2. 命中本 Worker 的权威区（现有逻辑）：权威应答。
3. 命中转发区：只转发（forward-only），**我的决定**。上游视为递归服务器，查询带 RD=1；按顺序或轮询依次尝试，每次有超时；全部失败返回 SERVFAIL，不回退到自身递归。应答设置 `ra=1`，结果进入缓存。
4. `recursion` 开启且查询的 RD=1：从缓存应答，或做迭代递归。
5. 其他情况：返回 REFUSED。

递归的最低要求：
- 内置根提示（root hints）。
- 处理 referral、使用 glue，没有 glue 时先解析 NS 地址。
- 追踪 CNAME 链。
- 检查 bailiwick，丢弃越界记录。
- 限制最大深度和总步数，防止死循环。
- 用 `:crypto` 生成随机事务 ID，并校验响应的 ID 和问题部分。
- 上游 UDP 响应 TC=1 时改用 TCP 重试。
- 缓存正面结果和 RFC 2308 负面结果，按 TTL 过期，有容量上限。缓存属于单个服务实例，不使用全局 named table。

客户端响应超过 512 字节时，要么支持 EDNS0 的 UDP 尺寸，要么设置 TC=1 让客户端改用 TCP。现有 TCP 监听保留。

并发：递归和转发查询不能阻塞 adapter 进程，也不能阻塞其他查询。adapter 只提供当前配置和缓存的句柄。

### 6.4 Management 中的配置位置

第一版把递归开关、转发区和 `allow_query` 作为 **DNS 服务实例的参数**，在“节点管理 → 服务实例”中编辑，经 `build_plan` 进入 WorkerPlan（**我的决定**）。理由：WorkerPlan 现在只承载服务 config 和固定版本的 Zone，现有的 `DnsView`/`DnsAcl` 模型（`recursion_enabled`、`fallback_forwarders`、规则）还没有导出路径，而且包含国家、多 View 等第一版不做的内容。

把 View/ACL 编译进 WorkerPlan 是后续工作。到时 View 的递归/转发设置与服务参数怎么合并，需要另外设计。

### 6.5 部署

- 镜像：使用现有构建方式（`Dockerfile` + `build_img.sh`，或 flake 的 `docker-worker`）生成 `ghcr.io/gsmlg-dev/yellow-dog-worker`。
- 四台 NixOS 主机直接用 `podman run` 运行（测试阶段，不写入 NixOS 配置）：
  - `--network host`：直接绑定 53/udp 和 53/tcp，同时保留真实的客户端源 IP，供 ACL 使用。
  - 持久卷挂载 `data_dir`，用于存放快照、日志和 `connection.toml`。
  - bootstrap 文件只读挂载，设置 `YELLOW_DOG_WORKER_BOOTSTRAP`。
  - 绑定 53 端口所需的能力（`CAP_NET_BIND_SERVICE` 或以 root 运行）。
- Worker 通过 Caddy 的 VPN 入口 `ws://10.10.10.10:4270` 访问 Management（见 6.7）。

### 6.6 部署权限

- 实现方（Claude）负责：构建并发布 Worker（以及需要时 Management）镜像，并在云主机上更新为新镜像。
- 其他任何部署变更（NixOS 配置、容器参数、Management 认证模式、监听地址、防火墙、VPN 等）必须先告知所有者并获得同意后再做。
- 部署前要检查宿主机 53 端口是否已被占用（如 systemd-resolved），结果写入操作手册，处理方式需所有者同意。

### 6.7 Management 在 VPN 上的可达性（2026-11-12 实地查看）

现状：
- vultr-01 上 Management 容器使用 host 网络，`YELLOW_DOG_MANAGEMENT_BIND_ADDRESS=127.0.0.1`，`TRUSTED_PROXY_IP=127.0.0.1`，对外 origin 为 `https://yellow-dog.gsmlg.net`。
- Caddy 在 `yellow-dog.gsmlg.net` 上要求 mTLS 客户端证书，然后反代到 `127.0.0.1:4270`，供 UI 使用。
- Caddy 在 `http://10.10.10.10:4270`（WireGuard `wg0`，10.10.10.0/24）上只放行来自 10.10.10.54（vultr-02）、10.10.10.53（vultr-03）、10.10.10.55（vultr-04）的 `POST /api/worker/connect`，其他请求一律返回 403。
- 四台主机 53 端口都空闲，systemd-resolved 未运行，podman 已安装。

结论：不需要修改 Management 的认证模式或监听地址。Worker 一律连 `ws://10.10.10.10:4270/<worker socket 路径>`，经 Caddy 反代到 Management。所需的部署改动如下，**每项都要先征得所有者同意**：
1. Caddy 的 `@worker` 匹配规则：路径保持 `/api/worker/connect`（Management 把 Worker WebSocket 挂在这个路径上），`method POST` 改为 `method GET`（WebSocket 握手），`remote_ip` 加上 10.10.10.10，让 vultr-01 本机的 Worker 也走同一入口。所有者已同意改 Caddy（2026-11-12）。该配置位于 vultr-01 的 NixOS 配置中，需要重建系统生效；执行前确认配置仓库位置和执行人。
2. 在四台主机上用 `podman run` 直接启动 Worker 容器（host 网络、数据卷、bootstrap 文件）。测试阶段**不写入 NixOS 配置**，方便修改（所有者已同意，2026-11-12）。

Management 端的 Worker socket 不能依赖 UI 的认证（mTLS 在 Caddy 的另一个站点上），只能靠 Worker 令牌认证。

## 7. 验收（“云上跑通”）

1. 在 Management 中登记 vultr-01 到 04 四个 Worker，各自拿到 bootstrap。
2. 四台主机的 podman Worker 容器启动后，通过 WebSocket 连上 Management。UI 显示四个 Worker 在线，能力包含 DNS。
3. 为每个 Worker 配置 DNS 服务：开启递归，配置至少一个转发区，`allow_query` 只包含 VPN 网段和本机。发布后 Worker 在数秒内应用并回报成功，不需要等轮询周期。
4. 从允许的来源执行 `dig @<worker> example.com A` 和 `AAAA`，能拿到正确的递归结果。第二次查询命中缓存，TTL 递减。转发区内的域名走指定上游（可通过抓包或上游日志证明）。
5. 从不在允许列表中的来源查询，返回 REFUSED。关闭递归后，非转发区查询返回 REFUSED。
6. 停止 Management 后，Worker 继续服务；重启 Worker 容器后，Worker 用本地快照恢复服务；Management 恢复后，Worker 自动重连并同步。
7. 自动化：ConfigSpec 新字段有单元测试和共享 fixtures；Worker 的递归、转发、ACL、缓存在本地用测试用的假根和假上游覆盖（不依赖公网）；Management 的 socket 认证和推送有测试；`mix compile --warnings-as-errors`、`mix format --check-formatted`、`mix credo --strict`、`scripts/e2e/architecture_smoke.sh` 和两个 release smoke 全部通过。

## 8. 留给实现者的决定

- 事件名、心跳间隔、退避参数。
- ConfigSpec 字段的具体命名和上限数值。
- 递归模块的内部结构（可以从 legacy `RecursionWorker` 和 `yellow_dog_resolved` 的 `Forwarder`/`Cache` 复制后重写；legacy 的 `RecursionWorker` 读的是 `rdata` 字段，实际字段是 `data`，不能直接运行）。
- 上游 TCP 查询的实现方式（Worker 现有 TCP 监听用的是 `:gen_tcp`）。
- 根提示是否包含 IPv6，以及是否使用 IPv6 上游（取决于主机的 IPv6 连通性）。
- `podman run` 的具体参数和重启策略（测试阶段不写 NixOS 配置）。
