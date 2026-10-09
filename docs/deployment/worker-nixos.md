# 使用 flake 部署 Yellow Dog Worker（NixOS / Linux x86_64）

Worker 执行网络服务；Management 保存配置、管理 Worker 凭据并接收实际运行状态。
当前可执行的服务只有 authoritative DNS。此部署使用原生 Nix 包和 systemd，
不需要 Worker 容器、PostgreSQL 或本机 Elixir 安装。

## 引入 flake 和模块

将 Yellow Dog 加入目标仓库的 flake inputs，并导入 `nixosModules.worker`。
`v1.2.7` 包含本模块和匿名初始化功能；保留 flake.lock 中固定的提交。

```nix
# flake.nix
inputs.yellow-dog.url = "github:gsmlg-dev/yellow-dog/v1.2.7";

# 目标主机的 nixosSystem modules 中
modules = [
  inputs.yellow-dog.nixosModules.worker
  ./hosts/worker.nix
];
```

```nix
# hosts/worker.nix
{ ... }: {
  services.yellow-dog-worker = {
    enable = true;
    bootstrapFile = "/run/secrets/yellow-dog-worker-bootstrap";
  };

  # 按 Management 中实际配置的监听端口和主机访问策略开放。
  networking.firewall.allowedUDPPorts = [ 53 ];
  networking.firewall.allowedTCPPorts = [ 53 ];
}
```

`package` 默认选取此 flake 的 `yellow_dog_worker`，也可以显式替换。
服务以专用 `yellow-dog-worker` 用户运行，只有绑定低端口所需的
`CAP_NET_BIND_SERVICE`，状态目录为 `/var/lib/yellow-dog-worker`（0700）。
模块使用 systemd credentials 从运行时文件读取 bootstrap，启动时生成
Erlang release 所需的随机 cookie，并关闭 Erlang distribution。
无需额外维护 Erlang cookie；此服务配置不启用远程 Erlang RPC。

## 管理端和连接配置

Management 必须运行包含 Worker 注册、token 和 `/api/worker/connect` 的代码
以及匿名初始化开关的代码，并应用对应数据库迁移。
现有 `v1.2.5` Management 容器不具备这一能力；不能只部署新版 Worker。
更新管理端时使用已确认包含这些代码的容器 digest 或构建产物。

### VPN 内匿名初始化（只配置地址）

在 Management → Workers（`/management/servers`）开启 **Allow anonymous Worker initialization**。
默认关闭；开启时允许新的 Worker 自动注册。当前通过 VPN 直接连接 Management，
不要求 mTLS。管理端需监听实际 VPN 地址（`YELLOW_DOG_MANAGEMENT_BIND_ADDRESS`），
并允许 VPN 客户端访问配置的端口。

Worker 的完整最小 bootstrap：

```toml
management_url = "http://VPN_MANAGEMENT_ADDRESS:4270"
```

也可以填写 HTTPS 地址。将文件保存到运行时路径后，按上面的 `bootstrapFile`
启用 NixOS 服务。无需手工输入名称、ID、token 或 `data_dir`：模块提供
`STATE_DIRECTORY=/var/lib/yellow-dog-worker`，Worker 在此持久保存私有
`connection.toml`（0600）及业务快照。直接运行包时，默认状态目录为
`$XDG_STATE_HOME/yellow-dog-worker` 或 `~/.local/state/yellow-dog-worker`，
也可显式指定绝对 `data_dir`。

首次初始化在本地生成固定 UUID 和随机凭据，再注册到 Management；后续自动认证。
网络超时及重启复用同一身份，不重复创建 Worker。注册后可在管理界面修改名称、
配置服务并发布完整目标。关闭开关只阻止新 Worker 注册，已有 Worker 继续连接。
身份文件绑定管理端地址，改连另一管理端需使用独立状态目录；不要复制此文件
来初始化另一台机器。

### 手动创建并配置 token

在 Management → Workers（`/management/servers`）仅输入名称创建 Worker，
保存一次性展示的完整连接配置。保留生成的 ID 和 token，并把 `data_dir`
改为模块的持久化绝对路径：

```toml
worker_id = "由 Management 生成的 ID"
data_dir = "/var/lib/yellow-dog-worker"
management_url = "http://VPN_MANAGEMENT_ADDRESS:4270"
token = "由 Management 生成的 token"
poll_interval_ms = 10000
```

bootstrap 由 systemd 复制到临时 credentials 目录。**显式 `data_dir`、本地模式的
`source` 以及 TLS 文件路径均应使用绝对路径**，不能保留生成配置中的相对
`data_dir = "data"`。状态目录属于本地 Linux 文件系统；不要使用 NFS。

`bootstrapFile` 是运行时绝对路径字符串，不能使用 Nix 路径字面量、
`builtins.readFile` 或 `pkgs.writeText` 把真实 token 写入 Nix store。
可使用 root 所有、0600/0400 的文件，或 SOPS 的运行时解密文件。
完整 bootstrap 被 systemd 安全复制后，服务用户无需直接读取原始秘密文件。

### SOPS（Gao-OS/nix-config）

将完整 bootstrap 作为 SOPS 的一个加密字符串项保存：

```nix
{ config, lib, ... }: {
  sops.secrets."yellow_dog_worker/bootstrap" = {
    sopsFile = ../../secrets/network.yaml; # 按目标主机的相对位置调整。
    owner = "root";
    mode = "0400";
    restartUnits = [ "yellow-dog-worker.service" ];
  };

  services.yellow-dog-worker = {
    enable = true;
    bootstrapFile = config.sops.secrets."yellow_dog_worker/bootstrap".path;
  };

  # useSystemdActivation=true 时，确保 credentials 在 Worker 启动前就绪。
  systemd.services.yellow-dog-worker = lib.mkIf config.sops.useSystemdActivation {
    after = [ "sops-install-secrets.service" ];
    requires = [ "sops-install-secrets.service" ];
  };
}
```

已有 `GaoOS.apps.yellow-dog` 管理端模块继续管理 Management；这个 Worker
模块是独立服务，在需要执行 DNS 的主机上单独启用。

### 可选私有 CA 和 mTLS

VPN 内直接访问 Management 时不需要客户端证书。以下适用于要求 mTLS 的 HTTPS
入口；如果入口要求客户端证书，匿名初始化开关不会绕过 TLS 握手。
签发/保存凭据后，将 TLS 文件作为额外 systemd credentials 传入：

```nix
systemd.services.yellow-dog-worker.serviceConfig.LoadCredential = [
  "ca.pem:/run/secrets/yellow-dog-ca"
  "client.pem:/run/secrets/yellow-dog-client-cert"
  "client.key:/run/secrets/yellow-dog-client-key"
];
```

在加密 bootstrap 中设置这些运行时绝对路径：

```toml
tls_ca_file = "/run/credentials/yellow-dog-worker.service/ca.pem"
tls_cert_file = "/run/credentials/yellow-dog-worker.service/client.pem"
tls_key_file = "/run/credentials/yellow-dog-worker.service/client.key"
```

`tls_ca_file` 应包含用于验证 Management **服务器证书**的 CA；客户端证书需由
Caddy 信任的客户端 CA 签发。服务器使用公开可信证书时可省略 `tls_ca_file`。
私钥和 bootstrap 都只在运行时通过 credentials 提供。
通过 SOPS 管理 TLS 凭据时，也为其设置 `restartUnits`。

## 构建、部署和验收

```sh
nix flake lock --update-input yellow-dog
nix build .#nixosConfigurations.HOST.config.system.build.toplevel
sudo nixos-rebuild switch --flake .#HOST
sudo systemctl status yellow-dog-worker.service
sudo journalctl -u yellow-dog-worker.service -n 100 --no-pager
```

首次没有已确认目标时，Worker 保持运行并等待 Management。
在 Management 中配置 DNS 服务和 zone，然后**确认/发布完整目标**；只保存草稿
不会启动服务。检查管理页面的连接状态、实际 DNS 状态和最近联系时间，并从允许的
网络位置发出真实 UDP/TCP DNS 查询：

```sh
dig @WORKER_IP example.com SOA
dig +tcp @WORKER_IP example.com SOA
```

重启服务后再查询；停止 DNS 并发布后确认监听关闭，重启仍应保持停止。
Management 暂时不可达时，Worker 保留上次已提交服务并从本地快照恢复。
保留 `/var/lib/yellow-dog-worker`；NixOS generation 回滚不会回滚其中的业务状态。

在 Management 重置 token 后更新加密 bootstrap、部署秘密并重启服务。
自动初始化的 Worker 也遵循撤销规则：旧凭据不会重新注册。可改用重置后生成的
手动连接配置，保留同一 Worker ID 和原 `data_dir`，更新 token 后重启。
不要把真实 token、私钥或完整连接配置写到 GitHub issue、日志或版本仓库。

本项目的范围内验证：

```sh
nix build .#yellow_dog_worker --no-link
nix build .#checks.x86_64-linux.worker --no-link --print-build-logs
```

NixOS VM 检查会验证真实 systemd 启动、运行时 credentials、非 root DNS 低端口、
UDP/TCP、持久化重启，以及仅地址模式的稳定凭据和连接轮询。
目标 Gao-OS 主机的实际部署需按上述步骤单独完成。
