# Dify 向量库高可用

分两段。**Phase 1 已实现**（本目录），Phase 2 待决策。

- Phase 1：给 Weaviate 加 S3 备份 —— 不升版本、不动数据、不重 embedding
- Phase 2：多节点真 HA —— 需要升版本，有未决权衡，见第 7 节

English summary: Phase 1 (implemented here) adds nightly S3 backups to the existing
Weaviate 1.19.0 with no version bump and no re-embedding. Phase 2 (multi-node with real
data replication) requires upgrading Weaviate and is still an open decision — see §7.

---

## 1. 现状与敞口

`dify/database/weaviate.yaml` 当前是：

| 项 | 值 |
|---|---|
| 版本 | `semitechnologies/weaviate:1.19.0` |
| 副本 | 1 |
| 存储 | hostPath `/root/dify/db/weaviate/data` |
| 内存上限 | 1Gi |
| 备份 | **无** |

所以节点故障、磁盘故障、Pod 被误删 = 全部向量数据永久丢失，且**没有任何恢复途径**。
这比 Redis 严重：Redis 丢的是缓存和队列（可重算），这里丢的是知识库本身。

Phase 1 只解决这一条。**它不解决自动故障切换**——节点挂了还是要人工从备份恢复。

## 2. 文件

| 文件 | 作用 |
|---|---|
| `weaviate-statefulset-patch.yaml` | 给现有 StatefulSet 打补丁：启用 `backup-s3` 模块 + S3 凭据 |
| `backup-cronjob.yaml` | 每晚触发 `POST /v1/backups/s3` 并轮询结果 |
| `apply.sh` | 环境变量驱动，幂等 |

## 3. 已核实的 1.19.0 事实

全部对着仓库实际运行的 **v1.19.0 源码**核过，不是照抄当前文档：

| 事实 | 出处 |
|---|---|
| `backup-s3` 模块存在 | `modules/` 目录树 |
| 变量为 `BACKUP_S3_BUCKET` / `_PATH` / `_ENDPOINT` / `_USE_SSL` | `modules/backup-s3/module.go` |
| `POST /v1/backups/s3` 创建、`GET /v1/backups/s3/{id}` 查状态 | `openapi-specs/schema.json` |
| 请求体 `{"id":..., "include":["all"]}` | `entities/models/backup_create_request.go` |
| `id` 只允许小写/数字/下划线/连字符 | 同上，字段注释 |
| **没有 list / delete 接口** | openapi spec 只有 `POST /backups/{backend}` 与 `GET /backups/{backend}/{id}` |

最后一条决定了保留策略的做法，见第 5 节。

## 4. 部署

```bash
cd dify/database-ha/weaviate
S3_BUCKET=dify-backups \
S3_ACCESS_KEY=... S3_SECRET_KEY=... \
WEAVIATE_API_KEY=<当前 Weaviate 已接受的 key> \
./apply.sh
```

可选：`S3_ENDPOINT`（MinIO 等）、`S3_REGION`、`S3_PATH`、`S3_USE_SSL`、`SCHEDULE`、`NS`。

**顺序是刻意的**：先建 Secret，再打补丁。打补丁后的 Pod 引用了 Secret，Secret 不存在
就起不来。

### 关于 `WEAVIATE_API_KEY`

补丁顺手把 `AUTHENTICATION_APIKEY_ALLOWED_KEYS` 从 manifest 里的硬编码字面量
（`xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`，一个占位符）改成读同一个 Secret，
CronJob 也从这个 Secret 读。这样服务端和备份客户端**不可能再悄悄错开**导致每次备份 401。

- 传入你**当前正在用的** key → Dify 侧无需任何改动
- 传入新 key → 必须同步更新 `dify/api/api.yaml` 和 `dify/api/worker.yaml` 的
  `WEAVIATE_API_KEY`，否则知识库功能立即失效

## 5. 必须验证，否则等于没做

**配错了 Weaviate 照样能正常启动**——backup-s3 模块不会在启动时探测 S3 连通性
（v1.19.0 的 `module.go` 里没有 `HeadBucket` 检查）。所以配置错误的表现是
**备份静默失败**，不是启动失败。必须手动验证：

```bash
kubectl -n dify create job --from=cronjob/dify-weaviate-backup weaviate-backup-test
kubectl -n dify logs -f job/weaviate-backup-test
```

看到 `SUCCESS` 才算成功。`FAILED` 就是 bucket 或凭据不对。

### 保留策略交给 S3

1.19.0 没有 delete 接口，所以清理旧备份**不是** CronJob 该干的事。给 bucket
的 `weaviate/` 前缀配一条生命周期规则即可（与 CNPG 的 WAL 归档可以共用同一个
bucket，用前缀区分）：

```json
{
  "Rules": [{
    "ID": "dify-weaviate-backup-expiry",
    "Filter": { "Prefix": "weaviate/" },
    "Status": "Enabled",
    "Expiration": { "Days": 30 }
  }]
}
```

## 6. 恢复流程

⚠️ **恢复是全类覆盖式的，不是增量的。** `POST /v1/backups/s3/{id}/restore` 会用备份
里的 class 定义覆盖当前同名 class。所以：

1. 先确认要恢复到哪个时间点：`kubectl -n dify get sts dify-weaviate -o yaml`
   记下当前副本数
2. 停掉写入方（`kubectl -n dify scale sts dify-api dify-worker --replicas=0`）
3. 恢复：

```bash
KEY=<weaviate-api-key>
curl -sS -X POST \
  "http://dify-weaviate.dify.svc.cluster.local:8080/v1/backups/s3/dify-<timestamp>/restore" \
  -H "X-Weaviate-Api-Key: ${KEY}" -H 'Content-Type: application/json' \
  -d '{"include":["all"]}'
```

4. 轮询 `GET /v1/backups/s3/dify-<timestamp>/restore` 直到 `SUCCESS`
5. 起回 api / worker

**必须先在测试环境演练一次。** 没演练过的恢复流程，等真需要时大概率是坏的。

## 7. Phase 2 待决策

多节点要成为真 HA，必须解决「Dify 从不设 `replicationFactor`」这一点。查证结果：

| 事实 | 出处 |
|---|---|
| Weaviate 有全局开关 `REPLICATION_MINIMUM_FACTOR`，无需改 Dify 代码 | `usecases/config/environment.go` |
| 该变量 **v1.21.0 才引入**，1.19.0 / 1.20.0 都没有 | 扫 v1.19/v1.20/v1.21 源码树 |
| **只对新建 collection 生效**，现有 collection 保持 factor=1 | `usecases/schema/manager.go` 注释：*"the required minimum to only apply to newly created classes"* |

所以升版本不是可选项。两条路线：

| | 2A：升到 1.21 | 2B：升到 ≥1.32 |
|---|---|---|
| 现有知识库 | 仍是单副本，要复制只能**重跑 embedding** | 用 replica movement 在线提升复制因子，**不用重 embedding** |
| 风险 | 低 | 版本跳跃大，与 Dify 固定的 `weaviate-client==4.22.0` 组合未验证 |
| 前提 | 无 | 必须先在测试集群验证读写正常 |

**未验证的风险要说清楚**：Dify 固定 `weaviate-client==4.22.0`，用 gRPC 连接且显式
`skip_init_checks=True`（跳过版本检查）。1.19 → 1.21/1.32 的服务端跳跃与这个客户端的
组合**无法在本地验证**——本机没有集群，Docker daemon 也没起。任何 Phase 2 都必须先在
测试集群跑通读写再上生产。

另外 `REPLICATION_MINIMUM_FACTOR=2` 必须在集群**已经扩到 3 节点之后**才设：只有 1 个节点时
新建 collection 会因为放不下 2 个副本而直接失败。

## 8. 已知限制

- **Phase 1 不提供自动故障切换。** 只是「能恢复」，不是「自动恢复」。
- **hostPath 仍是 hostPath。** 本阶段只加备份，没动存储。节点漂移到别的机器时，
  hostPath 上的数据不会跟着走（Phase 2 会一并改成 PVC）。
- **备份粒度是整个实例**，不是单个知识库。恢复会覆盖所有 collection。
- **`include: ["all"]`** 会把 schema 里所有 class 都备进去，包含 Dify 自己创建的
  那些。数据量增长后备份时长和 S3 成本都要重新评估。
- **`skip_init_checks=True` 是上游行为**，意味着 Dify 侧不会替你发现客户端/服务端
  版本不兼容。升级 Weaviate 时这条要重点验证。
