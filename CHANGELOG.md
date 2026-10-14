## 1.0.4

- 新增一次性维护单元 `systemd/sharkey-notes-cleaner-vacuum.{service,timer}` + `tools/vacuum-maintenance.sh`：
  在低峰窗口把 `VACUUM FULL note` 排成一次性任务（写死 `OnCalendar=` 日期、`Persistent=false` 错过不补跑），
  包装脚本负责「停清理定时器 → 等清理容器退出（最多 10 分钟，仍在跑就安全放弃）→ 全表重写 →
  起定时器 → 用通知器通报前后体积与耗时」，并支持 `DRY=1` 自检。
- README：新增「一次性维护：VACUUM FULL」小节（代价、排期方法、日志位置、实测回收量）。

## 1.0.3

- 新增 `tools/vacuum-full.sh`：低峰窗口用的 `VACUUM FULL note` 包装（`statement_timeout=0`、前后体积对比、
  耗时统计、日志落盘、执行前检查有无清理容器在跑），并在 README「空间回收」里写明代价与窗口建议。
- README「实测数据」补上**一次完整清理的结果**（310 万行 → 59.5 万行、删 ~250 万行、残留 46% 是被置顶帖、
  应用零异常、吞吐 ≈130 行/秒）。
- 明确层叠收敛的衰减规律（0.5–0.7 → 0.99，尾部每轮只剩几百行），并把「稳态不会层叠」写清。

## 1.0.2

- 新增 `tools/converge.sh`：**层叠收敛循环**——只删叶子的规则会让「被转帖/被回复的帖」要等子节点删完的
  **下一轮**才成为叶子；实测残留按约 0.5–0.7 倍逐轮衰减（150.8k → 60.3k → 32.5k → 19.8k → 13.5k → 9.9k …），
  单轮跑不到 0，需要循环到「某一轮 0 删除」。脚本默认最多 15 轮、每轮 ≤15 分钟，日志落 `/var/log/sharkey-cleaner/`。
- README：补「层叠收敛」步骤、以及两条硬约束 ——
  ① 收敛循环与 systemd timer 不能重叠；② **长跑不要加 `--rm`**（容器一退出日志连同最后那行 `SUMMARY` 一起消失，
  最终删除数/时间范围/中止原因都没了；实测踩过，后来只能用 `n_tup_del` 反推）。
- README 故障排查：补「一轮跑完还剩几十万行是正常的」说明。

## 1.0.1

- `run.sh`：**未知环境下的安全默认改为 `DRY_RUN=1`（只读）**；配置文件缺失时不再误删。
- `run.sh`：调用方显式传入的 `DRY_RUN/EXPIRY_DAYS/BATCH/MAX_MINUTES/MAX_NOTES/SLEEP_MS` 现在优先于 `/etc/default/*`
  （便于手工试跑与限流：`DRY_RUN=1 MAX_NOTES=500 /opt/sharkey-notes-cleaner/run.sh`）。
- `install.sh`：探测改为三级判定（镜像名 → 排除 postgres/pgroonga/redis/cleaner → 硬校验容器内 `ormconfig.js`），
  并在安装后自动跑一次只读预演；多网络容器优先选 `*_default`。
- 打包脚本：兼容 Windows/MSYS（探测可用 python + `cygpath -m`）。

## 1.0.0

首个可分发版本。基于一次真实实例（`note` 表 310 万行 / 3.79GB）的完整实测：

**功能**

- `clean.mjs`：外部清理器，同镜像一次性容器内运行，复用镜像自带 `ormconfig.js`（TypeORM DataSource）与 `built/misc/id/{aidx,aid}.js`，无需启动应用。
- 清理语义：远程帖 + 早于保留期 + 无置顶/收藏/clip/本地反应 + **无任何子节点**（避免自引用 CASCADE 误删本地回复与转帖）。
- 单批 `DELETE ... WHERE id IN (SELECT ...) RETURNING id` 原子执行；`statement_timeout` / `lock_timeout` 保护。
- `DRY_RUN` 默认开启（只读预演）；`MAX_NOTES` / `MAX_MINUTES` / `BATCH` 限流；`STOP_FILE` 优雅刹车；`STATE_FILE` 跨轮续跑并在扫到末尾时自动重置。
- 安全闸：`EXPIRY_DAYS < 30` 直接拒绝执行。
- 机器可读输出：每次运行末尾一行 `{"SUMMARY": ...}`。

**部署**

- `install.sh`：自动探测 web 容器 / 镜像 / compose 网络 / 宿主 `.config` 目录与 db 容器，装文件、写 `/etc/default/sharkey-notes-cleaner`、跑只读预演、可选安装并启用 systemd timer。
- `run.sh`：systemd 入口，异常（非 0 退出 / fatal / 连续批失败 > 8）才调用通知命令，常态静默。
- `systemd/`：oneshot service + 每天 04:00（带 10 分钟抖动、`Persistent=true`）的 timer。
- `sql/01`：只读体检——列出引用 `note` 的外键子表中**缺索引**的项。
- `sql/02`：补索引脚本（`CREATE INDEX CONCURRENTLY`，不阻塞读写）。

**修复的历史坑（都真实踩过）**

- **安装脚本探测 bug**：清理器自己也是「用同一镜像跑的容器」，早先的探测会把它当成应用容器，并进而挑错 db 容器（把同一台机器上**别的** PostgreSQL 容器当成目标库，报 `relation "note" does not exist`）。现在按「镜像名像 Sharkey/Misskey + 排除 postgres/pgroonga/redis/cleaner + 硬校验容器内 `ormconfig.js` 存在」三级判定。
- **多网络容器选错网络**：应用容器同时接了 compose 网络与外部共享网络，map 迭代顺序随机会挑错，导致 `db` 解析不到。现在优先 `*_default`，其次项目名网络。
- TypeORM 的 `query()` 对 `DELETE ... RETURNING` 返回 `[rows, affectedCount]` 两元组，误当 rows 用会让游标被写成数字并抛 `Cannot read properties of undefined (reading 'slice')`。现已兼容两种形状，并在形状异常时**主动中止**而非继续推进游标。
- 边界 id 必须用实例配置的 id 方法（`aidx` vs `aid`）生成，用错会删错/删不掉；现已从 `.config/default.yml` 自动识别。
- 缺索引导致删除单价 140ms/行 → 补 3 个索引后 7.4ms/行（19 倍）。
- `autovacuum_naptime` 是全局 GUC，写进 per-table 选项会让整条 `ALTER TABLE` 失败回滚。
- 长跑必须 detach（`docker run -d`）：SSH 断连会带走前台 `docker run`。
- `docker run <镜像> node x.mjs` 不会被镜像 ENTRYPOINT（`/sbin/tini --`）吞掉，无需强加 `--entrypoint`。
- Windows/MSYS 下打包脚本里 `python3` 可能是商店占位符、且原生 python 不认 MSYS 路径：打包脚本已改为探测可用 python + `cygpath -m` 转换。
