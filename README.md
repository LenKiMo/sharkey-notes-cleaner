<div align="center">

# sharkey-notes-cleaner

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-1.0.4-blue.svg)](CHANGELOG.md)
[![Platform](https://img.shields.io/badge/platform-Linux%20%2B%20Docker-informational.svg)](#-前置要求)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-14%2B-336791.svg?logo=postgresql&logoColor=white)](#-工作原理)
[![Node](https://img.shields.io/badge/Node-20%2B-339933.svg?logo=nodedotjs&logoColor=white)](#-工作原理)
[![No image rebuild](https://img.shields.io/badge/不改镜像-不改源码-success.svg)](#-为什么不是打补丁--重建镜像)
[![AIGC](https://img.shields.io/badge/%F0%9F%A4%96-AIGC%20assisted-orange.svg)](#-许可与声明)

**给自托管 Misskey / Sharkey 实例的「旧远程帖清理」外部清理器**

不改镜像 · 不改源码 · 不动数据库结构 · 随时可停可退役

</div>

---

## 📑 目录

- [这是什么](#-这是什么)
- [为什么不是打补丁 / 重建镜像](#-为什么不是打补丁--重建镜像)
- [工作原理](#-工作原理)
- [前置要求](#-前置要求)
- [快速开始](#-快速开始)
- [配置参数](#-配置参数)
- [建议的上线节奏](#-建议的上线节奏)
- [观测指标](#-观测指标)
- [空间回收](#-空间回收)
- [长期自动化（systemd）](#-长期自动化systemd)
- [应急停止 / 卸载 / 退役](#-应急停止--卸载--退役)
- [性能：先做一次索引体检](#-性能先做一次索引体检)
- [故障排查](#-故障排查)
- [限制与风险](#-限制与风险)
- [实测数据](#-实测数据)
- [文件清单](#-文件清单)
- [许可与声明](#-许可与声明)

---

## ✨ 这是什么

Misskey 从 **2025.8.0** 起内置了「定期清理服务器上的旧远程帖」功能（[misskey-dev/misskey#16292](https://github.com/misskey-dev/misskey/pull/16292)，后续由 #16368 / #16412 修正），用来回收数据库空间。

但基于早期 Misskey 的 fork（例如 **Sharkey**）以及**第三方预编译镜像**（云上大量实例用的就是这种，服务器上根本没有源码）长期没有同步这个功能——镜像一停更，实例就只能眼看着 `note` 表越涨越大。

本项目不碰你的镜像和源码，而是**用同一个镜像起一次性容器**，直接对同一个数据库做「按上游语义」的批量清理。适合：

- 实例跑在第三方预编译镜像 / 无源码环境下；
- 你想**保留将来换镜像、跟随上游**的自由（清理器与镜像零耦合，上游自带该功能后停掉即可）；
- 你只想回收空间，不想维护一份打过补丁的应用分支。

## 🤔 为什么不是打补丁 / 重建镜像

| 方案 | 结论 |
|---|---|
| 外部清理器（**本项目**） | ✅ 对镜像/源码/schema 零改动；上游发新镜像照常换；上游自带该功能 → 停 timer 退役，零残留 |
| 薄派生镜像（`FROM` 现镜像 + 覆盖编译产物） | ⚠️ 每次镜像升级都要重打补丁、且没有版本锚点，编译产物结构一变就静默失效 |
| fork + 补丁 + 自建 CI 重建整个镜像 | ❌ 若原镜像的源码基线不可复现（版本号对不上公开仓库、构建参数不同），重建等于把线上应用换成一个**更新版本**，破坏性远大于功能本身 |

## 🧠 工作原理

清理条件（**保守**，宁可少删也不误伤）：

```sql
note."userHost" IS NOT NULL          -- 只看远程帖
AND note.id < genId(now - EXPIRY_DAYS 天)   -- 只删早于保留期的
AND note."clippedCount" = 0
AND NOT EXISTS (... user_note_pining ...)   -- 未被置顶
AND NOT EXISTS (... note_favorite   ...)   -- 未被收藏
AND NOT EXISTS (... clip_note       ...)   -- 未被 clip
AND NOT EXISTS (... note_reaction JOIN "user" ON ... host IS NULL ...)  -- 无本地用户反应
AND NOT EXISTS (... note c WHERE c."replyId"  = note.id ...)  -- 无回复子节点
AND NOT EXISTS (... note c2 WHERE c2."renoteId" = note.id ...)  -- 无转帖子节点
```

**「无子节点」是关键**：`note.replyId` / `note.renoteId` 是**自引用外键且 `ON DELETE CASCADE`**，删一条父帖会连带删掉指向它的回复与转帖（**包括你实例本地用户的**）。只删叶子帖就永远不会踩到这个坑；父帖会在后续轮次自然变成叶子（被删除子节点腾出来后）。

其他要点：

- **单批一条 `DELETE ... WHERE id IN (SELECT ...) ... RETURNING id`**：原子执行，避免「选中候选后新插入回复被级联误删」的竞态；配合 `statement_timeout` / `lock_timeout` 防长事务与锁等待。
- **游标只向前**：单轮内单调推进；跨轮可选用状态文件续跑（`STATE_FILE`），扫到范围末尾自动重置，下一轮从头捕捉新到期的帖。
- **借力镜像自身产物**：直接 `import` 镜像里的 `ormconfig.js`（TypeORM DataSource，自动读 `.config/default.yml`）与 `built/misc/id/{aidx,aid}.js`（生成时间边界 id）。**不需要启动应用、不需要 NestJS DI**，也不依赖镜像里有没有源码。
- **id 方法自适应**：实例用 `aidx` 还是 `aid` 由 `.config/default.yml` 的 `id:` 决定（自动识别，也可用 `ASSUME_ID_METHOD` 指定）。用错会让边界错位、删错或删不掉。

## 📦 前置要求

- 宿主机有 `docker`，且有权限 `docker run`；实例以 Docker Compose 方式部署（能拿到镜像名、compose 网络名、宿主上的 `.config` 目录）。
- 目标数据库是 **PostgreSQL**（Misskey/Sharkey 的标准部署）。
- 磁盘留有余量（删除会产生死元组，空间「先涨后降」，见下文「空间回收」）。
- 建议先补上缺失的外键索引（见「性能」一节），否则删除单价可能高一个数量级。

## 🚀 快速开始

```bash
# 1) 解包后进目录，跑安装（会自动探测镜像 / 网络 / .config 目录，并做一次只读预演）
sudo ./install.sh

# 2) 复核预演结果（候选条数、被保护条数、估算可回收体积），确认保留天数
#    输出形如：
#    {"SUMMARY":"DRY_RUN 完成，未删除任何数据","eligible":1761997,"pinned":50701,"hasChild":801512,...}

# 3) 手工实删一小批观察
sudo EXPIRY_DAYS=90 BATCH=200 MAX_NOTES=500 MAX_MINUTES=2 /opt/sharkey-notes-cleaner/run.sh

# 4) 确认无误后启用长期自动化（每天 04:00）
sudo ./install.sh --enable-timer
```

不想用安装脚本，也可以直接手工跑（不改宿主机任何配置）：

```bash
docker run --rm --network <compose网络> --entrypoint node --memory 512m \
  -v $PWD:/cleaner:ro \
  -v /path/to/compose/.config:/sharkey/.config:ro \
  -e DRY_RUN=1 -e EXPIRY_DAYS=90 -e BATCH=2000 -e MAX_MINUTES=180 -e SLEEP_MS=500 \
  <与 web 容器相同的镜像> /cleaner/clean.mjs
```

> 长跑请用 `-d --rm --name sharkey-cleaner-bulk` 再 `docker logs -f`，避免 SSH 断连把前台 `docker run` 带走。

## ⚙️ 配置参数

全部走环境变量（systemd 部署下写在 `/etc/default/sharkey-notes-cleaner`）：

| 变量 | 默认 | 说明 |
|---|---|---|
| `DRY_RUN` | `1` | **默认只读**；只有显式 `DRY_RUN=0` 才真删 |
| `EXPIRY_DAYS` | `90` | 保留天数；小于 30 会被拒绝（`MIN_EXPIRY_GUARD=0` 可覆盖） |
| `BATCH` | `1000` | 每批删除上限（批量跑建议 2000） |
| `MAX_MINUTES` | `180` | 单次运行时间上限 |
| `MAX_NOTES` | `0` | 单次删除条数上限，0=不限（试点/限流用） |
| `SLEEP_MS` | `1500` | 批间休眠，给数据库喘息 |
| `MONTHS` | `18` | `DRY_RUN` 时按月分布回溯月数 |
| `SHARKEY_HOME` | `/sharkey` | 镜像内应用根目录 |
| `STATE_FILE` | 空 | 跨轮续跑的状态文件（容器内路径；`run.sh` 默认 `/state/state.json`） |
| `STOP_FILE` | 空 | 该文件存在时优雅停止（`touch /var/lib/sharkey-notes-cleaner/STOP` 即刹车） |
| `ARCHIVE_DIR` | 空 | 非空时把每批被删 id 写成 `.ids.gz` 归档（首次积压可选） |
| `SAMPLE_IDS` | `5` | 预演时打印多少条样例候选 id |
| `MIN_EXPIRY_GUARD` | `1` | 是否启用「保留期不得小于 30 天」的安全闸 |
| `ASSUME_ID_METHOD` | `auto` | `aidx` / `aid` / `auto`（按 `.config/default.yml` 自动判断） |

## 🪜 建议的上线节奏

1. **只读预演**：`DRY_RUN=1`，看候选数、被保护数、估算体积、按月分布。
2. **小批试点**：`BATCH=200 MAX_NOTES=500 MAX_MINUTES=2`，删几百条，核对
   `pg_stat_user_tables.n_tup_del` 的增量是否与实际删除数一致、应用日志与前端是否正常。
3. **补索引 + 调 autovacuum**（见「性能」），再放开批量。
4. **清理积压**：分窗口跑，例如 `BATCH=2000 SLEEP_MS=500 MAX_MINUTES=200`；实测吞吐 ≈130 行/秒，
   积压 170 万条约需 3–4 小时；跨窗口靠 `STATE_FILE` 续跑。
5. **层叠收敛**：只删叶子的规则意味着「被转帖/被回复的帖」要等子节点删掉后**下一轮**才变成叶子。
   实测单轮跑完后残留会按约 0.5–0.7 倍逐轮衰减（150.8k → 60.3k → 32.5k → 19.8k → 13.5k → 9.9k …），
   所以要**反复跑到某一轮 0 删除**才算收敛：直接跑 `tools/converge.sh`（默认最多 15 轮，每轮 ≤15 分钟）。
6. **稳态**：启用 timer，每天一次（日增几千条时几秒就跑完）。稳态下新到期的帖都是新叶子，不会层叠。
7. **收尾**：`VACUUM (ANALYZE) note`；需要把磁盘真正还给操作系统时，择窗口 `VACUUM FULL`。

> ⚠️ 收敛循环与 systemd timer **不能重叠**（同一批行会被两个进程争抢）：跑 `converge.sh` 前先
> `systemctl stop sharkey-notes-cleaner.timer`，跑完再 `start`。
> ⚠️ **长跑不要加 `--rm`**：容器退出即被删除，日志（含最后那行 `SUMMARY`：最终删除数、时间范围、中止原因）
> 会一起消失。要么不加 `--rm`（跑完手工 `docker rm`），要么把输出重定向到文件（`converge.sh` 就是这么做的）。

## 📊 观测指标

```sql
-- 删除是否真的发生（比 count(*) 更可靠）
SELECT n_tup_del, n_dead_tup, last_autovacuum FROM pg_stat_user_tables WHERE relname = 'note';
-- 表/索引/整库体积
SELECT pg_size_pretty(pg_total_relation_size('note')), pg_size_pretty(pg_database_size(current_database()));
-- autovacuum 是否跟得上
SELECT pid, state, left(query,50), now()-xact_start FROM pg_stat_activity WHERE query ILIKE '%autovacuum%note%';
```

清理器每次运行都会打印一行机器可读的 `{"SUMMARY": ...}`（`COMPLETED` / `TIME_LIMIT` / `ABORTED` / `DRY_RUN`），便于接监控。

## 🧹 空间回收

- 普通 `VACUUM` 只把空间标记为可复用，**`df` 不会立刻下降**，这是 PostgreSQL MVCC 的正常行为。
- 想把空间真正还给操作系统：
  - `VACUUM FULL note;` —— 会拿 `ACCESS EXCLUSIVE` 锁（全表阻塞），需要约「表+索引」量级的额外磁盘空间。
    执行前在会话里 `SET statement_timeout = 0;`（否则会被服务器默认的 120s 语句超时杀掉），且不要放在事务块里。
  - 或 `pg_repack`（需另装，同样需要额外空间，但锁时间短）。
- 批量删除期间把 `note` 的 autovacuum 收紧（见 `sql/02-add-missing-indexes.sql` 末尾注释）。
- 删除**不会**顺带清掉远端媒体缓存文件（`drive_file` 中远端条目通常是 0 字节的链接），如需清理请用 Misskey 自带的远程文件清理。

## ⏰ 长期自动化（systemd）

```bash
sudo install -m 0644 systemd/sharkey-notes-cleaner.service /etc/systemd/system/
sudo install -m 0644 systemd/sharkey-notes-cleaner.timer   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now sharkey-notes-cleaner.timer
systemctl list-timers | grep sharkey-notes-cleaner
journalctl -u sharkey-notes-cleaner -n 50            # 每次运行的 JSON 日志
```

- 调整频率/时段：改 timer 的 `OnCalendar=`（默认每天 04:00 + 10 分钟抖动）。
- 调整强度：改 `/etc/default/sharkey-notes-cleaner` 的 `BATCH` / `MAX_MINUTES` / `SLEEP_MS`。
- 告警：`CLEANER_NOTIFY_CMD` 只在异常（非 0 退出、fatal、连续批失败 > 8）时被调用；**默认留空**（只写日志）。
  想接告警就填你自己的命令（Telegram bot 脚本、邮件、webhook 等），脚本会以「消息正文」作为唯一参数调用它。

### 一次性维护：`VACUUM FULL`（把空间真正还给 OS）

`VACUUM FULL note` 会**全表加 `ACCESS EXCLUSIVE` 锁**（期间该表读写阻塞，站点会短暂不可用），
所以适合排成「低峰时刻的一次性任务」，并用包装脚本把清理定时器停/起、跑完通报体积：

```bash
sudo install -m 0755 tools/vacuum-full.sh        /opt/sharkey-notes-cleaner/tools/
sudo install -m 0755 tools/vacuum-maintenance.sh /opt/sharkey-notes-cleaner/tools/
sudo install -m 0644 systemd/sharkey-notes-cleaner-vacuum.service /etc/systemd/system/
sudo install -m 0644 systemd/sharkey-notes-cleaner-vacuum.timer   /etc/systemd/system/
# 先改 timer 里的 OnCalendar=<你要的年月日 时:分:秒>，再：
sudo systemctl daemon-reload && sudo systemctl enable --now sharkey-notes-cleaner-vacuum.timer
DRY=1 /opt/sharkey-notes-cleaner/tools/vacuum-maintenance.sh   # 自检：只打印将做什么
```

包装脚本做的事：停 `sharkey-notes-cleaner.timer` → 等清理容器退出（最多 10 分钟，仍在跑就安全放弃）→
`VACUUM (FULL, ANALYZE) note`（会话内 `statement_timeout=0`）→ 起定时器 → 用 `CLEANER_NOTIFY_CMD` 通报
「前后体积 + 耗时」。日志：`/var/log/sharkey-cleaner/{vacuum-maintenance,vacuum-full}.log`；
`Persistent=false`（错过不补跑，避免白天做全表锁操作）。实测参考：310 万行 → 59.5 万行后
`VACUUM FULL` 前 `note` 3,792MB（堆 1,673 + 索引 2,119），重写后约 1GB，回收 ≈2.8GB。

## 🛑 应急停止 / 卸载 / 退役

```bash
touch /var/lib/sharkey-notes-cleaner/STOP          # 优雅刹车（当前批跑完即停）
sudo systemctl stop sharkey-notes-cleaner           # 停当前运行
sudo systemctl disable --now sharkey-notes-cleaner.timer   # 停定时
docker rm -f sharkey-cleaner-bulk                   # 停手工 detach 的那次
sudo ./install.sh --uninstall                       # 删 unit（保留文件与数据库改动）
```

**上游一旦自带该功能**（Sharkey/Misskey 新版本 / 新镜像带 `cleanRemoteNotes`），停掉 timer 即可退役：
清理器与镜像零耦合，不会和上游任务打架（上游该功能默认关闭，需管理员显式开启）。

## 🚄 性能：先做一次索引体检

删一条 `note` 时，PostgreSQL 要按子表的 FK 列查找子行；**子表 FK 列没有索引就会全表扫描**。
实测一个 310 万行 `note` 的实例：`latest_note.note_id`(13ms/行) + `note_edit.replyId`(72ms/行)
+ `note_edit.renoteId`(55ms/行) 缺索引 → 删除单价 **140 ms/行**；补上三个索引后 **7.4 ms/行（19 倍）**。

```bash
# 只查不改
docker exec -i <db容器> sh -c 'psql -U $POSTGRES_USER -d $POSTGRES_DB' < sql/01-check-missing-fk-indexes.sql
# 确认后补索引（CREATE INDEX CONCURRENTLY 不阻塞读写）
docker exec -i <db容器> sh -c 'psql -U $POSTGRES_USER -d $POSTGRES_DB' < sql/02-add-missing-indexes.sql
```

这同时也是**应用自身的既有缺陷**（用户删自己的帖、删账号、管理操作都在付这个代价），值得反馈给上游。

## 🩺 故障排查

| 症状 | 原因 | 处理 |
|---|---|---|
| `Cannot read properties of undefined (reading 'slice')` | TypeORM 的 `query()` 对 `DELETE ... RETURNING` 返回 `[rows, affectedCount]` 两元组，被当成 rows 用 | 本脚本已兼容两种形状；自造脚本请注意 |
| 报 `no such file` / 找不到 `ormconfig.js` | `SHARKEY_HOME` 不对，或镜像内路径变了 | 改 `SHARKEY_HOME`；`docker exec <web容器> ls $SHARKEY_HOME/packages/backend` 核对 |
| 一条都删不掉，候选数却很多 | id 方法用错（`aid` vs `aidx`），边界与真实 id 错位 | 看 `.config/default.yml` 的 `id:`，或 `ASSUME_ID_METHOD=aidx` 显式指定 |
| 删除极慢（>100ms/行） | 子表 FK 列缺索引 | 跑 `sql/01` 体检 + `sql/02` 补索引 |
| `ALTER TABLE ... SET (autovacuum_naptime=...)` 报 `unrecognized parameter` | `autovacuum_naptime` 是全局 GUC，不是 per-table 选项 | 只设 `autovacuum_vacuum_scale_factor` / `autovacuum_vacuum_cost_limit` |
| 删完 `df` 没降 | MVCC 死元组尚未回收 | 见「空间回收」；看 `n_dead_tup` 与表体积而非 `df` |
| 容器 `--entrypoint` 疑虑 | 镜像 `ENTRYPOINT` 是 `/sbin/tini --`，会 exec 你传入的命令 | 直接用即可；想显式写 `--entrypoint node` 也可以 |
| 应用日志出现签名失败等 error | 通常是既有的联邦中继噪音，与本清理无关 | 对比清理前后的日志条数与类型；有新增类型再排查 |
| `batch-failed` 连续多次后中止 | 语句超时 / 死锁 / 完整性竞态 | 降低 `BATCH`、加大 `SLEEP_MS`；看日志里的 `code`（`57014` 超时 / `40P01` 死锁 / `23xxx` 完整性） |

## ⚠️ 限制与风险（请先读完再动手）

- **删除不可逆**。请自行决定是否在批量清理前做 `pg_dump -Fc` 冷备（本工具不做备份）。
- **绕过应用层直接删库**：父帖的 `repliesCount/renoteCount`、`user.notesCount`、`hashtag` 计数、
  各种 Redis 缓存**不会**被回减/失效（`note` 表没有任何触发器，计数全由应用维护）。
  本工具用「只删叶子 + 无本地互动」把影响面压到最小；上游自己的实现同样是绕过应用直接删。
- **会有少量永久残留**：被置顶的帖、互相转帖形成的环、子帖被永久保护（如被置顶）的父帖不会被删，属预期。
- **直接删与被删帖相关的本地投票/静音等关联行**：这些表对 `note` 都是 `ON DELETE CASCADE`，
  删帖会连带清掉它们（数量通常极小）。
- 本工具面向**远程帖**。它不会删你自己的本地帖（`userHost IS NULL` 一律跳过）。

## 📈 实测数据

| 项 | 值 |
|---|---|
| `note` 表 | 3,095,742 行 / 3.79GB（堆 ≈1.67GB + 索引 ≈2.1GB） |
| 远程 / 本地帖 | 3,095,711 / 31 |
| 90 天为界、未 clip 的远程帖 | 2,612,177 |
| 其中被置顶 | 50,701 |
| 其中有子节点 | 801,512 |
| 其中子帖仍在 90 天窗口内（本轮被挡） | 3,948 |
| **第一轮可直接删（叶子 + 无本地互动）** | **1,761,997** |
| 稳态日增 | ≈6,000 条/天 |
| 候选查询 | 1000 条 / 194 ms |
| 删除单价（补索引前 → 后） | 140 ms/行 → **7.4 ms/行** |
| 实测吞吐 | ≈130 行/秒（`BATCH=2000`） |
| 估算可回收 | ≈2.0 GB（表+索引，需 VACUUM 才归还 OS） |

**一次真实清理的完整结果**（2026-10-14，同一实例，全部达标无异常）：

| 结果 | 值 |
|---|---|
| `note` 行数 | 3,096,859 → **595,201** |
| 删除行数 | **≈2,502,400**（`n_tup_del` 16,037 → 2,518,508 逐一对上） |
| 时长 | 积压 2 轮约 3.3 小时 + 层叠收敛约 1.5 小时（含等待间隙共 ~6.7 小时） |
| 吞吐 / 单价 | ≈130 行/秒 / 7.4 ms/行（补索引后） |
| autovacuum | 全程跟得上（`n_dead_tup` 峰值 20 万即被回收） |
| 残留 | 110,449 行老远程帖，其中 **46% 被置顶**（上游语义按设计保留） |
| 应用影响 | HTTP 200、无新增错误类型、0 个 >60s 长事务 |
| 空间 | `VACUUM ANALYZE` 后表仍 3,792MB；`VACUUM FULL` 预计 ≈1GB（回收 ~2.8GB） |

## 🗂️ 文件清单

```
sharkey-notes-cleaner/
├── clean.mjs                     # 清理器本体（Node ESM，零第三方依赖，只用镜像内产物）
├── run.sh                        # 定时入口：读 /etc/default/*，跑一次性容器，异常才告警
├── install.sh                    # 安装：自动探测镜像/网络/配置目录 + 只读预演 +（可选）装 timer
├── env.example                   # /etc/default/sharkey-notes-cleaner 模板
├── systemd/
│   ├── sharkey-notes-cleaner.service
│   ├── sharkey-notes-cleaner.timer
│   ├── sharkey-notes-cleaner-vacuum.service   # 一次性维护：VACUUM FULL（停/起清理定时器 + 通报）
│   └── sharkey-notes-cleaner-vacuum.timer
├── sql/
│   ├── 01-check-missing-fk-indexes.sql   # 只读体检：哪些外键子表缺索引
│   └── 02-add-missing-indexes.sql        # 补索引（CREATE INDEX CONCURRENTLY）
├── docs/DESIGN.md                # 设计取舍：为什么是外部清理器（含多模型会诊与红队结论）
├── tools/
│   ├── converge.sh               # 层叠收敛：反复跑到「0 删除」为止（跑前先停 timer）
│   ├── vacuum-full.sh            # VACUUM FULL note（低峰窗口执行，会短暂锁表）
│   ├── vacuum-maintenance.sh     # 一次性维护包装：停 timer → 等清理退出 → VACUUM FULL → 起 timer → 通报
│   └── package.sh                # 打 tar.gz + zip 分发包
├── CHANGELOG.md
├── VERSION
└── LICENSE
```

## 📜 许可与声明

MIT（见 `LICENSE`）。本工具是独立实现，不与 Misskey / Sharkey 的代码产生衍生关系；
它只是通过你实例自带的镜像与数据库完成清理，清理语义参考了上游
[misskey-dev/misskey#16292](https://github.com/misskey-dev/misskey/pull/16292)、
[#16368](https://github.com/misskey-dev/misskey/pull/16368)、
[#16412](https://github.com/misskey-dev/misskey/pull/16412) 的行为定义。

> 🤖 **AIGC 声明**：本项目的代码、文档与其中的实测数据由 AI 助手（Hermes Agent）在人类指导下编写与验证，
> 关键结论均在真实实例上实测（含试跑、回滚式探针、`n_tup_del` 计数核对）。使用前请自行复核并备份。
