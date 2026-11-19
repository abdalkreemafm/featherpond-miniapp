import test from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { createPondService, validateTelegramInitData } from "../server.mjs";

const BOT_TOKEN = "test-bot-token-123:ABC";
const NOW = 1_800_000_000;
function signedInitData(userId, botToken = BOT_TOKEN, timestamp = NOW) {
  const params = new URLSearchParams();
  params.set("query_id", "AAE-test-query");
  params.set("user", JSON.stringify({ id: userId, first_name: "Private Name" }));
  params.set("auth_date", String(timestamp));
  const dataCheckString = [...params.entries()]
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
    .map(([key, value]) => `${key}=${value}`)
    .join("\n");
  const secret = createHmac("sha256", "WebAppData").update(botToken).digest();
  const hash = createHmac("sha256", secret).update(dataCheckString).digest("hex");
  params.set("hash", hash);
  return params.toString();
}

async function launch(t, options = {}) {
  const dataDir = await mkdtemp(path.join(os.tmpdir(), "featherpond-test-"));
  const service = createPondService({
    botToken: BOT_TOKEN,
    dataDir,
    staticDir: path.join(dataDir, "public"),
    webOrigins: ["https://game.example"],
    nowSeconds: () => NOW,
    ...options,
  });
  await new Promise((resolve, reject) => {
    service.server.once("error", reject);
    service.server.listen(0, "127.0.0.1", resolve);
  });
  const address = service.server.address();
  const base = `http://127.0.0.1:${address.port}`;
  t.after(async () => {
    await service.close();
    await rm(dataDir, { recursive: true, force: true });
  });
  return { service, dataDir, base };
}

async function getState(base, userId, extraHeaders = {}) {
  const response = await fetch(`${base}/api/state`, {
    headers: { "X-Telegram-Init-Data": signedInitData(userId), ...extraHeaders },
  });
  return { response, body: await response.json() };
}

async function action(base, userId, input, extraHeaders = {}) {
  const response = await fetch(`${base}/api/action`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Telegram-Init-Data": signedInitData(userId),
      ...extraHeaders,
    },
    body: JSON.stringify(input),
  });
  return { response, body: await response.json() };
}

test("Telegram initData is HMAC-verified and stale sessions are rejected", () => {
  const valid = signedInitData(345678901);
  assert.equal(validateTelegramInitData(valid, BOT_TOKEN, NOW).userId, "345678901");
  assert.throws(() => validateTelegramInitData(valid, "wrong-token", NOW));
  assert.throws(() => validateTelegramInitData(signedInitData(345678901, BOT_TOKEN, NOW - 86401), BOT_TOKEN, NOW));
});

test("first authenticated visit creates a private starter flock and safe public nickname", async (t) => {
  const { base } = await launch(t);
  const { response, body } = await getState(base, 10001);
  assert.equal(response.status, 200);
  assert.equal(body.state.player.coins, 25);
  assert.equal(body.state.player.food, 5);
  assert.equal(body.state.ducks.length, 1);
  assert.equal(body.state.eggs.length, 2);
  assert.equal(body.state.ducks[0].species, "sunny");
  assert.match(body.state.player.nickname, /^ريشة \d+$/);
  assert.equal(JSON.stringify(body.state).includes("10001"), false);
  assert.equal(JSON.stringify(body.state).includes("Private Name"), false);
});

test("action request IDs prevent duplicate feed rewards", async (t) => {
  const { base } = await launch(t);
  const request = { type: "feed", requestId: "feed-once-0001" };
  const first = await action(base, 20001, request);
  const second = await action(base, 20001, request);
  assert.equal(first.response.status, 200);
  assert.equal(second.response.status, 200);
  assert.equal(first.body.state.player.food, 4);
  assert.equal(second.body.state.player.food, 4);
  assert.equal(second.body.state.player.score, 1);
});

test("server-authoritative feed, collect, merge, hatch and task loop", async (t) => {
  const { base } = await launch(t);
  const userId = 30001;
  for (let i = 0; i < 3; i += 1) {
    const result = await action(base, userId, { type: "feed", requestId: `feed-loop-000${i}` });
    assert.equal(result.response.status, 200);
  }
  let stateResult = await getState(base, userId);
  assert.equal(stateResult.body.state.player.readyEggs, 1);
  const collect = await action(base, userId, { type: "collect", requestId: "collect-loop-0001" });
  assert.equal(collect.response.status, 200);
  let eggs = collect.body.state.eggs;
  assert.equal(eggs.length, 3);
  const merge = await action(base, userId, {
    type: "merge",
    requestId: "merge-loop-0001",
    eggIds: [eggs[0].id, eggs[1].id],
  });
  assert.equal(merge.response.status, 200);
  eggs = merge.body.state.eggs;
  assert.deepEqual(eggs.map((egg) => egg.level).sort(), [1, 2]);
  const levelTwo = eggs.find((egg) => egg.level === 2);
  const hatch = await action(base, userId, { type: "hatch", requestId: "hatch-loop-0001", eggId: levelTwo.id });
  assert.equal(hatch.response.status, 200);
  assert.equal(hatch.body.state.ducks.length, 2);
  assert.equal(hatch.body.state.ducks.some((duck) => duck.species === "aqua"), true);
  assert.equal(hatch.body.state.tasks.find((task) => task.id === "feed3").ready, true);
  const claim = await action(base, userId, { type: "claim_task", requestId: "claim-feed-0001", taskId: "feed3" });
  assert.equal(claim.response.status, 200);
  assert.equal(claim.body.state.player.coins, 37);
  const duplicateClaim = await action(base, userId, { type: "claim_task", requestId: "claim-feed-0002", taskId: "feed3" });
  assert.equal(duplicateClaim.response.status, 409);
});

test("co-op offers create one level-2 egg for each player and award both", async (t) => {
  const { base } = await launch(t);
  const ownerId = 40001;
  const friendId = 40002;
  const ownerStart = await getState(base, ownerId);
  const duckId = ownerStart.body.state.ducks[0].id;
  const offerResult = await action(base, ownerId, {
    type: "create_offer",
    requestId: "offer-create-0001",
    duckId,
  });
  assert.equal(offerResult.response.status, 200);
  const friendStart = await getState(base, friendId);
  const offer = friendStart.body.state.offers[0];
  assert.ok(offer);
  const accepted = await action(base, friendId, {
    type: "accept_offer",
    requestId: "offer-accept-0001",
    offerId: offer.id,
  });
  assert.equal(accepted.response.status, 200);
  assert.equal(accepted.body.state.player.coins, 20);
  assert.equal(accepted.body.state.eggs.filter((egg) => egg.level === 2).length, 1);
  const ownerAfter = await getState(base, ownerId);
  assert.equal(ownerAfter.body.state.player.score, 15);
  assert.equal(ownerAfter.body.state.eggs.filter((egg) => egg.level === 2).length, 1);
  const repeated = await action(base, friendId, {
    type: "accept_offer",
    requestId: "offer-accept-0001",
    offerId: offer.id,
  });
  assert.equal(repeated.response.status, 200);
  assert.equal(repeated.body.state.player.coins, 20);
});

test("invalid browser origins and forged initData are rejected", async (t) => {
  const { base } = await launch(t);
  const blockedOrigin = await getState(base, 50001, { Origin: "https://attacker.example" });
  assert.equal(blockedOrigin.response.status, 403);
  const forged = await fetch(`${base}/api/state`, {
    headers: { "X-Telegram-Init-Data": signedInitData(50001).replace(/hash=[^&]+/, "hash=" + "0".repeat(64)) },
  });
  assert.equal(forged.status, 401);
});
