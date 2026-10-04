# Dify Redis 高可用（Sentinel）

3 节点 Redis（1 主 2 从）+ 3 个 Sentinel，替换 `dify-deployment.yaml` 里单副本、hostPath
本地的 `dify-redis` StatefulSet。

- 目标：主库故障秒级自动切换（RTO），队列丢失窗口**有明确上界**（RPO ≤ 1s）
- 范围：应用缓存、Celery broker/result、agent 的 `db 2`
- 版本：`redis:7.4-alpine`（现网是 `redis:6-alpine`）。7.x 提供 sharded pub/sub 与更完整的
  Sentinel 配置项；Dify 默认 RESP3 协议在 6/7 上都可用

English summary: 3-node Redis with 3 Sentinels in one StatefulSet, headless Service for
stable per-pod DNS, and a second ClusterIP Service that deliberately keeps the `dify-redis`
name so most Dify settings need no change at all. See the numbered steps below.

---

## 1. 为什么需要两个 Service

| Service | 用途 | 谁在用 |
|---|---|---|
| `dify-redis-ha-headless` | per-pod DNS（`dify-redis-ha-0.dify-redis-ha-headless`） | Sentinel 发现主库、副本 attach |
| `dify-redis`（ClusterIP，跨全部 3 节点） | 普通负载均衡 | Dify 的 pub/sub、`DIFY_AGENT_REDIS_URL` |

**关键约束**（读 1.17.1 源码确认，不是推测）：Dify 的 pub/sub 客户端
`api/extensions/ext_redis.py` 里 `_create_pubsub_client()` 只有「cluster」和「普通 URL」
两个分支，**没有 sentinel 分支**；而 `PUBSUB_REDIS_URL` 默认由 `REDIS_HOST`/`REDIS_PORT`
拼出来。另外 `DIFY_AGENT_REDIS_URL` 是个普通 `redis://` URL。

所以 Sentinel 只覆盖主数据面（`REDIS_USE_SENTINEL=true`）和 Celery broker
（`CELERY_USE_SENTINEL=true`），而 pub/sub 与 agent 走 `dify-redis` 这个跨节点 Service。
**Service 名字保持 `dify-redis` 正是为此**——现网已经叫这个名字，`REDIS_HOST`、
`PUBSUB_REDIS_URL`、`DIFY_AGENT_REDIS_URL` 一行都不用改。

## 2. 数据丢失上界（这才是 HA 的重点）

原配置是 `--save 20 1`，主库崩溃会丢最后几秒。这里换成：

| 配置 | 作用 |
|---|---|
| `appendonly yes` + `appendfsync everysec` | 队列丢失窗口 ≤ 1s，且有上界 |
| `min-replicas-to-write 1` | 没有健康从库就拒绝写入 |
| `min-replicas-max-lag 2` | 从库延迟 > 2s 时主库拒绝写入 |
| `maxmemory-policy noeviction` | **绝不静默淘汰队列任务**（任务不可重算，缓存可以） |
| `replica-priority 100` + `replica-read-only yes` | 从库只在 AOF fsync 后才确认写入 |

`min-replicas-*` 的意义：把「异步复制悄悄丢数据」换成「短暂不可写」。对 Dify 来说队列
不可用几秒可以接受，队列静默丢任务不能接受。

> 已知取舍：加了 `min-replicas-to-write` 后，如果两个从库都挂了，Dify 会开始报错而不是
> 继续写。这是有意的——但意味着**不能只部署 1 主 1 从**。

## 3. 部署与切换

```bash
cd dify/database-ha/redis
REDIS_PASSWORD='<与现网 REDIS_PASSWORD 相同>' ./apply.sh
kubectl -n dify rollout status statefulset/dify-redis-ha --timeout=300s
```

**不要**直接删旧的 `dify-redis` StatefulSet——新旧 Pod 的 label 不同（`app: dify-redis`
vs `app: dify-redis-ha`），可以共存，正是我们需要的：

1. 先让新旧并存（`./apply.sh` 已完成）。此时两个 Service 都还指向旧 Pod（`dify-redis`
   Service 已被新 manifest 接管，selector 是 `dify-redis-ha`，所以流量已切到新集群）
2. 改 ConfigMap `dify-shared-config`（见下表）
3. 滚动重启 api / worker / worker-beat / plugin-daemon
4. 确认队列正常后再删旧的：

```bash
kubectl -n dify delete statefulset dify-redis
```

### ConfigMap 改动

```yaml
# 应用侧（api / worker / worker-beat / plugin-daemon 共用）
REDIS_USE_SENTINEL: 'true'
REDIS_SENTINELS: dify-redis-ha-0.dify-redis-ha-headless:26379,dify-redis-ha-1.dify-redis-ha-headless:26379,dify-redis-ha-2.dify-redis-ha-headless:26379
REDIS_SENTINEL_SERVICE_NAME: dify-redis-master
REDIS_SENTINEL_PASSWORD: '<同 REDIS_PASSWORD>'
REDIS_SENTINEL_SOCKET_TIMEOUT: '0.1'
REDIS_USE_CLUSTERS: 'false'
# REDIS_HOST / REDIS_PORT / REDIS_DB 不变，仍指向 dify-redis:6379

# Celery broker —— 这是最容易漏的一组，上游 .env.example 里根本没列
CELERY_USE_SENTINEL: 'true'
CELERY_SENTINEL_MASTER_NAME: dify-redis-master
CELERY_SENTINEL_PASSWORD: '<同 REDIS_PASSWORD>'
CELERY_SENTINEL_SOCKET_TIMEOUT: '0.1'
CELERY_BROKER_URL: 'sentinel://dify-redis-ha-0.dify-redis-ha-headless:26379;sentinel://dify-redis-ha-1.dify-redis-ha-headless:26379;sentinel://dify-redis-ha-2.dify-redis-ha-headless:26379/1'
CELERY_BACKEND: database        # 见下方说明

# agent（1.17.1 新增，无 sentinel 支持，保持普通 URL）
DIFY_AGENT_REDIS_URL: redis://:<password>@dify-redis:6379/2
```

三点说明：

1. **`CELERY_BROKER_URL` 必须是 `sentinel://` 形式**。`ext_celery.py` 里
   `broker=dify_config.CELERY_BROKER_URL` 是原样传给 Celery 的，Sentinel 的
   `master_name` / `sentinel_kwargs` 只进 `broker_transport_options`，URL 本身得自己写对。
   多个 sentinel 用 `;` 分隔，末尾 `/1` 是 broker 的 DB 号。
2. **`CELERY_BACKEND: database`**。`CELERY_RESULT_BACKEND` 在 `CELERY_BACKEND=redis` 时
   直接等于 `CELERY_BROKER_URL`，也就是让结果后端也跟着走 Sentinel。功能上可用，但既然
   Postgres 已经做完 HA，把任务结果放数据库更稳、少一个依赖。代价是结果查询会打数据库。
3. **`CELERY_USE_SENTINEL` 等 4 个变量在 `docker/.env.example` 里不存在**（1.15.0 和
   1.17.1 都没有），照抄官方 .env 会漏掉 broker 侧，导致队列还挂在单机上。

## 4. 队列数据迁移

Redis 里是缓存 + 队列 + 会话，**没有需要搬运的业务数据**。所以：

1. 先让队列排空（`celery -A app inspect active` 确认为空），或在维护窗口直接接受少量
   在途任务丢失
2. 不要尝试 `DUMP`/`RESTORE` 旧单机数据：缓存复制过去是负收益（旧的过期数据），
   而队列数据在任务完成后本就无意义

真正的"迁移"就是改配置 + 重启。旧 hostPath 数据 `/root/dify/db/redis/data` 建议保留
几天作为回滚兜底，确认稳定后再删。

## 5. 故障切换演练

```bash
# 找到当前主库
kubectl -n dify exec dify-redis-ha-0 -c redis -- \
  redis-cli SENTINEL get-master-addr-by-name dify-redis-master

# 杀掉主库，观察 5s 内选出新主（down-after-milliseconds=5000）
kubectl -n dify delete pod <master-pod>

# 确认唯一主库
for i in 0 1 2; do
  echo -n "pod-$i: "
  kubectl -n dify exec dify-redis-ha-$i -c redis -- \
    redis-cli --no-auth-warning info replication | grep -E "role:|master_link_status"
done
```

演练要记录的：切换耗时、Dify 端有无报错、队列有无丢失。**建议每季度演练一次**，
写进 runbook 并更新实测 RTO——配置文件里的数字不是保证。

## 6. 回滚

1. ConfigMap 把 `REDIS_USE_SENTINEL` / `CELERY_USE_SENTINEL` 改回 `false`，
   `CELERY_BROKER_URL` 改回 `redis://:<password>@dify-redis-old:6379/1`
2. 恢复旧 StatefulSet（若已删，需先从 hostPath 重新 apply 原 manifest）
3. `kubectl -n dify apply -f dify/database/redis.yaml`

## 7. 已知限制

- **pub/sub 不走 Sentinel**（第 1 节），靠 `dify-redis` Service 跨节点负载均衡。
  Redis 的 pub/sub 会经主库广播到所有副本，所以功能正常；但 pub/sub 客户端
  拿到的是一个具体地址，该节点故障时要等 `redis-py` 重连。`PUBSUB_REDIS_CHANNEL_TYPE`
  建议保持默认 `pubsub`；若遇到订阅者竞态，上游建议改 `streams`（at-least-once）。
- **`DIFY_AGENT_REDIS_URL` 无 sentinel 支持**，同样走 Service。1.17.1 新增组件，
  这是上游现状，不是本方案的选择。
- **3 节点起步**。1 主 1 从在 `min-replicas-to-write` 下不可用（故障即拒写）。
- **Redis 不做备份**。它不是数据源，队列可重算，缓存可重建；真正需要备份的是
  Postgres（已有 WAL 归档）和 Weaviate（见 `../cnpg/README.md` 的取舍说明）。
