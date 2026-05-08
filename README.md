# Mia Cloud Relay (`cloud/`)

跑在**公网云主机**上的消息中继。只做一件事：**把 phone 侧和 agent 侧的 WebSocket 连接配对，按账号（Bearer token）相互转发协议信封**。

关键特性：

- FastAPI + `uvicorn[standard]`，两个端点：`/ws/phone` 与 `/ws/agent`。
- **不解码业务 payload**；仅校验信封骨架与 `from` / `to` 合法性，防止伪造。
- 每个 token 下 phone/agent **各一个活连接**；重入顶替旧连接，关闭码 `1008`。
- 对端离线时：按账号维度缓冲（≤ 200 条 / TTL 5 分钟）；溢出回 `error: buffer_overflow`。
- WebSocket 级心跳：30 秒 ping / 90 秒宽限。
- 通过 **Caddy 反代** 统一落 TLS，域名由 `.env` 注入。

详细契约见 `openspec/changes/add-mia-mvp/specs/cloud-relay`、`specs/wire-protocol`、`specs/relay-deployment`。

---

## 三步上线（一台干净的 Linux 主机）

前提：

- 装好 **Docker Engine + Compose v2**（`docker compose version` 能跑）。
- 有一个域名，**A/AAAA 记录指向本机**，`80`/`443` 公网可达（Caddy 需要 ACME 挑战）。
- 选一把强 token（后面手机与 Agent 会用同一把）：`openssl rand -base64 32`。

```bash
# 1) 拉仓库
git clone <this-repo> mia && cd mia/cloud

# 2) 写 .env
cp .env.example .env
# 用编辑器填：
#   MIA_AUTH_TOKENS=<上一步生成的 token>
#   MIA_DOMAIN=mia.example.com

# 3) 起栈
docker compose up -d
```

验证：

```bash
curl -fsS https://<MIA_DOMAIN>/health
# 预期输出：{"ok":true}
```

第一次 `up` 后，Caddy 会在后台向 Let's Encrypt 申请证书，通常 30–60 秒内完成；首次 curl 若 503，等一会儿再试。

---

## 更新流程

```bash
cd mia && git pull
cd cloud && docker compose up -d --build
```

- `relay` 会用新镜像重建并重启（有 5–10 秒短暂不可用，在线缓冲按 spec 会清空，这是可接受的）。
- `caddy` 保持运行，证书卷 `caddy_data` 被复用，**不会触发新的 ACME 挑战**。

## token 轮换

1. 重新生成：`openssl rand -base64 32`。
2. 编辑 `cloud/.env` 的 `MIA_AUTH_TOKENS`（可以先把新旧两把都塞进去，逗号分隔，过渡期双活）。
3. `docker compose up -d`（只会重启 `relay`）。
4. 把新 token 同步到 PC Agent 的 `server/.env` 与手机端设置页，完成切换后再从 `MIA_AUTH_TOKENS` 里删掉旧 token 并再次 `up -d`。

---

## 运维查看

```bash
# 实时日志
docker compose logs -f relay
docker compose logs -f caddy

# 仅看最近 200 行
docker compose logs --tail=200 relay

# 栈状态
docker compose ps
```

## 停 / 清

```bash
docker compose down               # 停服务，保留证书卷
docker compose down -v            # 停服务并删证书卷（谨慎，会触发下次重新申请证书）
```

---

## 常见问题

**Q: `GET /health` 一直 503。**
A: 检查 `cloud/.env` 是否填了 `MIA_AUTH_TOKENS`；`docker compose logs relay` 如果看到 `MIA_AUTH_TOKENS is required`，relay 会自杀退出。

**Q: ACME 失败 / HTTPS 一直不可用。**
A: 确认 `MIA_DOMAIN` 的 DNS A 记录真的指向本机的公网 IP，且防火墙放行 `80/443`。`docker compose logs caddy` 能看到 ACME 的详细错误。

**Q: 8000 端口也能直连？**
A: 不应该。`docker-compose.yml` 里 `relay` 只 `expose` 不 `publish`，只在 `mia-net` 内部可见。如果你在公网上能 curl 到 `:8000`，那是防火墙配置或宿主有别的反代在转。
