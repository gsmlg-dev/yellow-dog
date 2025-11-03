# Yellow Dog DNS - Deployment Guide

Complete guide for deploying Yellow Dog DNS in production environments.

## Table of Contents

- [Overview](#overview)
- [System Requirements](#system-requirements)
- [Pre-Deployment Checklist](#pre-deployment-checklist)
- [Deployment Methods](#deployment-methods)
  - [Systemd (Linux)](#systemd-deployment)
  - [Docker](#docker-deployment)
  - [Docker Compose](#docker-compose-deployment)
  - [Kubernetes](#kubernetes-deployment)
- [Configuration](#configuration)
- [Security Hardening](#security-hardening)
- [Monitoring and Operations](#monitoring-and-operations)
- [Backup and Recovery](#backup-and-recovery)
- [Troubleshooting](#troubleshooting)
- [High Availability](#high-availability)

---

## Overview

Yellow Dog DNS is a high-performance DNS and DHCP server built with Elixir/OTP. This guide covers production deployment scenarios including:

- **DNS Server**: Authoritative DNS with views and hot-reload
- **DHCPv4 Server**: IPv4 address management
- **DHCPv6 Server**: IPv6 address management
- **mDNS Responder**: Local network service discovery

---

## System Requirements

### Minimum Requirements

- **CPU**: 2 cores
- **RAM**: 1GB (2GB recommended)
- **Disk**: 10GB
- **OS**: Linux (Ubuntu 20.04+, Debian 11+, RHEL 8+)
- **Network**: Static IP address recommended

### Software Requirements

- **Erlang**: OTP 27 or 28
- **Elixir**: 1.18+
- **Docker**: 20.10+ (if using containers)
- **Systemd**: Latest version (for systemd deployment)

### Network Requirements

- **UDP Port 53**: DNS queries
- **TCP Port 53**: DNS zone transfers (optional)
- **UDP Port 67**: DHCPv4 server
- **UDP Port 547**: DHCPv6 server
- **UDP Port 5353**: mDNS (optional)
- **TCP Port 9090**: Prometheus metrics (optional)

---

## Pre-Deployment Checklist

Before deploying, ensure you have:

### Configuration
- [ ] Network topology documented
- [ ] IP address allocation plan
- [ ] DNS zone files prepared
- [ ] DHCP address pools defined
- [ ] Static reservations list
- [ ] Views configuration planned

### Infrastructure
- [ ] Static IP address assigned
- [ ] Firewall rules configured
- [ ] Backup system configured
- [ ] Monitoring system ready
- [ ] Log aggregation configured

### Security
- [ ] TLS certificates prepared (if applicable)
- [ ] Access control lists defined
- [ ] Security policies reviewed
- [ ] Audit logging enabled

### Documentation
- [ ] Network diagram created
- [ ] Runbook documented
- [ ] Escalation procedures defined
- [ ] Recovery procedures tested

---

## Deployment Methods

### Systemd Deployment

Best for: Traditional Linux servers, bare metal, VMs

#### 1. Build Release

```bash
# Clone repository
git clone https://github.com/gsmlg-dev/yellow-dog.git
cd yellow-dog

# Set production environment
export MIX_ENV=prod

# Install dependencies
mix deps.get --only prod

# Compile
mix compile

# Build release
mix release yellow_dog
```

#### 2. Install Release

```bash
# Create installation directory
sudo mkdir -p /opt/yellow-dog

# Extract release
sudo tar -xzf _build/prod/rel/yellow_dog/yellow_dog-*.tar.gz -C /opt/yellow-dog

# Create required directories
sudo mkdir -p /opt/yellow-dog/{config,zones,data,logs}
```

#### 3. Configure Service

```bash
# Copy example configurations
sudo cp apps/yellow_dog_dns/config/prod.toml.example /opt/yellow-dog/config/prod.toml
sudo cp apps/yellow_dog_dns/config/views.toml.example /opt/yellow-dog/config/views.toml

# Edit configurations
sudo vim /opt/yellow-dog/config/prod.toml
sudo vim /opt/yellow-dog/config/views.toml
```

#### 4. Create User and Set Permissions

```bash
# Create system user
sudo useradd -r -s /bin/false yellow-dog

# Set ownership
sudo chown -R yellow-dog:yellow-dog /opt/yellow-dog

# Set permissions
sudo chmod 750 /opt/yellow-dog
sudo chmod 640 /opt/yellow-dog/config/*.toml
```

#### 5. Install Systemd Service

```bash
# Copy service file
sudo cp apps/yellow_dog_dns/deployment/yellow-dog-dns.service /etc/systemd/system/

# Reload systemd
sudo systemctl daemon-reload

# Enable service
sudo systemctl enable yellow-dog-dns

# Start service
sudo systemctl start yellow-dog-dns

# Check status
sudo systemctl status yellow-dog-dns
```

#### 6. Verify Installation

```bash
# Check DNS
dig @localhost example.com

# Check service status
/opt/yellow-dog/bin/yellow_dog rpc "YellowDog.get_all_status()"

# View logs
sudo journalctl -u yellow-dog-dns -f
```

---

### Docker Deployment

Best for: Containerized environments, development, testing

#### 1. Build Image

```bash
# From project root
cd apps/yellow_dog_dns/deployment

# Build image
docker build -t yellow-dog-dns:latest -f Dockerfile ../../..
```

#### 2. Prepare Configuration

```bash
# Create config directory
mkdir -p ./config ./zones ./data ./logs

# Copy example configurations
cp ../config/prod.toml.example ./config/prod.toml
cp ../config/views.toml.example ./config/views.toml

# Edit configurations
vim ./config/prod.toml
vim ./config/views.toml
```

#### 3. Run Container

```bash
# Run with host network (recommended for DNS/DHCP)
docker run -d \
  --name yellow-dog-dns \
  --network host \
  --cap-add NET_BIND_SERVICE \
  --cap-drop ALL \
  -v $(pwd)/config:/opt/yellow-dog/config:ro \
  -v $(pwd)/zones:/opt/yellow-dog/zones:ro \
  -v $(pwd)/data:/opt/yellow-dog/data \
  -v $(pwd)/logs:/opt/yellow-dog/logs \
  --restart unless-stopped \
  yellow-dog-dns:latest
```

#### 4. Verify Container

```bash
# Check container status
docker ps -f name=yellow-dog-dns

# View logs
docker logs -f yellow-dog-dns

# Check DNS
dig @localhost example.com

# Execute commands in container
docker exec yellow-dog-dns bin/yellow_dog rpc "YellowDog.get_all_status()"
```

---

### Docker Compose Deployment

Best for: Multi-container setups, easier management

#### 1. Prepare Environment

```bash
# Navigate to deployment directory
cd apps/yellow_dog_dns/deployment

# Create config directory structure
mkdir -p config zones data logs

# Copy configurations
cp ../config/prod.toml.example config/prod.toml
cp ../config/views.toml.example config/views.toml
```

#### 2. Review docker-compose.yml

The provided `docker-compose.yml` includes:
- Host networking mode (recommended)
- Volume mounts for config, zones, data, logs
- Health checks
- Resource limits
- Proper capabilities

#### 3. Start Services

```bash
# Start in background
docker-compose up -d

# View logs
docker-compose logs -f

# Check status
docker-compose ps
```

#### 4. Management Commands

```bash
# Stop services
docker-compose stop

# Restart services
docker-compose restart

# Update and restart
docker-compose pull
docker-compose up -d

# Remove services
docker-compose down

# Remove with volumes
docker-compose down -v
```

---

### Kubernetes Deployment

Best for: Large-scale deployments, orchestration needs

#### 1. Create Namespace

```yaml
# namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: yellow-dog
```

#### 2. Create ConfigMaps

```yaml
# configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: yellow-dog-config
  namespace: yellow-dog
data:
  prod.toml: |
    # Include your prod.toml content here
  views.toml: |
    # Include your views.toml content here
```

#### 3. Create Deployment

```yaml
# deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: yellow-dog-dns
  namespace: yellow-dog
spec:
  replicas: 2
  selector:
    matchLabels:
      app: yellow-dog-dns
  template:
    metadata:
      labels:
        app: yellow-dog-dns
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      containers:
      - name: yellow-dog-dns
        image: yellow-dog-dns:latest
        imagePullPolicy: Always
        ports:
        - containerPort: 53
          protocol: UDP
          name: dns-udp
        - containerPort: 53
          protocol: TCP
          name: dns-tcp
        - containerPort: 67
          protocol: UDP
          name: dhcpv4
        - containerPort: 547
          protocol: UDP
          name: dhcpv6
        - containerPort: 9090
          protocol: TCP
          name: metrics
        securityContext:
          capabilities:
            add:
            - NET_BIND_SERVICE
            drop:
            - ALL
          readOnlyRootFilesystem: true
        volumeMounts:
        - name: config
          mountPath: /opt/yellow-dog/config
          readOnly: true
        - name: data
          mountPath: /opt/yellow-dog/data
        - name: logs
          mountPath: /opt/yellow-dog/logs
        resources:
          requests:
            cpu: 500m
            memory: 512Mi
          limits:
            cpu: 2
            memory: 2Gi
        livenessProbe:
          exec:
            command:
            - bin/yellow_dog
            - rpc
            - "YellowDog.Dns.status()"
          initialDelaySeconds: 10
          periodSeconds: 30
        readinessProbe:
          exec:
            command:
            - bin/yellow_dog
            - rpc
            - "YellowDog.Dns.status()"
          initialDelaySeconds: 5
          periodSeconds: 10
      volumes:
      - name: config
        configMap:
          name: yellow-dog-config
      - name: data
        persistentVolumeClaim:
          claimName: yellow-dog-data
      - name: logs
        emptyDir: {}
```

#### 4. Create Service

```yaml
# service.yaml
apiVersion: v1
kind: Service
metadata:
  name: yellow-dog-dns
  namespace: yellow-dog
spec:
  type: LoadBalancer
  selector:
    app: yellow-dog-dns
  ports:
  - port: 53
    targetPort: 53
    protocol: UDP
    name: dns-udp
  - port: 53
    targetPort: 53
    protocol: TCP
    name: dns-tcp
  - port: 9090
    targetPort: 9090
    protocol: TCP
    name: metrics
```

#### 5. Deploy

```bash
# Apply manifests
kubectl apply -f namespace.yaml
kubectl apply -f configmap.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml

# Check status
kubectl get pods -n yellow-dog
kubectl get svc -n yellow-dog

# View logs
kubectl logs -n yellow-dog -l app=yellow-dog-dns -f
```

---

## Configuration

### Configuration File Locations

- **Systemd**: `/opt/yellow-dog/config/`
- **Docker**: Mounted via volumes
- **Kubernetes**: ConfigMaps

### Main Configuration (prod.toml)

See `config/prod.toml.example` for complete configuration options.

Key sections:
- `[core]`: Service enablement
- `[dns]`: DNS server settings
- `[dhcpv4]`: DHCPv4 configuration
- `[dhcpv6]`: DHCPv6 configuration
- `[telemetry]`: Monitoring settings
- `[logging]`: Log configuration
- `[performance]`: Tuning parameters
- `[security]`: Security settings

### Views Configuration (views.toml)

See `config/views.toml.example` for examples.

Example view:
```toml
[[view]]
name = "internal"
match_clients = "localnets"
zones = ["corp.example.com", "internal.example.com"]
recursion_enabled = true
```

### Hot-Reload Configuration Changes

```bash
# Systemd
/opt/yellow-dog/bin/yellow_dog rpc "YellowDog.Dns.View.Operations.trigger_reload()"

# Docker
docker exec yellow-dog-dns bin/yellow_dog rpc "YellowDog.Dns.View.Operations.trigger_reload()"

# Kubernetes
kubectl exec -n yellow-dog <pod-name> -- bin/yellow_dog rpc "YellowDog.Dns.View.Operations.trigger_reload()"
```

Or use CLI tool:
```bash
mix dns.reload
```

---

## Security Hardening

### File Permissions

```bash
# Config files readable only by yellow-dog user
chmod 640 /opt/yellow-dog/config/*.toml
chown yellow-dog:yellow-dog /opt/yellow-dog/config/*.toml

# Binaries executable only
chmod 750 /opt/yellow-dog/bin/*
```

### Firewall Configuration

```bash
# UFW (Ubuntu/Debian)
sudo ufw allow 53/udp comment 'DNS'
sudo ufw allow 53/tcp comment 'DNS TCP'
sudo ufw allow 67/udp comment 'DHCPv4'
sudo ufw allow 547/udp comment 'DHCPv6'

# Restrict metrics to internal network
sudo ufw allow from 10.0.0.0/8 to any port 9090 proto tcp comment 'Metrics'

# Firewalld (RHEL/CentOS)
sudo firewall-cmd --permanent --add-service=dns
sudo firewall-cmd --permanent --add-service=dhcp
sudo firewall-cmd --permanent --add-service=dhcpv6
sudo firewall-cmd --reload
```

### SELinux Configuration (RHEL/CentOS)

```bash
# Allow binding to privileged ports
sudo setsebool -P nis_enabled 1

# Custom policy (if needed)
sudo ausearch -c 'yellow_dog' --raw | audit2allow -M yellow_dog
sudo semodule -i yellow_dog.pp
```

### AppArmor Configuration (Ubuntu/Debian)

```bash
# Create profile
sudo aa-genprof /opt/yellow-dog/bin/yellow_dog

# Load profile
sudo apparmor_parser -r /etc/apparmor.d/opt.yellow-dog.bin.yellow_dog
```

### Network Security

- Enable Response Rate Limiting (RRL) in config
- Configure ACLs for management interfaces
- Use TLS for monitoring endpoints
- Implement IP-based access controls

---

## Monitoring and Operations

### CLI Management Tools

```bash
# System status
mix dns.status

# Health check
mix dns.health

# Metrics
mix dns.metrics

# List views
mix dns.views

# View details
mix dns.view internal

# Test IP matching
mix dns.test 192.168.1.100

# Trigger reload
mix dns.reload
```

### Programmatic API

```elixir
# Get status
{:ok, status} = YellowDog.Dns.View.Operations.status()

# Health check
{:ok, health} = YellowDog.Dns.View.Operations.health_check()

# Get metrics
{:ok, metrics} = YellowDog.Dns.View.Operations.get_metrics()

# List views
{:ok, views} = YellowDog.Dns.View.Operations.list_views()

# Test client match
{:ok, result} = YellowDog.Dns.View.Operations.test_client_match({192, 168, 1, 100})
```

### Prometheus Metrics

Access metrics at `http://localhost:9090/metrics`

Key metrics:
- `yellow_dog_dns_queries_total`: Total DNS queries
- `yellow_dog_dns_responses_total`: Total responses
- `yellow_dog_dns_errors_total`: Total errors
- `yellow_dog_dhcp_leases_active`: Active DHCP leases
- `yellow_dog_view_reload_success_total`: Successful reloads
- `yellow_dog_view_reload_failed_total`: Failed reloads

### Log Monitoring

```bash
# Systemd
sudo journalctl -u yellow-dog-dns -f

# Docker
docker logs -f yellow-dog-dns

# Kubernetes
kubectl logs -n yellow-dog -l app=yellow-dog-dns -f

# Filter for errors
sudo journalctl -u yellow-dog-dns -p err -f
```

### Alerting

Configure alerts for:
- Service down
- High error rate
- View reload failures
- DHCP pool exhaustion
- High memory usage
- Disk space low

---

## Backup and Recovery

### What to Backup

1. **Configuration Files**
   - `/opt/yellow-dog/config/prod.toml`
   - `/opt/yellow-dog/config/views.toml`

2. **Zone Files**
   - `/opt/yellow-dog/zones/*.zone`

3. **Persistent Data**
   - `/opt/yellow-dog/data/` (DHCP leases, cache)

4. **Logs** (optional)
   - `/opt/yellow-dog/logs/`

### Backup Script

```bash
#!/bin/bash
# backup-yellow-dog.sh

BACKUP_DIR="/backup/yellow-dog"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="yellow-dog-${DATE}.tar.gz"

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Backup configuration and data
tar -czf "${BACKUP_DIR}/${BACKUP_FILE}" \
  /opt/yellow-dog/config \
  /opt/yellow-dog/zones \
  /opt/yellow-dog/data

# Keep only last 7 backups
find "$BACKUP_DIR" -name "yellow-dog-*.tar.gz" -mtime +7 -delete

echo "Backup complete: ${BACKUP_FILE}"
```

### Restore Procedure

```bash
# Stop service
sudo systemctl stop yellow-dog-dns

# Restore from backup
sudo tar -xzf /backup/yellow-dog/yellow-dog-YYYYMMDD_HHMMSS.tar.gz -C /

# Verify permissions
sudo chown -R yellow-dog:yellow-dog /opt/yellow-dog/config
sudo chown -R yellow-dog:yellow-dog /opt/yellow-dog/zones
sudo chown -R yellow-dog:yellow-dog /opt/yellow-dog/data

# Start service
sudo systemctl start yellow-dog-dns

# Verify
sudo systemctl status yellow-dog-dns
```

### Disaster Recovery

1. **Rebuild Server**
   - Install OS and dependencies
   - Install Yellow Dog DNS
   - Restore configuration from backup

2. **Failover** (if HA configured)
   - Secondary takes over automatically
   - Update DNS/DHCP records if needed
   - Restore primary when ready

3. **Data Loss**
   - DHCP leases can be regenerated
   - DNS cache rebuilt automatically
   - Zone files must be restored from backup

---

## Troubleshooting

### Service Won't Start

```bash
# Check service status
sudo systemctl status yellow-dog-dns

# Check logs
sudo journalctl -u yellow-dog-dns -n 100

# Common issues:
# - Port already in use
# - Permission denied (check capabilities)
# - Configuration errors
# - Missing dependencies
```

### DNS Not Resolving

```bash
# Test locally
dig @localhost example.com

# Check views configuration
mix dns.test <client-ip>

# Verify zone files loaded
mix dns.views

# Check upstream servers
dig @8.8.8.8 example.com
```

### DHCP Not Working

```bash
# Check server running
sudo systemctl status yellow-dog-dns

# Verify port binding
sudo netstat -ulnp | grep 67

# Check pool configuration
mix dns.metrics

# Test DHCP discovery
sudo nmap --script broadcast-dhcp-discover
```

### Configuration Reload Failed

```bash
# Check configuration syntax
/opt/yellow-dog/bin/yellow_dog rpc "YellowDog.Dns.View.ViewConfig.load_file(\"/opt/yellow-dog/config/views.toml\")"

# View reload status
mix dns.status

# Check logs for error details
sudo journalctl -u yellow-dog-dns | grep reload
```

### High Memory Usage

```bash
# Check memory stats
/opt/yellow-dog/bin/yellow_dog rpc ":erlang.memory()"

# Analyze processes
/opt/yellow-dog/bin/yellow_dog rpc ":recon.proc_count(:memory, 10)"

# Adjust cache size in config
# cache_max_entries = 5000  # Reduce if needed
```

### Performance Issues

```bash
# Check metrics
mix dns.metrics

# Monitor query rate
watch -n 1 'sudo journalctl -u yellow-dog-dns --since "1 minute ago" | grep query | wc -l'

# Increase worker pool size in config
# dns_workers = 8  # Increase based on CPU cores

# Enable rate limiting
# rate_limit_enabled = true
```

---

## High Availability

### Active-Passive Setup

**Primary Server:**
```toml
[ha]
enabled = true
mode = "active-passive"
peer_nodes = ["10.0.0.2:5353"]
heartbeat_interval_seconds = 5
failover_timeout_seconds = 15
```

**Secondary Server:**
```toml
[ha]
enabled = true
mode = "active-passive"
peer_nodes = ["10.0.0.1:5353"]
heartbeat_interval_seconds = 5
failover_timeout_seconds = 15
```

### Active-Active Setup

For DNS, multiple servers can run simultaneously with:
- Same zone files
- Synchronized via zone transfers or file sync
- Load balanced via DNS round-robin or external LB

For DHCP, use:
- Split address pools
- Failover protocol
- Lease synchronization

### Failover Testing

```bash
# Test primary failure
sudo systemctl stop yellow-dog-dns

# Verify secondary takes over
dig @secondary-ip example.com

# Check failover metrics
mix dns.metrics

# Restore primary
sudo systemctl start yellow-dog-dns
```

---

## Production Checklist

Before going live:

### Configuration
- [ ] All IP addresses updated for production
- [ ] DNS zones configured and tested
- [ ] DHCP pools properly sized
- [ ] Static reservations configured
- [ ] Views tested with client IPs
- [ ] Hot-reload enabled and tested

### Security
- [ ] Firewall rules applied
- [ ] Access controls configured
- [ ] TLS certificates installed
- [ ] Audit logging enabled
- [ ] Security scanning completed

### Monitoring
- [ ] Prometheus metrics enabled
- [ ] Alerts configured
- [ ] Log aggregation setup
- [ ] Health checks working
- [ ] Dashboard created

### Operations
- [ ] Backup system configured
- [ ] Restore procedure tested
- [ ] Runbook documented
- [ ] Escalation procedures defined
- [ ] Team trained

### Performance
- [ ] Load testing completed
- [ ] Resource limits set
- [ ] Rate limiting configured
- [ ] Cache tuned
- [ ] Worker pools sized

---

## Support and Resources

- **Documentation**: `docs/` directory
- **GitHub**: https://github.com/gsmlg-dev/yellow-dog
- **Issues**: https://github.com/gsmlg-dev/yellow-dog/issues

---

## License

See LICENSE file in project root.
