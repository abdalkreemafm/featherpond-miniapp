import http from "node:http";
import { createHmac, randomUUID, timingSafeEqual, randomInt } from "node:crypto";
import { createReadStream } from "node:fs";
import { mkdir, realpath, stat } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { DatabaseSync } from "node:sqlite";

const MAX_BODY_BYTES = 16 * 1024;
const AUTH_MAX_AGE_SECONDS = 24 * 60 * 60;
const AUTH_FUTURE_SKEW_SECONDS = 60;
const OFFER_LIFETIME_SECONDS = 24 * 60 * 60;
const TASKS = [
  { id: "feed3", title: "أطعم البط 3 مرات", target: 3, reward: 12, field: "feeds" },
  { id: "collect1", title: "اجمع بيضة واحدة", target: 1, reward: 8, field: "collects" },
  { id: "merge1", title: "ادمج بيضتين", target: 1, reward: 12, field: "merges" },
  { id: "hatch1", title: "فقّس بطة جديدة", target: 1, reward: 15, field: "hatches" },
];
const MIME_TYPES = new Map([
  [".html", "text/html; charset=utf-8"],
  [".js", "text/javascript; charset=utf-8"],
  [".mjs", "text/javascript; charset=utf-8"],
  [".css", "text/css; charset=utf-8"],
  [".json", "application/json; charset=utf-8"],
  [".wasm", "application/wasm"],
  [".png", "image/png"],
  [".jpg", "image/jpeg"],
  [".jpeg", "image/jpeg"],
  [".svg", "image/svg+xml"],
  [".ico", "image/x-icon"],
  [".woff2", "font/woff2"],
  [".pck", "application/octet-stream"],
  [".zip", "application/zip"],
]);

class HttpError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

export function validateTelegramInitData(rawInitData, botToken, nowSeconds = Math.floor(Date.now() / 1000)) {
  if (!botToken) throw new HttpError(503, "telegram_auth_not_configured", "لم يُضبط رمز البوت على الخادم.");
  if (typeof rawInitData !== "string" || rawInitData.length < 1 || rawInitData.length > 8192) {
    throw new HttpError(401, "telegram_init_data_missing", "افتح اللعبة من Telegram للتحقق من الجلسة.");
  }

  const params = new URLSearchParams(rawInitData.startsWith("?") ? rawInitData.slice(1) : rawInitData);
  const entries = [];
  const seen = new Set();
  for (const [key, value] of params.entries()) {
    if (seen.has(key)) throw new HttpError(401, "telegram_init_data_duplicate", "بيانات جلسة Telegram غير صالحة.");
    seen.add(key);
    entries.push([key, value]);
  }

  const suppliedHash = params.get("hash");
  if (!suppliedHash || !/^[a-f0-9]{64}$/i.test(suppliedHash)) {
    throw new HttpError(401, "telegram_init_data_invalid", "تعذّر التحقق من جلسة Telegram.");
  }
  const dataCheckString = entries
    .filter(([key]) => key !== "hash")
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
    .map(([key, value]) => `${key}=${value}`)
    .join("\n");
  const secretKey = createHmac("sha256", "WebAppData").update(botToken).digest();
  const expectedHash = createHmac("sha256", secretKey).update(dataCheckString).digest();
  const actualHash = Buffer.from(suppliedHash, "hex");
  if (actualHash.length !== expectedHash.length || !timingSafeEqual(actualHash, expectedHash)) {
    throw new HttpError(401, "telegram_init_data_invalid", "تعذّر التحقق من جلسة Telegram.");
  }

  const authDateText = params.get("auth_date") ?? "";
  if (!/^\d{1,12}$/.test(authDateText)) throw new HttpError(401, "telegram_auth_date_invalid", "انتهت صلاحية جلسة Telegram.");
  const authDate = Number(authDateText);
  const age = nowSeconds - authDate;
  if (age > AUTH_MAX_AGE_SECONDS || age < -AUTH_FUTURE_SKEW_SECONDS) {
    throw new HttpError(401, "telegram_auth_date_expired", "انتهت صلاحية جلسة Telegram؛ أعد فتح اللعبة.");
  }

  let user;
  try {
    user = JSON.parse(params.get("user") ?? "null");
  } catch {
    throw new HttpError(401, "telegram_user_invalid", "بيانات لاعب Telegram غير صالحة.");
  }
  const rawId = user?.id;
  const userId = typeof rawId === "number" && Number.isSafeInteger(rawId) && rawId > 0
    ? String(rawId)
    : typeof rawId === "string" && /^\d{1,20}$/.test(rawId) && rawId !== "0"
      ? rawId
      : "";
  if (!userId) throw new HttpError(401, "telegram_user_invalid", "تعذّر تحديد لاعب Telegram.");
  return { userId, authDate };
}

function createDatabase(databasePath) {
  const db = new DatabaseSync(databasePath);
  db.exec("PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL; PRAGMA busy_timeout = 5000;");
  db.exec(`
    CREATE TABLE IF NOT EXISTS players (
      user_id TEXT PRIMARY KEY,
      nickname TEXT NOT NULL,
      coins INTEGER NOT NULL DEFAULT 25 CHECK(coins >= 0),
      food INTEGER NOT NULL DEFAULT 5 CHECK(food >= 0 AND food <= 12),
      feed_progress INTEGER NOT NULL DEFAULT 0 CHECK(feed_progress >= 0),
      ready_eggs INTEGER NOT NULL DEFAULT 0 CHECK(ready_eggs >= 0 AND ready_eggs <= 9),
      score INTEGER NOT NULL DEFAULT 0 CHECK(score >= 0),
      created_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS ducks (
      id TEXT PRIMARY KEY,
      owner_id TEXT NOT NULL REFERENCES players(user_id) ON DELETE CASCADE,
      species TEXT NOT NULL CHECK(species IN ('sunny','aqua','lilac')),
      name TEXT NOT NULL,
      created_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS eggs (
      id TEXT PRIMARY KEY,
      owner_id TEXT NOT NULL REFERENCES players(user_id) ON DELETE CASCADE,
      level INTEGER NOT NULL CHECK(level BETWEEN 1 AND 4),
      created_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS daily_stats (
      user_id TEXT NOT NULL REFERENCES players(user_id) ON DELETE CASCADE,
      day TEXT NOT NULL,
      feeds INTEGER NOT NULL DEFAULT 0 CHECK(feeds >= 0),
      collects INTEGER NOT NULL DEFAULT 0 CHECK(collects >= 0),
      merges INTEGER NOT NULL DEFAULT 0 CHECK(merges >= 0),
      hatches INTEGER NOT NULL DEFAULT 0 CHECK(hatches >= 0),
      coops INTEGER NOT NULL DEFAULT 0 CHECK(coops >= 0),
      claimed_tasks TEXT NOT NULL DEFAULT '[]',
      PRIMARY KEY(user_id, day)
    );
    CREATE TABLE IF NOT EXISTS offers (
      id TEXT PRIMARY KEY,
      owner_id TEXT NOT NULL REFERENCES players(user_id) ON DELETE CASCADE,
      duck_id TEXT NOT NULL REFERENCES ducks(id) ON DELETE CASCADE,
      species TEXT NOT NULL CHECK(species IN ('sunny','aqua','lilac')),
      status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','accepted','expired')),
      created_at INTEGER NOT NULL,
      expires_at INTEGER NOT NULL,
      accepted_by TEXT REFERENCES players(user_id),
      accepted_at INTEGER
    );
    CREATE TABLE IF NOT EXISTS idempotency (
      user_id TEXT NOT NULL REFERENCES players(user_id) ON DELETE CASCADE,
      request_id TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      PRIMARY KEY(user_id, request_id)
    );
    CREATE INDEX IF NOT EXISTS idx_ducks_owner ON ducks(owner_id);
    CREATE INDEX IF NOT EXISTS idx_eggs_owner ON eggs(owner_id);
    CREATE INDEX IF NOT EXISTS idx_offers_open ON offers(status, expires_at, owner_id);
    CREATE INDEX IF NOT EXISTS idx_players_score ON players(score DESC, created_at ASC);
  `);
  return db;
}

function dailyKey(nowSeconds) {
  return new Date(nowSeconds * 1000).toISOString().slice(0, 10);
}

function speciesName(species) {
  if (species === "aqua") return "موجة";
  if (species === "lilac") return "ليلك";
  return "شمسة";
}

function speciesForLevel(level) {
  if (level <= 1) return "sunny";
  if (level === 2) return "aqua";
  return "lilac";
}

function asId(value, fieldName) {
  if (typeof value !== "string" || value.length < 1 || value.length > 80) {
    throw new HttpError(400, "invalid_input", `قيمة ${fieldName} غير صالحة.`);
  }
  return value;
}

function parseJsonBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        reject(new HttpError(413, "body_too_large", "حجم الطلب أكبر من المسموح."));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => {
      try {
        const text = Buffer.concat(chunks).toString("utf8");
        const value = JSON.parse(text || "{}");
        if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("not_object");
        resolve(value);
      } catch {
        reject(new HttpError(400, "invalid_json", "بيانات الطلب غير صالحة."));
      }
    });
    req.on("error", (error) => reject(error));
  });
}

function createRateLimiter(limit = 120, windowMs = 60_000) {
  const buckets = new Map();
  return (key) => {
    const now = Date.now();
    let bucket = buckets.get(key);
    if (!bucket || now - bucket.start >= windowMs) bucket = { start: now, count: 0 };
    bucket.count += 1;
    buckets.set(key, bucket);
    if (buckets.size > 5000) {
      for (const [id, value] of buckets) if (now - value.start >= windowMs) buckets.delete(id);
    }
    return bucket.count <= limit;
  };
}

function writeJson(res, status, value) {
  const payload = Buffer.from(JSON.stringify(value));
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": payload.length,
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
  });
  res.end(payload);
}

function expectedRequestOrigin(req, trustProxy) {
  const forwarded = trustProxy ? String(req.headers["x-forwarded-proto"] ?? "").split(",")[0].trim() : "";
  const protocol = forwarded || (req.socket.encrypted ? "https" : "http");
  const host = String(req.headers.host ?? "");
  if (!host) return "";
  try { return new URL(`${protocol}://${host}`).origin; } catch { return ""; }
}

function applyCors(req, res, allowedOrigins, trustProxy) {
  const origin = typeof req.headers.origin === "string" ? req.headers.origin : "";
  if (origin) {
    const allowed = allowedOrigins.size > 0
      ? allowedOrigins.has(origin)
      : origin === expectedRequestOrigin(req, trustProxy);
    if (!allowed) throw new HttpError(403, "origin_not_allowed", "هذا النطاق غير مسموح له باستخدام الخدمة.");
    res.setHeader("Access-Control-Allow-Origin", origin);
    res.setHeader("Vary", "Origin");
    res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
    res.setHeader("Access-Control-Allow-Headers", "Content-Type, X-Telegram-Init-Data");
    res.setHeader("Access-Control-Max-Age", "600");
  }
  if (req.method === "OPTIONS") {
    res.writeHead(204, { "Cache-Control": "no-store" });
    res.end();
    return true;
  }
  return false;
}

async function serveStatic(req, res, url, staticDir) {
  if (req.method !== "GET" && req.method !== "HEAD") {
    writeJson(res, 405, { error: "method_not_allowed", message: "الطريقة غير مسموحة." });
    return;
  }
  let pathname;
  try { pathname = decodeURIComponent(url.pathname); } catch {
    writeJson(res, 400, { error: "invalid_path", message: "مسار غير صالح." });
    return;
  }
  if (pathname.split("/").some((part) => part.startsWith("."))) {
    writeJson(res, 404, { error: "not_found", message: "الملف غير موجود." });
    return;
  }
  const root = path.resolve(staticDir);
  const relative = pathname.replace(/^\/+/, "") || "index.html";
  let candidate = path.resolve(root, relative);
  if (candidate !== root && !candidate.startsWith(root + path.sep)) {
    writeJson(res, 403, { error: "path_forbidden", message: "المسار غير مسموح." });
    return;
  }
  try {
    const rootReal = await realpath(root);
    let fileInfo = await stat(candidate);
    if (fileInfo.isDirectory()) {
      candidate = path.join(candidate, "index.html");
      fileInfo = await stat(candidate);
    }
    const fileReal = await realpath(candidate);
    if (fileReal !== rootReal && !fileReal.startsWith(rootReal + path.sep)) {
      writeJson(res, 403, { error: "path_forbidden", message: "المسار غير مسموح." });
      return;
    }
    if (!fileInfo.isFile()) throw new Error("not_file");
    const extension = path.extname(fileReal).toLowerCase();
    const headers = {
      "Content-Type": MIME_TYPES.get(extension) ?? "application/octet-stream",
      "Content-Length": fileInfo.size,
      "X-Content-Type-Options": "nosniff",
      "Cache-Control": extension === ".html" ? "no-cache" : "public, max-age=3600",
    };
    res.writeHead(200, headers);
    if (req.method === "HEAD") res.end();
    else createReadStream(fileReal).pipe(res);
  } catch {
    const looksLikeFile = path.extname(pathname) !== "";
    if (!looksLikeFile && pathname !== "/api" && pathname !== "/api/") {
      const fallback = new URL("/", url);
      await serveStatic(req, res, fallback, staticDir);
      return;
    }
    writeJson(res, 404, { error: "not_found", message: "الملف غير موجود." });
  }
}

export function createPondService(options = {}) {
  const botToken = options.botToken ?? process.env.BOT_TOKEN ?? "";
  const dataDir = path.resolve(options.dataDir ?? process.env.DATA_DIR ?? path.join(process.cwd(), "data"));
  const staticDir = path.resolve(options.staticDir ?? process.env.STATIC_DIR ?? path.join(process.cwd(), "public"));
  const webOrigins = options.webOrigins ?? String(process.env.WEB_ORIGINS ?? "").split(",").map((item) => item.trim()).filter(Boolean);
  const allowedOrigins = new Set(webOrigins);
  const botUsername = String(options.botUsername ?? process.env.BOT_USERNAME ?? "").replace(/^@/, "");
  const miniAppShortName = String(options.miniAppShortName ?? process.env.MINI_APP_SHORT_NAME ?? "");
  const trustProxy = String(options.trustProxy ?? process.env.TRUST_PROXY ?? "false") === "true";
  const nowSeconds = options.nowSeconds ?? (() => Math.floor(Date.now() / 1000));
  const allowRequest = createRateLimiter(options.rateLimit ?? 120);
  const inviteUrl = /^[A-Za-z0-9_]{5,32}$/.test(botUsername) && /^[A-Za-z0-9_-]{1,64}$/.test(miniAppShortName)
    ? `https://t.me/${botUsername}/${miniAppShortName}?startapp=pond`
    : null;
  const databasePath = path.join(dataDir, "featherpond.sqlite");
  let db;

  const ready = mkdir(dataDir, { recursive: true }).then(() => {
    db = createDatabase(databasePath);
  });

  function ensureDaily(userId) {
    const day = dailyKey(nowSeconds());
    db.prepare("INSERT OR IGNORE INTO daily_stats (user_id, day) VALUES (?, ?)").run(userId, day);
    return db.prepare("SELECT * FROM daily_stats WHERE user_id = ? AND day = ?").get(userId, day);
  }

  function ensurePlayer(userId) {
    const existing = db.prepare("SELECT user_id FROM players WHERE user_id = ?").get(userId);
    if (existing) {
      ensureDaily(userId);
      return;
    }
    db.exec("BEGIN IMMEDIATE");
    try {
      const recheck = db.prepare("SELECT user_id FROM players WHERE user_id = ?").get(userId);
      if (!recheck) {
        const suffix = randomInt(1000, 10000);
        const nickname = `ريشة ${suffix}`;
        const createdAt = new Date(nowSeconds() * 1000).toISOString();
        db.prepare("INSERT INTO players (user_id, nickname, created_at) VALUES (?, ?, ?)").run(userId, nickname, createdAt);
        db.prepare("INSERT INTO ducks (id, owner_id, species, name, created_at) VALUES (?, ?, 'sunny', 'شمسة', ?)").run(randomUUID(), userId, createdAt);
        const insertEgg = db.prepare("INSERT INTO eggs (id, owner_id, level, created_at) VALUES (?, ?, 1, ?)");
        insertEgg.run(randomUUID(), userId, createdAt);
        insertEgg.run(randomUUID(), userId, createdAt);
      }
      ensureDaily(userId);
      db.exec("COMMIT");
    } catch (error) {
      db.exec("ROLLBACK");
      throw error;
    }
  }

  function buildState(userId) {
    const player = db.prepare("SELECT nickname, coins, food, feed_progress, ready_eggs, score FROM players WHERE user_id = ?").get(userId);
    if (!player) throw new HttpError(404, "player_not_found", "تعذّر تحميل ملف اللاعب.");
    const ducks = db.prepare("SELECT id, species, name FROM ducks WHERE owner_id = ? ORDER BY created_at, id").all(userId)
      .map((row) => ({ id: row.id, species: row.species, name: row.name }));
    const eggs = db.prepare("SELECT id, level FROM eggs WHERE owner_id = ? ORDER BY created_at, id").all(userId)
      .map((row) => ({ id: row.id, level: row.level }));
    const daily = ensureDaily(userId);
    let claimed = [];
    try { claimed = JSON.parse(daily.claimed_tasks || "[]"); } catch { claimed = []; }
    const tasks = TASKS.map((task) => {
      const progress = Number(daily[task.field] ?? 0);
      const wasClaimed = claimed.includes(task.id);
      return {
        id: task.id,
        title: task.title,
        progress,
        target: task.target,
        reward: task.reward,
        claimed: wasClaimed,
        ready: progress >= task.target && !wasClaimed,
      };
    });
    const now = nowSeconds();
    db.prepare("UPDATE offers SET status='expired' WHERE status='open' AND expires_at <= ?").run(now);
    const offers = db.prepare(`
      SELECT o.id, o.species, o.created_at, o.expires_at, p.nickname
      FROM offers o JOIN players p ON p.user_id = o.owner_id
      WHERE o.status = 'open' AND o.expires_at > ? AND o.owner_id <> ?
      ORDER BY o.created_at DESC LIMIT 20
    `).all(now, userId).map((row) => ({
      id: row.id,
      species: row.species,
      nickname: row.nickname,
      createdAt: row.created_at,
      expiresAt: row.expires_at,
    }));
    const leaderboard = db.prepare("SELECT nickname, score FROM players ORDER BY score DESC, created_at ASC LIMIT 10").all()
      .map((row, index) => ({ rank: index + 1, nickname: row.nickname, score: row.score }));
    return {
      player: {
        nickname: player.nickname,
        coins: player.coins,
        food: player.food,
        readyEggs: player.ready_eggs,
        feedProgress: player.feed_progress,
        score: player.score,
        duckCount: ducks.length,
        eggsCount: eggs.length,
      },
      ducks,
      eggs,
      tasks,
      offers,
      leaderboard,
      inviteUrl,
    };
  }

  function incrementDaily(userId, column, count = 1) {
    const allowed = new Set(["feeds", "collects", "merges", "hatches", "coops"]);
    if (!allowed.has(column)) throw new Error("invalid_daily_column");
    const day = dailyKey(nowSeconds());
    db.prepare(`UPDATE daily_stats SET ${column} = ${column} + ? WHERE user_id = ? AND day = ?`).run(count, userId, day);
  }

  function addEggs(ownerId, level, count = 1) {
    const insert = db.prepare("INSERT INTO eggs (id, owner_id, level, created_at) VALUES (?, ?, ?, ?)");
    const createdAt = new Date(nowSeconds() * 1000).toISOString();
    for (let i = 0; i < count; i += 1) insert.run(randomUUID(), ownerId, level, createdAt);
  }

  function executeAction(userId, input) {
    const type = asId(input.type, "type");
    const requestId = asId(input.requestId, "requestId");
    if (!/^[A-Za-z0-9._:-]{8,80}$/.test(requestId)) throw new HttpError(400, "invalid_request_id", "معرّف الإجراء غير صالح.");
    db.exec("BEGIN IMMEDIATE");
    try {
      const duplicate = db.prepare("SELECT 1 FROM idempotency WHERE user_id = ? AND request_id = ?").get(userId, requestId);
      if (duplicate) {
        const state = buildState(userId);
        db.exec("COMMIT");
        return state;
      }
      const profile = () => db.prepare("SELECT coins, food, feed_progress, ready_eggs, score FROM players WHERE user_id = ?").get(userId);
      const addScore = (amount) => db.prepare("UPDATE players SET score = score + ? WHERE user_id = ?").run(amount, userId);
      const createdAt = new Date(nowSeconds() * 1000).toISOString();

      switch (type) {
        case "feed": {
          const p = profile();
          if (p.food < 1) throw new HttpError(409, "not_enough_food", "نفد الطعام. يمكنك شراء 3 وجبات مقابل 15 عملة.");
          let feedProgress = p.feed_progress + 1;
          let readyEggs = p.ready_eggs;
          if (feedProgress >= 2 && readyEggs < 9) {
            feedProgress -= 2;
            readyEggs += 1;
          }
          db.prepare("UPDATE players SET food=food-1, feed_progress=?, ready_eggs=?, score=score+1 WHERE user_id=?").run(feedProgress, readyEggs, userId);
          incrementDaily(userId, "feeds", 1);
          break;
        }
        case "collect": {
          const p = profile();
          const ready = p.ready_eggs;
          if (ready < 1) throw new HttpError(409, "no_ready_eggs", "لا يوجد بيض جاهز للجمع بعد. أطعِم البط أولاً.");
          const currentEggs = Number(db.prepare("SELECT COUNT(*) AS count FROM eggs WHERE owner_id=?").get(userId).count);
          if (currentEggs + ready > 40) throw new HttpError(409, "egg_storage_full", "الحاضنة ممتلئة. ادمج البيض أو فقّسه أولاً.");
          addEggs(userId, 1, ready);
          db.prepare("UPDATE players SET ready_eggs=0, score=score+? WHERE user_id=?").run(ready * 5, userId);
          incrementDaily(userId, "collects", ready);
          break;
        }
        case "merge": {
          if (!Array.isArray(input.eggIds) || input.eggIds.length !== 2 || input.eggIds[0] === input.eggIds[1]) {
            throw new HttpError(400, "invalid_eggs", "اختر بيضتين مختلفتين لدمجهما.");
          }
          const ids = input.eggIds.map((id) => asId(id, "eggId"));
          const find = db.prepare("SELECT id, level FROM eggs WHERE id=? AND owner_id=?");
          const first = find.get(ids[0], userId);
          const second = find.get(ids[1], userId);
          if (!first || !second) throw new HttpError(409, "egg_not_owned", "إحدى البيضتين غير موجودة في حاضنتك.");
          if (first.level !== second.level) throw new HttpError(409, "egg_levels_differ", "يجب اختيار بيضتين من المستوى نفسه.");
          if (first.level >= 4) throw new HttpError(409, "egg_max_level", "وصلت البيضة إلى أعلى مستوى في هذه النسخة.");
          const removed = db.prepare("DELETE FROM eggs WHERE owner_id=? AND id IN (?, ?)").run(userId, ids[0], ids[1]);
          if (removed.changes !== 2) throw new HttpError(409, "egg_changed", "تغيّرت الحاضنة؛ حدّث الحالة وحاول مجدداً.");
          addEggs(userId, first.level + 1, 1);
          addScore(10 * (first.level + 1));
          incrementDaily(userId, "merges", 1);
          break;
        }
        case "hatch": {
          const eggId = asId(input.eggId, "eggId");
          const egg = db.prepare("SELECT id, level FROM eggs WHERE id=? AND owner_id=?").get(eggId, userId);
          if (!egg) throw new HttpError(409, "egg_not_owned", "اختر بيضة موجودة في الحاضنة.");
          db.prepare("DELETE FROM eggs WHERE id=? AND owner_id=?").run(eggId, userId);
          const species = speciesForLevel(egg.level);
          db.prepare("INSERT INTO ducks (id, owner_id, species, name, created_at) VALUES (?, ?, ?, ?, ?)")
            .run(randomUUID(), userId, species, speciesName(species), createdAt);
          addScore(10 * egg.level);
          incrementDaily(userId, "hatches", 1);
          break;
        }
        case "buy_food": {
          const p = profile();
          if (p.coins < 15) throw new HttpError(409, "not_enough_coins", "تحتاج إلى 15 عملة لشراء الطعام. أكمل المهام لكسب المزيد.");
          if (p.food >= 12) throw new HttpError(409, "food_storage_full", "مخزون الطعام ممتلئ حالياً.");
          db.prepare("UPDATE players SET coins=coins-15, food=MIN(12, food+3) WHERE user_id=?").run(userId);
          break;
        }
        case "claim_task": {
          const taskId = asId(input.taskId, "taskId");
          const task = TASKS.find((item) => item.id === taskId);
          if (!task) throw new HttpError(400, "unknown_task", "المهمة غير معروفة.");
          const daily = ensureDaily(userId);
          let claimed = [];
          try { claimed = JSON.parse(daily.claimed_tasks || "[]"); } catch { claimed = []; }
          if (claimed.includes(taskId)) throw new HttpError(409, "task_already_claimed", "سبق استلام مكافأة هذه المهمة اليوم.");
          if (Number(daily[task.field] ?? 0) < task.target) throw new HttpError(409, "task_not_ready", "أكمل متطلبات المهمة أولاً.");
          claimed.push(taskId);
          db.prepare("UPDATE daily_stats SET claimed_tasks=? WHERE user_id=? AND day=?").run(JSON.stringify(claimed), userId, dailyKey(nowSeconds()));
          db.prepare("UPDATE players SET coins=coins+? WHERE user_id=?").run(task.reward, userId);
          break;
        }
        case "create_offer": {
          const duckId = asId(input.duckId, "duckId");
          const duck = db.prepare("SELECT id, species FROM ducks WHERE id=? AND owner_id=?").get(duckId, userId);
          if (!duck) throw new HttpError(409, "duck_not_owned", "البطة المختارة ليست ضمن قطيعك.");
          const now = nowSeconds();
          db.prepare("UPDATE offers SET status='expired' WHERE status='open' AND expires_at <= ?").run(now);
          const openCount = Number(db.prepare("SELECT COUNT(*) AS count FROM offers WHERE owner_id=? AND status='open'").get(userId).count);
          if (openCount >= 3) throw new HttpError(409, "offer_limit", "لديك 3 عروض مفتوحة بالفعل؛ انتظر أو ألغِ عرضاً قديماً.");
          const sameDuck = db.prepare("SELECT 1 FROM offers WHERE duck_id=? AND status='open' AND expires_at>? LIMIT 1").get(duckId, now);
          if (sameDuck) throw new HttpError(409, "offer_exists", "هذه البطة معروضة للتعاون بالفعل.");
          db.prepare("INSERT INTO offers (id, owner_id, duck_id, species, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?)")
            .run(randomUUID(), userId, duckId, duck.species, now, now + OFFER_LIFETIME_SECONDS);
          break;
        }
        case "accept_offer": {
          const offerId = asId(input.offerId, "offerId");
          const now = nowSeconds();
          const offer = db.prepare("SELECT id, owner_id, species, status, expires_at FROM offers WHERE id=?").get(offerId);
          if (!offer || offer.status !== "open" || offer.expires_at <= now) throw new HttpError(409, "offer_unavailable", "انتهى العرض أو لم يعد متاحاً.");
          if (offer.owner_id === userId) throw new HttpError(403, "cannot_accept_own_offer", "لا يمكنك قبول عرضك أنت.");
          const receiver = profile();
          if (receiver.coins < 5) throw new HttpError(409, "not_enough_coins", "تحتاج إلى 5 عملات لقبول التعاون.");
          const ownerEggs = Number(db.prepare("SELECT COUNT(*) AS count FROM eggs WHERE owner_id=?").get(offer.owner_id).count);
          const receiverEggs = Number(db.prepare("SELECT COUNT(*) AS count FROM eggs WHERE owner_id=?").get(userId).count);
          if (ownerEggs >= 40 || receiverEggs >= 40) throw new HttpError(409, "egg_storage_full", "لا يمكن إكمال التعاون لأن إحدى الحاضنتين ممتلئة.");
          const claimed = db.prepare("UPDATE offers SET status='accepted', accepted_by=?, accepted_at=? WHERE id=? AND status='open' AND expires_at>?")
            .run(userId, now, offerId, now);
          if (claimed.changes !== 1) throw new HttpError(409, "offer_unavailable", "سبق أن قبل لاعب آخر هذا العرض.");
          db.prepare("UPDATE players SET coins=coins-5, score=score+15 WHERE user_id=?").run(userId);
          db.prepare("UPDATE players SET score=score+15 WHERE user_id=?").run(offer.owner_id);
          addEggs(userId, 2, 1);
          addEggs(offer.owner_id, 2, 1);
          incrementDaily(userId, "coops", 1);
          incrementDaily(offer.owner_id, "coops", 1);
          break;
        }
        default:
          throw new HttpError(400, "unknown_action", "الإجراء غير معروف.");
      }

      const now = nowSeconds();
      db.prepare("INSERT INTO idempotency (user_id, request_id, created_at) VALUES (?, ?, ?)").run(userId, requestId, now);
      db.prepare("DELETE FROM idempotency WHERE created_at < ?").run(now - 30 * 24 * 60 * 60);
      const state = buildState(userId);
      db.exec("COMMIT");
      return state;
    } catch (error) {
      db.exec("ROLLBACK");
      throw error;
    }
  }

  async function handle(req, res) {
    await ready;
    res.setHeader("X-Content-Type-Options", "nosniff");
    let url;
    try { url = new URL(req.url ?? "/", "http://localhost"); } catch {
      writeJson(res, 400, { error: "invalid_url", message: "عنوان الطلب غير صالح." });
      return;
    }
    if (url.pathname === "/api/health" && req.method === "GET") {
      writeJson(res, 200, { ok: true, service: "featherpond" });
      return;
    }

    if (!url.pathname.startsWith("/api/")) {
      await serveStatic(req, res, url, staticDir);
      return;
    }

    try {
      if (applyCors(req, res, allowedOrigins, trustProxy)) return;
      if (!allowRequest(req.socket.remoteAddress ?? "unknown")) throw new HttpError(429, "rate_limited", "طلبات كثيرة؛ حاول بعد قليل.");
      const rawInitData = req.headers["x-telegram-init-data"];
      const auth = validateTelegramInitData(typeof rawInitData === "string" ? rawInitData : "", botToken, nowSeconds());
      ensurePlayer(auth.userId);

      if (url.pathname === "/api/state" && req.method === "GET") {
        writeJson(res, 200, { state: buildState(auth.userId) });
        return;
      }
      if (url.pathname === "/api/action" && req.method === "POST") {
        const input = await parseJsonBody(req);
        writeJson(res, 200, { state: executeAction(auth.userId, input) });
        return;
      }
      throw new HttpError(404, "not_found", "المسار غير موجود.");
    } catch (error) {
      if (res.headersSent) return;
      if (error instanceof HttpError) {
        writeJson(res, error.status, { error: error.code, message: error.message });
        return;
      }
      console.error("[featherpond] request error", error?.code ?? error?.name ?? "internal_error");
      writeJson(res, 500, { error: "internal_error", message: "حدث خطأ في الخادم. حاول مجدداً لاحقاً." });
    }
  }

  const server = http.createServer((req, res) => {
    handle(req, res).catch((error) => {
      if (!res.headersSent) writeJson(res, 500, { error: "internal_error", message: "حدث خطأ في الخادم." });
      else res.destroy(error);
    });
  });

  return {
    server,
    databasePath,
    close: async () => {
      await ready;
      if (server.listening) await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
      db?.close();
    },
  };
}

const invokedPath = process.argv[1] ? pathToFileURL(path.resolve(process.argv[1])).href : "";
if (import.meta.url === invokedPath) {
  const service = createPondService();
  const port = Number(process.env.PORT ?? 3000);
  const host = process.env.HOST ?? "0.0.0.0";
  service.server.listen(port, host, () => {
    console.log(`[featherpond] listening on ${host}:${port}`);
    if (!process.env.BOT_TOKEN) console.warn("[featherpond] BOT_TOKEN is not set; health works but player API is disabled.");
  });
  const shutdown = async () => {
    await service.close();
    process.exit(0);
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}
