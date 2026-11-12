# Worker WebSocket 连接与递归/转发 DNS 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Worker 通过 WebSocket 接收 Management 推送的配置，并在 vultr-01 到 04 上提供带 ACL 的递归和转发 DNS。

**Architecture:**
- ConfigSpec 给 `dns` 服务的 config 增加 `recursion`、`forward_zones`、`allow_query` 三个字段。
- Worker 的 DNS 查询顺序：ACL → 权威区 → 转发区 → 迭代递归。上游查询走 `Abyss.Client.send_recv/5`，缓存是每个服务实例自己的 ETS 表。
- Management 新增 `Phoenix.Socket`，路径正好是 `/api/worker/connect`。Worker 用 `phoenix_socket_client` 0.9 连接，替换现有的 HTTP 轮询。

**Tech Stack:** Elixir 1.18 / OTP 27-28、Phoenix 1.8 Channels（Gaoxy adapter）、`phoenix_socket_client ~> 0.9`、Abyss `~> 1.0.0-rc.13`、in-umbrella `ex_dns`、Ecto/PostgreSQL、podman。

**Spec:** `docs/superpowers/specs/2026-11-12-worker-ws-recursive-dns-design.md`

## Global Constraints

- 产品代码禁止直接使用 `:gen_udp`。UDP 上游查询只能用 `Abyss.Client.send_recv/5`；测试文件中的假 DNS 服务器可以用 `:gen_udp`。
- Worker 不能依赖 Management 应用、PostgreSQL 或 legacy 应用（`yellow_dog_dns`、`yellow_dog_resolved`、`yellow_dog_server_agent`、Store、Concord、YellowDog.Telemetry）。legacy 代码只能复制后改写。
- 修改 `ex_dns`（共享协议库）前必须先停下来征得所有者同意（AGENTS.md）。
- 依赖用 `{:phoenix_socket_client, "~> 0.9"}`，不能用 0.8，因为 0.8 与 `http_core 1.0.0-rc.13` 冲突。该库的问题按 upstream-issue-routing 上报到 gsmlg-dev，不在本地绕过。
- Worker socket 路径固定为 `/api/worker/connect`，不带 `/websocket` 后缀。写法：`socket "/api/worker", ..., websocket: [path: "/connect"]`。同时把这个路径加入 Gaoxy 的 `websocket_paths`（`apps/yellow_dog_management/config/config.exs`、`config/dev.exs`、`config/test.exs`）。
- 令牌只能放在 channel join payload `{"token", "report"}` 里，不能出现在 URL query 或 HTTP 头中（Caddy 访问日志会记录 URI 和自定义请求头），也不能出现在日志、`format_status`、审计记录里。握手为 `GET /api/worker/connect?vsn=2.0.0&worker_id=<uuid>`。（2026-11-12 裁定：原方案把令牌放在 HTTP 头 `x-yellow-dog-worker-token` 中，但 Caddy 访问日志会记录自定义请求头，令牌会落入日志，所以改为只放在 channel join payload 中。）
- 没有配置 `allow_query` 时默认拒绝所有来源。
- `listen_address` 保持单个 IPv4 地址，云上部署使用 `0.0.0.0`（设计文档 6.2 已修订）。
- 项目在设计阶段，不保留 HTTP 轮询，也不做协议兼容层。
- Mix 命令一律在 `devenv shell` 中运行。不要动工作区里与本任务无关的未提交改动。
- 提交使用 Conventional Commits，结尾带 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`，不加 "Generated with Claude Code"。

## Review Focus

1. **令牌轮换时 Worker 正在线**：轮换后，旧连接要在下一次心跳报告时被拒绝并断开，不能一直保持在线。测试见 Task 6。
2. **伪造或错位的上游响应**：ID 不符、问题段不符、来源地址或端口不符的响应必须丢弃。测试见 Task 3。
3. **递归死循环**：CNAME 环或 NS 互相 referral 时，要在步数上限内返回 SERVFAIL，不能挂住。测试见 Task 5。
4. **大响应**：客户端不带 EDNS 时，UDP 响应超过 512 字节要设 TC=1；带 EDNS 时，按客户端声明的大小处理，上限 1232。测试见 Task 4。
5. **非 A 类记录类型**：TXT、MX、HTTPS、未知类型 65280 经过递归和缓存后，要能原样返回。测试见 Task 2 和 Task 5。

---

### Task 1: ConfigSpec 增加 DNS 递归、转发和 ACL 字段

**Files:**
- Modify: `apps/yellow_dog_config_spec/lib/yellow_dog/config_spec.ex`（`dns_config/2` 约 L227）
- Modify: `apps/yellow_dog_config_spec/test/fixtures/*.toml`（按需修改；新增 `recursive_forward.toml`）
- Test: `apps/yellow_dog_config_spec/test/config_spec_test.exs`

**Interfaces:**
- Produces：规范化后的 dns config 总是包含以下 5 个键。输入里后三个键可以省略，省略时使用默认值：
  ```
  %{"listen_address" => "0.0.0.0", "port" => 53,
    "recursion" => false,                       # 默认 false
    "allow_query" => ["10.10.10.0/24"],        # 默认 []，已规范化的 CIDR 字符串，排序后去重
    "forward_zones" => [%{"name" => "corp.example.", "forwarders" => [%{"address" => "10.0.0.2", "port" => 53}]}]}
  ```
  `forward_zones` 按 `name` 排序，`forwarders` 保持输入顺序（顺序就是尝试顺序）。

- [ ] **Step 1：写失败的测试** `describe "dns policy config"`，覆盖以下情况：
  - 省略三个新键时，规范化结果为 `recursion: false, allow_query: [], forward_zones: []`。
  - `"allow_query" => ["10.10.10.7/24", "::1/128", "10.10.10.0/24"]` 规范化为 `["10.10.10.0/24", "::1/128"]`。
  - `forward_zones` 名称统一为带结尾点的小写形式。允许 `"."`（表示转发全部）。名称重复时报 `:duplicate_forward_zone`。
  - forwarder 地址可以是 IPv4 或 IPv6，端口范围 1..65535。端口省略时规范化为 53。
  - 上限：`allow_query` ≤ 128，`forward_zones` ≤ 64，每个区的 `forwarders` 在 1..8 之间。超限返回 `:too_many`，空 forwarders 返回 `:invalid_value`（使用现有的错误原子风格）。
  - 未知键（例如 `"cache"`）仍然报错。
  - 新字段参与 `plan_digest`：只改 `recursion` 时 digest 改变。
  - `encode/1` 然后 `decode/1` 能完整往返 `recursive_forward.toml`。

- [ ] **Step 2：运行测试，确认失败**
  Run：`devenv shell -- bash -c 'cd apps/yellow_dog_config_spec && mix test'`
  Expected：新测试 FAIL。

- [ ] **Step 3：实现** 扩展 `dns_config/2`，`shape` 的可选键改为 `~w(recursion allow_query forward_zones)`。新增私有校验函数 `cidr/2`、`forward_zone/2`、`forwarder/2`。CIDR 规范化方式：主机位清零，IPv6 用 `:inet.ntoa` 输出的小写压缩形式。

- [ ] **Step 4：运行测试，确认通过**；同时跑 Worker 和 Management 里引用 dns config 的现有测试：
  Run：`devenv shell -- mix cmd --app yellow_dog_config_spec --app yellow_dog_worker mix test`
  Expected：PASS。Worker 现有 DNS 测试此时还不检查 ACL，应全部通过。

- [ ] **Step 5：提交** `feat(config-spec): add DNS recursion, forward zones and allow_query`

### Task 2: Worker DNS 基础组件——ACL 和缓存

**Files:**
- Create: `apps/yellow_dog_worker/lib/yellow_dog/worker/dns/acl.ex`
- Create: `apps/yellow_dog_worker/lib/yellow_dog/worker/dns/cache.ex`
- Test: `apps/yellow_dog_worker/test/yellow_dog/worker/dns/acl_test.exs`
- Test: `apps/yellow_dog_worker/test/yellow_dog/worker/dns/cache_test.exs`

**Interfaces:**
- `Acl.compile([String.t()]) :: {:ok, Acl.t()}`
- `Acl.allowed?(Acl.t(), :inet.ip_address()) :: boolean()`：IPv4 映射的 IPv6 地址（`::ffff:a.b.c.d`）按 IPv4 匹配。
- `Cache.new(opts) :: Cache.t()`：创建一张未命名、`:public`、`read_concurrency: true` 的 ETS 表，表的属主是调用进程（DnsAdapter）。默认值 `max_entries: 10_000, max_ttl: 86_400, negative_ttl_cap: 3_600`。
- `Cache.get(Cache.t(), name :: String.t(), type :: non_neg_integer()) :: {:ok, %{rcode: 0 | 3, answers: [DNS.Message.Record.t()], authority: [DNS.Message.Record.t()]}} | :miss`：返回的记录 TTL 已减去缓存停留时间。
- `Cache.put(Cache.t(), name, type, %{rcode:, answers:, authority:}) :: :ok`：正面结果的 TTL 取 answers 中的最小值；负面结果按 RFC 2308，取 SOA 的 minimum 与 SOA TTL 中较小的一个，再受 `negative_ttl_cap` 限制。超过 `max_entries` 时先删除过期条目，仍然超出就删除最旧的条目。
- `Cache.delete(Cache.t()) :: :ok`

- [ ] **Step 1：写失败的测试**，覆盖以下情况：
  - ACL：`["10.10.10.0/24"]` 允许 `{10,10,10,54}`，拒绝 `{10,10,11,1}`；`[]` 拒绝所有地址；`["::1/128"]` 允许 `{0,0,0,0,0,0,0,1}`；`["10.0.0.0/8"]` 允许 `{0,0,0,0,0,0xffff,0x0a01,0x0203}`。
  - 缓存：put A 记录（TTL 300）后 get 命中，TTL ≤ 300；把注入的时钟推进 301 秒后返回 `:miss`（`Cache.new(clock: fn -> ms end)`）。
  - NXDOMAIN 带 SOA（minimum 60）时缓存 60 秒。
  - TXT、MX、HTTPS、类型 65280 的记录 put 后 get，`DNS.Message.Record` 结构体完全相等。
  - 条目超过上限时总数不超过 `max_entries`。

- [ ] **Step 2：运行测试，确认失败**
  Run：`devenv shell -- bash -c 'cd apps/yellow_dog_worker && mix test test/yellow_dog/worker/dns/'`

- [ ] **Step 3：实现两个模块**。缓存表不要用 `named_table`。

- [ ] **Step 4：运行测试，确认通过**

- [ ] **Step 5：提交** `feat(worker): add DNS ACL and per-service cache`

### Task 3: Worker 上游查询客户端

**Files:**
- Create: `apps/yellow_dog_worker/lib/yellow_dog/worker/dns/upstream.ex`
- Create: `apps/yellow_dog_worker/test/support/fake_dns_server.ex`。在 Worker 的 `mix.exs` 中设置 `elixirc_paths(:test)`，把 `test/support` 加进去。
- Test: `apps/yellow_dog_worker/test/yellow_dog/worker/dns/upstream_test.exs`

**Interfaces:**
- `Upstream.query(server :: {:inet.ip_address(), :inet.port_number()}, name :: String.t(), type :: non_neg_integer(), opts) :: {:ok, DNS.Message.t()} | {:error, :timeout | :mismatch | :malformed | term()}`
  - `opts`：`rd: boolean()`，默认 true；`timeout: ms`，默认 2_000。
  - 事务 ID 用 `:crypto.strong_rand_bytes(2)` 生成。查询附带 EDNS0 OPT，UDP 大小 1232。
  - 先走 UDP（`Abyss.Client.send_recv/5`）。响应的 ID 或问题段（名字不区分大小写、类型、类）不匹配时返回 `{:error, :mismatch}`。
  - 响应 TC=1 时，改用 TCP（`:gen_tcp`，2 字节长度帧）向同一服务器重试一次。
- `FakeDnsServer.start_link(ip, port, handler :: (DNS.Message.t() -> binary() | :drop))`：测试用。UDP 和 TCP 都监听，可以使用 `:gen_udp`。

- [ ] **Step 1：写失败的测试**，覆盖以下情况：
  - 正常 A 应答。
  - 假服务器回复的 ID 不同，返回 `{:error, :mismatch}`。
  - 回复的问题名不同，返回 `{:error, :mismatch}`。
  - 不回复，在约 timeout 后返回 `{:error, :timeout}`。
  - UDP 回复 TC=1 后，客户端改用 TCP 并拿到完整的 40 条 A 记录。
  - `rd: false` 时，假服务器收到的查询 RD=0。
  - 假服务器（handler 收到查询后，从另一个端口的独立 socket 发送一个 ID 正确的响应）发出的响应被忽略，最终返回 `:timeout`。这一条用来确认 `Abyss.Client` 会校验响应的来源地址和端口。

- [ ] **Step 2：运行测试，确认失败**；**Step 3：实现**；**Step 4：运行测试，确认通过**
  Run：`devenv shell -- bash -c 'cd apps/yellow_dog_worker && mix test test/yellow_dog/worker/dns/upstream_test.exs'`

- [ ] **Step 5：提交** `feat(worker): add DNS upstream query client`

### Task 4: 查询处理顺序、转发区、ACL 接入监听

**Files:**
- Create: `apps/yellow_dog_worker/lib/yellow_dog/worker/dns/forwarder.ex`
- Modify: `apps/yellow_dog_worker/lib/yellow_dog/worker/dns/resolver.ex`
- Modify: `apps/yellow_dog_worker/lib/yellow_dog/worker/dns/udp_handler.ex`
- Modify: `apps/yellow_dog_worker/lib/yellow_dog/worker/dns_adapter.ex`
- Test: `apps/yellow_dog_worker/test/yellow_dog/worker/dns/forwarder_test.exs`
- Test: `apps/yellow_dog_worker/test/yellow_dog/worker/dns_adapter_test.exs`（扩展现有测试，并给现有用例的 config 补上 `allow_query: ["127.0.0.0/8"]`）

**Interfaces:**
- Consumes：Task 1 的 config 键；Task 2 的 `Acl`、`Cache`；Task 3 的 `Upstream.query/4`
- Produces：
  - `Resolver.build_context(service, resources, cache) :: {:ok, context}`，context 的结构为 `%{zones:, acl:, forward_zones: [{name, [server]}], recursion: boolean, cache:, recursor_opts: keyword}`。
  - `Resolver.reply(packet, context, transport :: :udp | :tcp, client_ip :: :inet.ip_address()) :: binary() | nil`
  - 现有的 `:snapshot` 调用改为返回 `{:ok, context}`。
- `Forwarder.resolve([server], name, type, opts) :: {:ok, DNS.Message.t()} | {:error, :servfail}`：按列表顺序依次尝试，失败或超时就换下一个，全部失败返回 `{:error, :servfail}`。只转发，不回退到递归。

**查询处理顺序**（写在 `Resolver.reply/4` 中）：
1. 解析失败：返回 nil（与现有行为一致）。
2. opcode 不是 QUERY：NOTIMP。
3. `Acl.allowed?` 为 false：REFUSED（rd 原样回填，ra=0）。
4. 命中权威区：执行现有的权威逻辑。
5. 最长后缀匹配到转发区：先查缓存，未命中则调用 `Forwarder.resolve`，成功后写入缓存。应答 ra=1、aa=0。上游返回的 rcode 原样回传；上游全部失败时返回 SERVFAIL（rcode 2）。
6. `recursion` 为 true 且 RD=1：先查缓存，未命中则调用 `Recursor.resolve`（Task 5）。本任务先用一个返回 SERVFAIL 的桩。
7. 其他情况：REFUSED。

**大小处理**：查询带 OPT 时，`limit = clamp(opt.udp_size, 512, 1232)`，响应中也附带 OPT；查询不带 OPT 时 `limit = 512`。UDP 响应超过 limit 时清空 answer 和 authority、设置 TC=1。TCP 不截断。

**并发**：UdpHandler 和 TCP session 用 `:snapshot` 取到 context 后，在自己的进程里调用 `Resolver.reply/4`。adapter 进程只负责保存 context，绝不在 adapter 里发起上游查询。

- [ ] **Step 1：写失败的测试**，覆盖以下情况：
  - forwarder 测试：第一个上游超时、第二个返回应答，结果为 `{:ok, _}`；两个都超时返回 `{:error, :servfail}`。
  - adapter 测试（真实 UDP/TCP 监听，使用回环地址和随机端口）：
    - `allow_query: []` 时查询返回 rcode 5。
    - 转发区 `"corp.test."` 指向 FakeDnsServer，`a.corp.test A` 返回假服务器给出的地址，并且 ra=1；连续查两次，假服务器只收到 1 次查询（命中缓存）。
    - 转发区的上游都不可达时返回 rcode 2。
    - 不在任何区里且 `recursion: false` 时返回 rcode 5。
    - 权威区查询仍返回 aa=1。
    - 转发区返回 40 条 A 记录：不带 EDNS 的 UDP 查询得到 TC=1，带 EDNS 1232 的查询得到完整应答（大小 ≤ 1232），TCP 得到完整应答。
    - 一个永不回复的转发区查询进行期间，另一个权威查询在 200ms 内得到应答（证明不会阻塞）。
  - `update/3` 只改 `allow_query` 时不需要重启监听，并且立即生效。

- [ ] **Step 2：运行测试，确认失败**；**Step 3：实现**；**Step 4：运行测试，确认通过**
  Run：`devenv shell -- bash -c 'cd apps/yellow_dog_worker && mix test'`
  Expected：全部 PASS，包括 `adapter_acceptance_test.exs`、`service_manager_test.exs`（如有需要，给它们的 fixtures 补上 allow_query）。

- [ ] **Step 5：提交** `feat(worker): serve forward zones with ACL and EDNS sizing`

### Task 5: 迭代递归

**Files:**
- Create: `apps/yellow_dog_worker/lib/yellow_dog/worker/dns/recursor.ex`
- Create: `apps/yellow_dog_worker/lib/yellow_dog/worker/dns/root_hints.ex`（13 个根服务器的 IPv4 和 IPv6 地址，来源 IANA `named.root`）
- Modify: `apps/yellow_dog_worker/lib/yellow_dog/worker/dns/resolver.ex`（把 Task 4 的递归桩换成真实实现）
- Test: `apps/yellow_dog_worker/test/yellow_dog/worker/dns/recursor_test.exs`

**Interfaces:**
- `Recursor.resolve(name, type, opts) :: {:ok, %{rcode: 0 | 3, answers: [Record.t()], authority: [Record.t()]}} | {:error, :servfail}`
- `opts`：
  - `root_hints: [{ip, port}]`，默认使用 `RootHints.servers()` 中的 IPv4 地址，端口 53。是否使用 IPv6 根，取决于运行时是否配置了 `ipv6: true`，默认 false。
  - `port: 53`：向 NS 查询时使用的端口，测试时可以覆盖。
  - `cache: Cache.t()`：可选，用于缓存 NS 和地址记录。
  - `max_steps: 64`：每次解析的上游查询总数上限。
  - `max_cname: 8`
  - `deadline_ms: 5_000`

**算法要求**：
- 对上游的查询一律 RD=0。
- 处理 referral：使用 authority 段的 NS 和 additional 段的 glue。只接受落在 referral 区内（bailiwick）的 glue；没有 glue 时，从根开始递归解析 NS 名称（计入同一个 `max_steps`）。
- 处理 CNAME：answer 段包含目标记录时直接使用，否则重新解析 CNAME 目标，次数受 `max_cname` 限制。返回的 answers 依次包含 CNAME 链和最终的记录。
- 丢弃 answer 中不属于当前查询名或 CNAME 链的记录。
- NXDOMAIN 和 NODATA 带上 SOA 返回。
- 超过 `max_steps`、`deadline_ms` 或 `max_cname` 时返回 `{:error, :servfail}`。

- [ ] **Step 1：写失败的测试**。用 `FakeDnsServer` 在 `127.0.0.10`（根）、`127.0.0.11`（`test.` 区）、`127.0.0.12`（`example.test.` 区）上搭一个假的三层层级，三个服务器使用同一个随机端口，`port:` 设为该端口。覆盖以下情况：
  - `www.example.test A` 经过根、`test.`、`example.test.` 三层，最终返回 A 记录。
  - `alias.example.test` 是指向 `www.example.test` 的 CNAME，answers 的顺序为 `[CNAME, A]`。
  - 不存在的名字返回 `rcode: 3`，authority 中带 SOA。
  - `test.` 区的 referral 附带了一条越界 glue `ns.evil. A 127.0.0.66`，这条 glue 不被使用（`127.0.0.66` 上的假服务器收到 0 次查询）。
  - `example.test.` 的 NS 是 `ns.other.test`（没有 glue），能先解析出它的地址，再继续解析。
  - `a.loop.test CNAME b.loop.test`、`b.loop.test CNAME a.loop.test` 返回 `{:error, :servfail}`，且在 1 秒内结束。
  - 两个区的 NS 互相 referral，在 `max_steps` 内返回 `{:error, :servfail}`。
  - TXT、MX、HTTPS、65280 类型的记录原样返回。
  - Recursor 测试里所有发往上游的查询，RD 都为 0。

  如果 `ex_dns` 无法完整往返 HTTPS 或 65280 类型的记录，**停下来报告**，不要修改 `ex_dns`。

- [ ] **Step 2：运行测试，确认失败**；**Step 3：实现**；**Step 4：运行测试，确认通过**
  Run：`devenv shell -- bash -c 'cd apps/yellow_dog_worker && mix test'`

- [ ] **Step 5：在 adapter 测试中增加一个端到端用例**：`recursion: true` 加假根，`dig` 风格的 UDP 查询 `www.example.test` 返回 A 记录，ra=1。

- [ ] **Step 6：提交** `feat(worker): add iterative recursive resolution`

### Task 6: Management 的 Worker socket 和推送

**Files:**
- Create: `apps/yellow_dog_management/lib/yellow_dog/management_ui/worker_socket.ex`
- Create: `apps/yellow_dog_management/lib/yellow_dog/management_ui/worker_channel.ex`
- Modify: `apps/yellow_dog_management/lib/yellow_dog/management_ui/endpoint.ex`
- Modify: `apps/yellow_dog_management/lib/yellow_dog/management_ui/router.ex`（删除 `forward "/api/worker"`）
- Delete: `apps/yellow_dog_management/lib/yellow_dog/management/worker_api.ex`
- Modify: `apps/yellow_dog_management/lib/yellow_dog/management/domain.ex`（在 `mutate/5` 成功分支中，参照 `Tasks.broadcast` 的写法广播）
- Modify: `apps/yellow_dog_management/lib/yellow_dog/management/worker_connections.ex`（`bootstrap/3` 去掉 `poll_interval_ms` 那一行；新增 `broadcast_target/1`）
- Modify: `apps/yellow_dog_management/config/config.exs`、`config/dev.exs`、`config/test.exs`（`websocket_paths` 加入 `"/api/worker/connect"`，并删除已失效的 `"/server/ws/websocket"`）
- Modify: `docs/phase1/management-integration-security.md`（Worker 凭据边界一节：路径相同，传输方式改为 WebSocket，令牌只放在 join payload 中）
- Test: `apps/yellow_dog_management/test/worker_channel_test.exs`（新建）、`worker_connections_test.exs`（修改），以及引用 `/api/worker` 的测试文件（`web_test.exs`、`export_scope_test.exs` 等，改为使用 channel 或删除对应断言）

**Interfaces:**
- 端点：`socket "/api/worker", YellowDog.ManagementUI.WorkerSocket, websocket: [path: "/connect", connect_info: [:peer_data], check_origin: false], longpoll: false`
- `WorkerSocket.connect(params, socket, connect_info)`：
  - 从 `params["worker_id"]` 读取 UUID，合法时存入 assigns，否则返回 `:error`。
  - 此处不读取令牌、不访问数据库，真正的认证在 join 时完成。（2026-11-12 裁定：原方案把令牌放在 HTTP 头 `x-yellow-dog-worker-token` 中，但 Caddy 访问日志会记录自定义请求头，令牌会落入日志，所以改为只放在 channel join payload 中。）
  - `id/1` 返回 `"worker_socket:<worker_id>"`。
- `WorkerChannel`：
  - topic 为 `"worker:" <> worker_id`，必须与 assigns 中的 worker_id 一致。
  - `join(topic, %{"token" => token, "report" => report}, socket)` 调用 `WorkerConnections.connect(token, report)`（令牌必须是 43 字节，只保存在 channel 进程的闭包/状态中，不写日志）：
    - 成功时订阅 PubSub `"worker_target:" <> id`，并在 join 后推送 `"target"`，payload 为 `%{"target" => target | nil}`。
    - 失败时返回 `{:error, %{"code" => code}}`。
  - `handle_in("report", report, socket)` 再次调用 `WorkerConnections.connect/2`：
    - 成功时回复 `{:ok, %{}}`；如果返回的 target 的 revision 比本连接上次推送的更新，再推送一次 `"target"`。
    - 认证失败时回复 `{:error, %{"code" => "unauthorized"}}`，然后 `{:stop, :normal, socket}`。
  - `handle_info({:worker_target, worker_id}, socket)` 读取 `Domain.get_target/1`，然后推送 `"target"`。
- `WorkerConnections.broadcast_target(worker_id)`：执行 `Phoenix.PubSub.broadcast(YellowDog.ManagementUI.PubSub, "worker_target:" <> id, {:worker_target, id})`。`Domain.mutate/5` 在 `"confirm_target"` 提交成功之后调用它。
- 报告 payload 与现有的 `@report_keys` 完全相同，`capabilities` 仍为 `["dns"]`。

- [ ] **Step 1：写失败的测试**（使用 `Phoenix.ChannelTest`）：
  - `worker_id` 缺失或不是 UUID 时 `connect` 返回 `:error`；join payload 缺少令牌时 join 被拒绝。
  - 令牌错误时 join 返回 `{:error, %{"code" => "unauthorized"}}`。
  - topic 中的 id 与 assigns 不一致时 join 被拒绝。
  - 合法 join 时 `assert_push "target", %{"target" => nil}`，并更新 `last_seen_at`。
  - 已经 join 的情况下执行 `confirm_target`，在 1 秒内 `assert_push "target", %{"target" => %{"revision" => r}}`。
  - **令牌轮换**：已经 join 后调用 `WorkerConnections.rotate/1`，下一次 `push "report"` 收到 unauthorized 回复，并且 channel 进程退出。
  - 匿名注册开启时，新 UUID 加合法格式的令牌可以 join 并创建 Worker；关闭时被拒绝。
  - `WorkerConnections.bootstrap/3` 的输出不包含 `poll_interval_ms`。
  - `web_test` 中断言 `POST /api/worker/connect` 返回 404。

- [ ] **Step 2：运行测试，确认失败**
  Run：`devenv shell -- scripts/e2e/phase1_postgres.sh mix cmd --app yellow_dog_management mix test test/worker_channel_test.exs test/worker_connections_test.exs`

- [ ] **Step 3：实现**；**Step 4：运行 Management 全部测试**
  Run：`devenv shell -- scripts/e2e/phase1_postgres.sh mix cmd --app yellow_dog_management mix test`
  Expected：PASS（与本任务无关的已知失败要记录下来，不要去修）。

- [ ] **Step 5：提交** `feat(management): push Worker targets over a WebSocket channel`

### Task 7: Worker 的 WebSocket 连接

**Files:**
- Modify: `apps/yellow_dog_worker/mix.exs`（加入 `{:phoenix_socket_client, "~> 0.9"}`；如果 `http_fetch` 没有其他用途就删除它）
- Modify: `mix.lock`、`default.nix`（更新 `fetchMixDeps` 的哈希）
- Rewrite: `apps/yellow_dog_worker/lib/yellow_dog/worker/connection.ex`
- Create: `apps/yellow_dog_worker/lib/yellow_dog/worker/connection/channel.ex`
- Delete: `apps/yellow_dog_worker/lib/yellow_dog/worker/connection_http.ex`
- Modify: `apps/yellow_dog_worker/lib/yellow_dog/worker/bootstrap.ex`（删除 `poll_interval_ms`）
- Test: `apps/yellow_dog_worker/test/connection_test.exs`（改写）、`bootstrap_test.exs`
- Modify: `scripts/e2e/worker_connection_smoke.py`（改为基于 WebSocket，并加入推送时延断言）

**Interfaces:**
- Consumes：Task 6 的协议，具体为：
  - URL：由 `management_url` 推导，规则是 `http→ws`、`https→wss`，再拼上 `/api/worker/connect`。
  - 参数：`params: %{"worker_id" => id}`。
  - 不带令牌请求头；令牌只放在 join payload：`%{"token" => token, "report" => report}`。
  - topic：`"worker:" <> id`；join 的 payload 是 `{"token", "report"}`。
  - 事件：入站 `"target"`，出站 `"report"`。
- `Connection.start_link(opts)` 和 `Connection.status(pid) :: %{connected: boolean, connection_error: String.t() | nil, apply_error: String.t() | nil}` 保持现有的公开形状。删除 `poll/1`。
- 内部行为：
  - 以 `reconnect?: false` 启动 `Phoenix.SocketClient`，并监控它。断线后按指数退避重连，从 1s 开始，上限 30s。
  - 每 15s 推送一次 `"report"` 作为心跳；应用完一个 target 后立即推送一次。
  - target 的校验和应用沿用现有的 `accept_target/3` 和 `fresh_target/3`。
  - 令牌不能出现在 GenServer 状态的 `format_status` 输出中，可参照现有的 redaction 写法。
- 如果 `phoenix_socket_client` 0.9 不支持 `ws://` 连接或 join payload，**停下来**，按 upstream-issue-routing 处理，不要改成在 query 或请求头里传令牌。

- [ ] **Step 1：改写测试**：
  - `connection_test.exs` 通过可注入的 socket 模块（opts `:socket_impl`，在测试中替换成假实现）验证以下行为：
    - join 后收到 target 时，调用 `submit_plan`，并推送一次 report，其中 `applied_revision` 等于该 target 的 revision。
    - 收到过期的 target 时，report 的 `apply_error` 为 `"stale_target"`。
    - socket 进程退出后，`status.connected` 变为 false，并按退避时间重连。
    - `inspect(:sys.get_state(pid))` 的输出不包含令牌。
  - `bootstrap_test.exs`：带 `poll_interval_ms` 的 bootstrap 被拒绝。

- [ ] **Step 2：运行测试，确认失败**；**Step 3：实现**；**Step 4：运行测试，确认通过**
  Run：`devenv shell -- mix cmd --app yellow_dog_config_spec --app yellow_dog_worker mix test`

- [ ] **Step 5：跨产品冒烟**：修改 `worker_connection_smoke.py`，原有的断言都保留，并新增一条：发布后 Worker 在 3 秒内报告应用成功（原来要等一个轮询周期）。
  Run：`devenv shell -- scripts/e2e/phase1_postgres.sh scripts/e2e/worker_connection_smoke.sh`
  Expected：脚本打印的所有 PASS 行都出现，退出码为 0。

- [ ] **Step 6：提交** `feat(worker): connect to Management over WebSocket`

### Task 8: Management UI 中的 DNS 服务参数

**Files:**
- Modify: `apps/yellow_dog_management/lib/yellow_dog/management/operation_schemas.ex`（扩展 `dns_config/0`）
- Modify: `apps/yellow_dog_management/lib/yellow_dog/management_ui/live/worker_live.ex`（服务表单约 L218、L349、L369、L628）
- Test: `apps/yellow_dog_management/test/node_workflow_live_test.exs`、`node_workflow_domain_test.exs`

**Interfaces:**
- 表单字段：
  - `service[recursion]`：复选框。
  - `service[allow_query]`：textarea，每行一个 CIDR。
  - `service[forward_zones]`：textarea，每行格式为 `<zone> <server> [<server> ...]`，其中 server 写作 `a.b.c.d`、`a.b.c.d:port` 或 `[v6]:port`。
- 新建服务时的默认值：`listen_address: "0.0.0.0"`、`port: 53`、`recursion: true`、`allow_query: ["127.0.0.0/8", "10.10.10.0/24", "10.88.0.0/16"]`。
- 解析错误按行显示在对应字段下，复用 `errors_for_field/2`。保存后经 `build_plan` 进入 WorkerPlan。
- 只能使用 `phoenix_duskmoon` 组件和 `@duskmoon-dev/core` 提供的类，不要写原始 Tailwind 类。动 UI 之前先加载 `phoenix-duskmoon-ui` 技能。

- [ ] **Step 1：写失败的测试**：
  - 提交 `forward_zones = "corp.test 10.0.0.2 10.0.0.3:5353"` 和 `allow_query = "10.10.10.0/24"` 后，`preview_target` 的 plan 中出现规范化后的值。
  - 填写非法 CIDR 时显示字段错误，并且不保存。
  - 详情页显示递归开关、转发区和允许列表。

- [ ] **Step 2：运行测试，确认失败**；**Step 3：实现**；**Step 4：运行测试，确认通过**
  Run：`devenv shell -- scripts/e2e/phase1_postgres.sh mix cmd --app yellow_dog_management mix test test/node_workflow_live_test.exs test/node_workflow_domain_test.exs`

- [ ] **Step 5：全量门禁**
  Run：`devenv shell -- bash -c 'mix compile --warnings-as-errors && mix format --check-formatted && mix credo --strict && scripts/e2e/architecture_smoke.sh && scripts/e2e/release_smoke.sh yellow_dog_worker && scripts/e2e/phase1_postgres.sh scripts/e2e/release_smoke.sh yellow_dog_management'`
  Expected：全部退出码为 0。

- [ ] **Step 6：提交** `feat(management): edit DNS recursion, forward zones and allow list`

### Task 9: 云上部署和验收（每个标注【需同意】的步骤都要先停下来问所有者）

**Files:** 不改仓库。需要的话，把操作记录写到 `docs/deployment/worker-podman-test.md`。

- [ ] **Step 1：构建并推送镜像**（已授权）：`./build_img.sh <version> yellow_dog_management --push` 和 `./build_img.sh <version> yellow_dog_worker --push`。版本号使用当前版本加一个 `-rc` 后缀。确认 vultr-01 到 04 能 `podman pull` 到这两个镜像（如果是私有镜像，需要 registry 凭据；凭据问题由所有者处理）。
- [ ] **Step 2：更新 vultr-01 上的 Management**（已授权的"更新镜像"）：用相同的参数重建 `yellow-dog-management` 容器，只换镜像。启动前先记下当前的 `podman inspect` 输出，用于回滚。
- [ ] **Step 3：修改 Caddy【需同意：先确认配置仓库位置和执行人】**：把 `http://10.10.10.10:4270` 的 `@worker` 规则改为 `method GET`、`path /api/worker/connect`，`remote_ip` 加上 `10.10.10.10`。然后重建 vultr-01 的 NixOS 配置。
- [ ] **Step 4：登记 Worker【需同意：二选一】**：所有者在 UI 中登记 4 个 Worker，然后把 bootstrap 交给实现方；或者临时开启匿名注册，Worker 启动后再关闭。
- [ ] **Step 5：启动 Worker【需同意：先把完整的 podman run 命令发给所有者看】**：在 4 台主机上分别运行
  `podman run -d --name yellow-dog-worker --network host --restart unless-stopped -v /var/lib/yellow-dog-worker:/data -v /etc/yellow-dog-worker/bootstrap.toml:/run/bootstrap.toml:ro -e YELLOW_DOG_WORKER_BOOTSTRAP=/run/bootstrap.toml ghcr.io/gsmlg-dev/yellow-dog-worker:v<version>`
  其中 `management_url = "http://10.10.10.10:4270"`，`data_dir = "/data"`。启动前在每台主机上执行 `ss -lntup | grep ':53 '`，确认 53 端口空闲。
- [ ] **Step 6：在 Management 中配置并发布**：每个 Worker 一个 DNS 服务，默认值来自 Task 8，再加一个测试用的转发区（具体区和上游由所有者指定，否则用 `.` 之外的某个测试区指向 `1.1.1.1`）。
- [ ] **Step 7：验收**（对应设计文档第 7 节，每一条都要记录命令和输出）：
  - UI 显示 4 个 Worker 在线。
  - 在每台主机上执行 `dig @10.10.10.x example.com A` 和 `AAAA`，都能得到应答；第二次查询时 TTL 递减。
  - 转发区的查询走指定上游。
  - 从 podman 网桥里的容器查询成功。
  - 不在 allow 列表中的来源返回 REFUSED（临时从 `allow_query` 中去掉 VPN 网段来验证，验证后恢复）。
  - `podman stop yellow-dog-management` 后 DNS 照常工作；重启 Worker 容器后 DNS 立即恢复；Management 恢复后 Worker 自动重连。
  - 无法验证的条目要标为"未验证"并说明原因。
