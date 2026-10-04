# Dify 数据库高可用（Postgres HA）

用 **CloudNativePG** 托管的 3 副本 Postgres 集群，替换 `dify-deployment.yaml` 里单副本、
hostPath 本地盘的 `dify-postgres` StatefulSet。

- 目标：RPO ≈ 0（同步流复制）、RTO < 60s（自动选主）、备份可恢复
- 范围：**仅 Postgres 应用库**（`dify` + `dify_plugin`）。`dify-redis` / `dify-weaviate`
  仍是单副本，属于后续独立议题
- 版本对齐：PG 大版本保持 **15**（与现网 `postgres:15-alpine` 一致）。**不要**把大版本升级
  混进这次 HA 迁移，升级单独做

English summary: a 3-instance CloudNativePG cluster (`instances: 3`, synchronous standby,
PgBouncer pooler, barman object-store backups) replacing the single-replica
`dify-postgres` StatefulSet. Apply order, cutover, rollback and drill steps below.

---

## 1. 前置条件

| 项 | 要求 | 怎么确认 |
|---|---|---|
| 集群节点 | ≥ 3 个可调度节点 | `kubectl get nodes` |
| Operator | CloudNativePG ≥ 1.30 | `kubectl get crd clusters.postgresql.cnpg.io` |
| StorageClass | 支持 RWX 之外的常规 RWO（每实例独立 PVC） | `kubectl get storageclass` |
| 备份存储 | S3 兼容对象存储（无则改用 volumeSnapshot） | — |
| 停机窗口 | 建议 10–30 分钟（见第 4 步） | — |

安装 Operator（集群级，只需一次）：

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm install cnpg cnpg/cloudnative-pg --namespace cnpg-system --create-namespace
kubectl wait --for=condition=Ready pod -l cnpg.io/instanceRole=operator -n cnpg-system --timeout=180s
```

## 2. 部署（一脚本，参数走环境变量）

集群、连接池、备份、**三个 Secret** 全部由 `apply.sh` 生成与下发，凭据不进 git：

```bash
cd dify/database-ha/cnpg

PG_SUPERUSER_PASSWORD='<superuser 密码>' \
PG_APP_PASSWORD='<dify 应用账号密码>' \
S3_BUCKET='dify-pg-backup' \
S3_ACCESS_KEY='<accessKeyId>' \
S3_SECRET_KEY='<secretAccessKey>' \
S3_ENDPOINT='https://oss-cn-hangzhou.aliyuncs.com' \
S3_REGION='' \
STORAGE_CLASS='local-path' \
./apply.sh

kubectl -n dify get cluster dify-postgres -w   # 等到 3/3 Running + 恰好 1 个 primary
```

必填：`PG_SUPERUSER_PASSWORD` `PG_APP_PASSWORD` `S3_BUCKET` `S3_ACCESS_KEY` `S3_SECRET_KEY`
选填：`S3_ENDPOINT`（AWS S3 留空，非 AWS 必填）`S3_REGION`（AWS 填，其他留空）
`STORAGE_CLASS`（留空则用集群默认 StorageClass）`NS`（默认 `dify`）

脚本会校验 `CHANGE_ME_*` 全部被替换后才 apply，可重复执行（幂等更新）。

> 想完全声明式管理（如用 external-secrets）就跳过脚本：先自行创建
> `dify-postgres-superuser` / `dify-postgres-app` / `dify-postgres-backup` 三个 Secret，
> 再 `kubectl apply -k dify/database-ha/cnpg/`。此时需要自己替换 `cluster.yaml` 里的
> `CHANGE_ME_BUCKET` / `CHANGE_ME_ENDPOINT` / `CHANGE_ME_STORAGE_CLASS`。

## 3. 应用侧连接参数

新集群自动提供三个 Service：`dify-postgres-rw`（读写/主）、`-ro`（只读副本）、
`-r`（全部）。推荐经 PgBouncer 接入：Service `dify-postgres-pgbouncer`，端口 `6432`。

改 `dify-deployment.yaml` 的 ConfigMap `dify-shared-config`（api / worker /
worker-beat / plugin-daemon 通过 `envFrom` 引用它，改一处即生效）：

```yaml
DB_HOST: dify-postgres-pgbouncer   # 直连主库则用 dify-postgres-rw
DB_PORT: '6432'                    # 直连则 5432
DB_USERNAME: dify                  # 专用应用账号，不再用 postgres
DB_PASSWORD: "<与 apply.sh 的 PG_APP_PASSWORD 一致>"
SQLALCHEMY_POOL_PRE_PING: 'true'  # 关键：切换后自动重连失效连接
DB_DATABASE: dify                  # 不变
DB_PLUGIN_DATABASE: dify_plugin   # 不变
```

`SQLALCHEMY_POOL_PRE_PING` 原来是 `false`。不开的话主库切换后连接池里全是死连接，
应用要等到 `SQLALCHEMY_POOL_RECYCLE`（3600s）才恢复，HA 就白做了。

## 4. 迁移与切换（含停机窗口）

```bash
# 1) 冻结写入：先停产生写入的应用（顺序很重要，先停写后 dump）
kubectl -n dify scale statefulset dify-api --replicas=0
kubectl -n dify scale statefulset dify-worker --replicas=0
kubectl -n dify scale statefulset dify-worker-beat --replicas=0
kubectl -n dify scale statefulset dify-plugin-daemon --replicas=0

# 2) 导数据 + 校验（dify 和 dify_plugin 两个库都要导）
./dify/database-ha/cnpg/migrate.sh ./pgdump

# 3) 改 dify-shared-config（见第 3 节），然后拉起应用
kubectl -n dify scale statefulset dify-api --replicas=1
kubectl -n dify scale statefulset dify-worker --replicas=1
kubectl -n dify scale statefulset dify-worker-beat --replicas=1
kubectl -n dify scale statefulset dify-plugin-daemon --replicas=1

# 4) 冒烟：登录、建应用、跑一次知识库导入
```

停机时长主要取决于数据量：`pg_dump` + `pg_restore` 期间应用不可用。

## 5. 验证与演练

```bash
# 主从角色
kubectl -n dify get pods -l cnpg.io/cluster=dify-postgres \
  -L cnpg.io/instanceRole,cnpg.io/role

# 切换演练：删掉当前主库 Pod，观察新主在 60s 内产生
kubectl -n dify delete pod <primary-pod>
kubectl -n dify get cluster dify-postgres -w

# 备份是否真的在跑（关键：备份没验证过等于没有）
kubectl -n dify get backup
kubectl -n dify exec <primary-pod> -- barman-cloud-backup list-backup
```

恢复演练（建议每月一次，在测试环境）：从 `barmanObjectStore` 恢复到新建集群，
记录真实 RTO。

## 6. 回滚

1. `dify-shared-config` 改回 `DB_HOST: dify-postgres` / `DB_PORT: '5432'` /
   `DB_USERNAME: postgres` / `DB_PASSWORD`（旧值），应用滚动重启
2. 确认无误后再 `kubectl delete cluster dify-postgres -n dify`（会连带删 PVC）

**旧数据不要删**：原 StatefulSet 的 hostPath 数据在 `/root/dify/db/postgres/data`，
迁移完成前它就是你的兜底副本。

## 7. 已知取舍

- **密码仍在 ConfigMap 里**（沿用本仓库现有约定）。生产建议把 `DB_PASSWORD` 挪到 Secret，
  需要给 api/worker 容器加 `envFrom.secretRef`，属于后续改动。
- **不做 PG 大版本升级**：需要升级时，先在 HA 集群稳定运行后单独做，并先演练
  `pg_upgrade` / dump-restore 路径。
- **Redis / Weaviate 仍是单点**：本方案只解决应用库。会话、缓存和知识库检索在节点故障时
  仍会受影响，要彻底 HA 需要另做（Redis 哨兵 / Weaviate 多副本 + 快照）。
- **`statement_timeout: 0`**（不限制）是为兼容 Dify 批量导入；如需更严格治理可调低。
