#!/usr/bin/env node
/**
 * sharkey-notes-cleaner —— 外部清理器（默认只读）
 *
 * 给自托管 Misskey/Sharkey 实例批量清理「早于保留期的远程帖」，用于回收数据库空间。
 * 设计目标：不改镜像、不改源码、不动数据库结构；随时可停、可退役。
 *
 * 依赖镜像内已有产物（无需启动应用、无需 NestJS DI）：
 *   ${SHARKEY_HOME}/packages/backend/ormconfig.js             → TypeORM DataSource（自动读 .config/default.yml）
 *   ${SHARKEY_HOME}/packages/backend/built/misc/id/aidx.js    → 生成/解析 aidx（本站 id 方法）
 *   ${SHARKEY_HOME}/packages/backend/built/misc/id/aid.js     → 生成/解析 aid（若实例用 aid）
 *
 * 用法：node clean.mjs [--help] [--version]
 * 配置全部走环境变量，见 README.md。
 */
import { existsSync, readFileSync, writeFileSync, mkdirSync, rmSync } from 'node:fs';
import { mkdir, writeFile } from 'node:fs/promises';
import { dirname } from 'node:path';
import { gzipSync } from 'node:zlib';

const VERSION = '1.0.0';
const argv = process.argv.slice(2);
if (argv.includes('--help') || argv.includes('-h')) {
	print(readHelp());
	process.exit(0);
}
if (argv.includes('--version') || argv.includes('-V')) {
	print(VERSION);
	process.exit(0);
}

function print(s) { process.stdout.write(`${s}\n`); }
function readHelp() {
	return `sharkey-notes-cleaner ${VERSION}

只读预演（默认）：   DRY_RUN=1 node clean.mjs
真正删除：           DRY_RUN=0 node clean.mjs

环境变量
  DRY_RUN                 1=只统计不删除（默认）  0=真删
  EXPIRY_DAYS             保留天数（默认 90；小于 30 会被拒绝，除非 MIN_EXPIRY_GUARD=0）
  BATCH                   每批删除条数上限（默认 1000）
  MAX_MINUTES             单次运行时间上限（默认 180）
  MAX_NOTES               单次删除条数上限，0=不限（默认 0）
  SLEEP_MS                批间休眠（默认 1500）
  MONTHS                  DRY_RUN 按月分布的月数（默认 18）
  SHARKEY_HOME            镜像内应用根目录（默认 /sharkey）
  STATE_FILE              JSON 状态文件路径：跨轮续跑游标（默认空=每轮从头扫）
  STOP_FILE               该文件存在时优雅停止（默认空）
  ARCHIVE_DIR             非空时把每批被删 id 写成 .ids.gz 归档（默认空）
  SAMPLE_IDS              DRY_RUN 时打印多少条样例候选 id（默认 5）
  ASSUME_ID_METHOD        aidx|aid|auto（默认 auto，读 .config/default.yml 的 id:）
`;
}

const cfg = {
	dryRun: (process.env.DRY_RUN ?? '1') !== '0',
	expiryDays: Number(process.env.EXPIRY_DAYS ?? 90),
	batch: Math.max(1, Number(process.env.BATCH ?? 1000)),
	maxMinutes: Number(process.env.MAX_MINUTES ?? 180),
	maxNotes: Math.max(0, Number(process.env.MAX_NOTES ?? 0)),
	sleepMs: Math.max(0, Number(process.env.SLEEP_MS ?? 1500)),
	months: Math.max(0, Number(process.env.MONTHS ?? 18)),
	home: process.env.SHARKEY_HOME ?? '/sharkey',
	stateFile: process.env.STATE_FILE ?? '',
	stopFile: process.env.STOP_FILE ?? '',
	archiveDir: process.env.ARCHIVE_DIR ?? '',
	sampleIds: Number(process.env.SAMPLE_IDS ?? 5),
	idMethod: (process.env.ASSUME_ID_METHOD ?? 'auto').toLowerCase(),
	minExpiryGuard: (process.env.MIN_EXPIRY_GUARD ?? '1') !== '0',
};

const log = (level, msg, extra) => {
	print(JSON.stringify({ t: new Date().toISOString(), level, msg, ...(extra ?? {}) }));
};
const die = (msg, extra) => { log('error', 'fatal', { message: msg, ...(extra ?? {}) }); process.exit(2); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

if (!Number.isFinite(cfg.expiryDays) || cfg.expiryDays <= 0) die(`EXPIRY_DAYS 非法: ${process.env.EXPIRY_DAYS}`);
if (cfg.minExpiryGuard && cfg.expiryDays < 30) {
	die(`EXPIRY_DAYS=${cfg.expiryDays} 小于 30 天，已拒绝执行（确认无误可设 MIN_EXPIRY_GUARD=0 覆盖）`);
}

// ── 载入镜像内产物 ────────────────────────────────────────────────────────────
const ormconfigPath = `${cfg.home}/packages/backend/ormconfig.js`;
if (!existsSync(ormconfigPath)) die(`找不到 ${ormconfigPath}（SHARKEY_HOME 是否正确？）`);
const ormconfig = (await import(ormconfigPath)).default;

async function loadIdLibs() {
	const aidx = await import(`${cfg.home}/packages/backend/built/misc/id/aidx.js`);
	const aid = await import(`${cfg.home}/packages/backend/built/misc/id/aid.js`);
	return { aidx, aid };
}

function detectIdMethod(confPath) {
	try {
		const m = readFileSync(confPath, 'utf8').match(/^\s*id:\s*['"]?([A-Za-z]+)['"]?/m);
		return m ? m[1].toLowerCase() : null;
	} catch { return null; }
}

// ── 删除语义：远程帖 + 早于阈值 + 无 pin/favorite/clip/本地 reaction + 无任何子节点 ──
const PREDICATE = `
	n."userHost" IS NOT NULL
	AND n.id < $1
	AND n."clippedCount" = 0
	AND NOT EXISTS (SELECT 1 FROM user_note_pining p WHERE p."noteId" = n.id)
	AND NOT EXISTS (SELECT 1 FROM note_favorite  f WHERE f."noteId" = n.id)
	AND NOT EXISTS (SELECT 1 FROM clip_note      cn WHERE cn."noteId" = n.id)
	AND NOT EXISTS (SELECT 1 FROM note_reaction r JOIN "user" u ON r."userId" = u.id
	                 WHERE r."noteId" = n.id AND u."host" IS NULL)
	AND NOT EXISTS (SELECT 1 FROM note c  WHERE c."replyId"  = n.id)
	AND NOT EXISTS (SELECT 1 FROM note c2 WHERE c2."renoteId" = n.id)
`;
const CURSOR_CLAUSE = 'AND n.id > $2';
const countSql = (where) => `SELECT count(*)::int AS c FROM note n WHERE ${where}`;

function readState() {
	if (!cfg.stateFile || !existsSync(cfg.stateFile)) return { cursor: '0' };
	try {
		const s = JSON.parse(readFileSync(cfg.stateFile, 'utf8'));
		return { cursor: typeof s.cursor === 'string' && s.cursor ? s.cursor : '0' };
	} catch { return { cursor: '0' }; }
}
function writeState(cursor) {
	if (!cfg.stateFile) return;
	try {
		mkdirSync(dirname(cfg.stateFile), { recursive: true });
		writeFileSync(cfg.stateFile, JSON.stringify({ cursor, updatedAt: new Date().toISOString() }, null, 1));
	} catch (e) { log('warn', 'state-write-failed', { message: String(e?.message ?? e) }); }
}
function clearState() {
	if (!cfg.stateFile) return;
	try { rmSync(cfg.stateFile, { force: true }); } catch { /* ignore */ }
}

async function survey(em, cutoff, genId) {
	const t0 = Date.now();
	const base = `n."userHost" IS NOT NULL AND n.id < $1 AND n."clippedCount" = 0`;
	const one = async (where, params = [cutoff]) => (await em.query(countSql(where), params))[0].c;
	const out = {
		base: await one(base),
		pinned: await one(`${base} AND EXISTS (SELECT 1 FROM user_note_pining p WHERE p."noteId" = n.id)`),
		favorited: await one(`${base} AND EXISTS (SELECT 1 FROM note_favorite f WHERE f."noteId" = n.id)`),
		clippedByTable: await one(`${base} AND EXISTS (SELECT 1 FROM clip_note cn WHERE cn."noteId" = n.id)`),
		localReaction: await one(`${base} AND EXISTS (SELECT 1 FROM note_reaction r JOIN "user" u ON r."userId" = u.id WHERE r."noteId" = n.id AND u."host" IS NULL)`),
		hasChild: await one(`${base} AND (EXISTS (SELECT 1 FROM note c WHERE c."replyId" = n.id) OR EXISTS (SELECT 1 FROM note c2 WHERE c2."renoteId" = n.id))`),
		blockedByFreshChild: await one(`${base} AND (EXISTS (SELECT 1 FROM note c WHERE c."replyId" = n.id AND c.id >= $1) OR EXISTS (SELECT 1 FROM note c2 WHERE c2."renoteId" = n.id AND c2.id >= $1))`),
		eligible: await one(PREDICATE),
	};
	if (cfg.months > 0) {
		const now = Date.now();
		out.months = [];
		for (let i = 0; i < cfg.months; i++) {
			const hi = i === 0 ? cutoff : genId(now - i * 30 * 86400000);
			const lo = genId(now - (i + 1) * 30 * 86400000);
			out.months.push({ from: lo, until: hi, daysAgo: i * 30, base: await one(`${base} AND n.id >= $2 AND n.id < $1`, [hi, lo]) });
		}
	}
	const t1 = Date.now();
	const ids = (await em.query(`SELECT n.id FROM note n WHERE ${PREDICATE} ${CURSOR_CLAUSE} ORDER BY n.id ASC LIMIT $3`, [cutoff, '0', cfg.batch])).map((r) => r.id);
	out.probeBatch = { asked: cfg.batch, got: ids.length, ms: Date.now() - t1 };
	out.sampleIds = ids.slice(0, cfg.sampleIds);
	out.surveyMs = Date.now() - t0;
	return out;
}

async function run() {
	const { aidx, aid } = await loadIdLibs();
	const method = cfg.idMethod === 'auto' ? (detectIdMethod(`${cfg.home}/.config/default.yml`) ?? 'aidx') : cfg.idMethod;
	const genId = method === 'aid' ? aid.genAid : aidx.genAidx;
	const parseId = method === 'aid' ? aid.parseAid : aidx.parseAidx;
	log('info', 'start', {
		version: VERSION, mode: cfg.dryRun ? 'DRY_RUN' : 'DELETE', idMethod: method,
		expiryDays: cfg.expiryDays, batch: cfg.batch, maxMinutes: cfg.maxMinutes,
		maxNotes: cfg.maxNotes, sleepMs: cfg.sleepMs,
		stateFile: cfg.stateFile || null, stopFile: cfg.stopFile || null,
	});

	const ds = ormconfig;
	await ds.initialize();
	const cutoff = genId(Date.now() - cfg.expiryDays * 86400000);
	const state = readState();
	const started = Date.now();
	const deadline = started + cfg.maxMinutes * 60000;

	if (cfg.dryRun) {
		const s = await ds.transaction(async (em) => {
			await em.query(`SET LOCAL statement_timeout = '600s'`);
			return survey(em, cutoff, genId);
		});
		const perRowBytes = 1220;              // 实测经验值：note 表堆+索引 ≈1.2KB/行
		log('info', 'survey', { ...s, estimatedReclaimMB: Math.round((s.eligible * perRowBytes) / 1048576), elapsedSec: Math.round((Date.now() - started) / 1000) });
		print(JSON.stringify({
			SUMMARY: 'DRY_RUN 完成，未删除任何数据',
			version: VERSION,
			cutoff,
			cutoffAt: parseId(cutoff).date.toISOString(),
			expiryDays: cfg.expiryDays,
			idMethod: method,
			eligible: s.eligible,
			base: s.base,
			hasChild: s.hasChild,
			blockedByFreshChild: s.blockedByFreshChild,
			pinned: s.pinned,
			favorited: s.favorited,
			clippedByTable: s.clippedByTable,
			localReaction: s.localReaction,
			estimatedReclaimMB: Math.round((s.eligible * perRowBytes) / 1048576),
			probe: s.probeBatch,
			sampleIds: s.sampleIds,
		}));
		await ds.destroy();
		return;
	}

	// ── 实删 ──────────────────────────────────────────────────────────────────
	let cursor = state.cursor;
	let deleted = 0;
	let batches = 0;
	let oldest = null;
	let newest = null;
	let affectedMismatch = 0;
	let failures = 0;
	let aborted = null;
	let ranOutOfCandidates = false;
	if (cfg.archiveDir) await mkdir(cfg.archiveDir, { recursive: true });
	if (state.cursor !== '0') log('info', 'resume-from-state', { cursor: state.cursor });

	while (Date.now() < deadline && (cfg.maxNotes === 0 || deleted < cfg.maxNotes)) {
		if (cfg.stopFile && existsSync(cfg.stopFile)) { aborted = 'stop-file'; log('warn', 'stop-file-detected', { file: cfg.stopFile }); break; }
		const t0 = Date.now();
		try {
			// 注意：TypeORM query() 对 DELETE ... RETURNING 返回 [rows, affectedCount] 两元组
			const raw = await ds.transaction(async (em) => {
				await em.query(`SET LOCAL statement_timeout = '60s'`);
				await em.query(`SET LOCAL lock_timeout = '10s'`);
				return em.query(
					`DELETE FROM note WHERE id IN (
						SELECT n.id FROM note n WHERE ${PREDICATE} ${CURSOR_CLAUSE} ORDER BY n.id ASC LIMIT $3
					) RETURNING id`,
					[cutoff, cursor, cfg.batch],
				);
			});
			const rows = Array.isArray(raw) && Array.isArray(raw[0]) ? raw[0] : raw;
			const affected = Array.isArray(raw) && !Array.isArray(raw[0]) ? raw[1] : undefined;
			if (!Array.isArray(rows) || (rows.length > 0 && typeof rows[0]?.id !== 'string')) {
				throw new Error(`DELETE 返回了意料之外的形状，已中止以防游标错乱：${JSON.stringify(raw).slice(0, 200)}`);
			}
			failures = 0;
			if (!rows.length) { ranOutOfCandidates = true; log('info', 'done-no-more-candidates', { deleted, batches, cursor }); break; }
			const ids = rows.map((r) => r.id);
			const nextCursor = ids.reduce((m, id) => (id > m ? id : m), cursor);
			if (nextCursor === cursor) { aborted = 'cursor-stuck'; log('error', 'cursor-not-advancing', { cursor }); break; }
			cursor = nextCursor;
			if (affected !== undefined && affected !== ids.length) { affectedMismatch += 1; log('warn', 'affected-mismatch', { affected, returned: ids.length }); }
			batches += 1;
			deleted += ids.length;
			for (const id of ids) {
				const t = parseId(id).date.getTime();
				if (oldest === null || t < oldest) oldest = t;
				if (newest === null || t > newest) newest = t;
			}
			if (cfg.archiveDir) {
				const gz = gzipSync(Buffer.from(`${ids.join('\n')}\n`));
				await writeFile(`${cfg.archiveDir}/deleted-${new Date().toISOString().replace(/[:.]/g, '-')}.ids.gz`, gz);
			}
			writeState(cursor);
			log('info', 'batch', { batch: batches, got: ids.length, deleted, cursor, ms: Date.now() - t0, cursorAt: parseId(cursor).date.toISOString() });
		} catch (e) {
			failures += 1;
			const code = e?.driverError?.code ?? e?.code ?? '';
			log('warn', 'batch-failed', { code, message: String(e?.message ?? e).slice(0, 300), consecutiveFailures: failures });
			if (failures >= 5) { aborted = 'repeated-failures'; log('error', 'abort-after-repeated-failures', { code }); break; }
			await sleep(5000 * failures);
			continue;
		}
		await sleep(cfg.sleepMs);
	}

	if (ranOutOfCandidates) clearState();   // 到末尾：清状态，下一轮从头扫（捕捉新到期的帖）
	const summary = {
		SUMMARY: cfg.dryRun ? 'DRY_RUN' : (aborted ? 'ABORTED' : ranOutOfCandidates ? 'COMPLETED' : 'TIME_LIMIT'),
		version: VERSION,
		deleted, batches, cursor,
		reachedEnd: ranOutOfCandidates,
		aborted,
		affectedMismatch,
		oldest: oldest ? new Date(oldest).toISOString() : null,
		newest: newest ? new Date(newest).toISOString() : null,
		elapsedSec: Math.round((Date.now() - started) / 1000),
		nextRun: ranOutOfCandidates
			? '本轮已扫到末尾；下一轮会自动从最早处重新扫描（捕捉新到期的帖）'
			: `下一轮会从状态文件的游标 ${cursor} 继续（STATE_FILE=${cfg.stateFile || '未设置，将从最早处重扫'}）`,
	};
	log('info', 'finish', summary);
	print(JSON.stringify(summary));
	await ds.destroy();
}

run().then(() => process.exit(0)).catch((e) => die(String(e?.stack ?? e).slice(0, 2000)));
