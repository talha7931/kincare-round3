const DATABASE = "kincare-offline-v1";
const VERSION = 1;
const TABLES = ["profiles", "decks", "cards", "media", "devices", "sessions", "responses", "outbox", "meta"] as const;

export type OfflineProfile = { id: string; display_name: string; preferred_language: string; caregiver_id?: string };
export type LocalSession = {
  id: string;
  caregiver_id: string;
  elderly_profile_id: string;
  activity_key: string;
  activity_type_id: string | null;
  device_id: string | null;
  memory_deck_id: string | null;
  started_at: string;
  completed_at: string | null;
  status: "in_progress" | "completed" | "abandoned";
  sync_state: "pending" | "synced" | "failed";
};
export type LocalResponse = {
  id: string;
  session_id: string;
  caregiver_id: string;
  response_index: number;
  response_payload: Record<string, unknown>;
  is_correct: boolean | null;
  responded_at: string;
  sync_state: "pending" | "synced" | "failed";
};
export type OutboxEntry = {
  id: string;
  kind: "session" | "response";
  record_id: string;
  caregiver_id: string;
  state: "pending" | "syncing" | "failed" | "synced";
  attempts: number;
  next_retry_at: string | null;
  last_error: string | null;
  updated_at: string;
};

let databasePromise: Promise<IDBDatabase> | null = null;
function database(): Promise<IDBDatabase> {
  if (!("indexedDB" in window)) return Promise.reject(new Error("This browser does not support offline storage."));
  databasePromise ??= new Promise((resolve, reject) => {
    const request = indexedDB.open(DATABASE, VERSION);
    request.onupgradeneeded = () => {
      const db = request.result;
      for (const table of TABLES) {
        if (db.objectStoreNames.contains(table)) continue;
        const keyPath = table === "sessions" || table === "responses" || table === "outbox" ? "id" : "key";
        const store = db.createObjectStore(table, { keyPath });
        if (table === "outbox") {
          store.createIndex("owner-state", ["caregiver_id", "state"]);
          store.createIndex("owner-retry", ["caregiver_id", "next_retry_at"]);
        }
        if (table === "sessions") store.createIndex("owner-profile", ["caregiver_id", "elderly_profile_id"]);
        if (table === "responses") store.createIndex("session", "session_id");
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error("Offline database could not be opened."));
    request.onblocked = () => reject(new Error("Offline database upgrade is blocked by another open KinCare tab."));
  });
  return databasePromise;
}

function requestValue<T>(request: IDBRequest<T>) {
  return new Promise<T>((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error("Offline storage request failed."));
  });
}

function transactionDone(transaction: IDBTransaction) {
  return new Promise<void>((resolve, reject) => {
    transaction.oncomplete = () => resolve();
    transaction.onabort = () => reject(transaction.error ?? new Error("Offline storage transaction was interrupted."));
    transaction.onerror = () => reject(transaction.error ?? new Error("Offline storage transaction failed."));
  });
}

const ownerKey = (owner: string, id: string) => `${owner}:${id}`;

export async function persistBrowserStorage() {
  try { return await navigator.storage?.persist?.() ?? false; } catch { return false; }
}

export async function cacheProfiles(owner: string, profiles: OfflineProfile[]) {
  const db = await database(); const tx = db.transaction("profiles", "readwrite"); const store = tx.objectStore("profiles");
  const oldRows = await requestValue<(OfflineProfile & { key: IDBValidKey; caregiver_id: string })[]>(store.getAll());
  for (const old of oldRows) if (old.caregiver_id === owner) store.delete(old.key);
  for (const profile of profiles) store.put({ key: ownerKey(owner, profile.id), caregiver_id: owner, ...profile, cached_at: new Date().toISOString() });
  await transactionDone(tx);
}
export async function readProfiles(owner: string): Promise<OfflineProfile[]> {
  const db = await database(); const tx = db.transaction("profiles", "readonly");
  const rows = await requestValue<(OfflineProfile & { caregiver_id: string })[]>(tx.objectStore("profiles").getAll()); await transactionDone(tx);
  return rows.filter((row) => row.caregiver_id === owner);
}

export async function cacheDeck(owner: string, profileId: string, deck: Record<string, unknown>, cards: Record<string, unknown>[]) {
  const db = await database(); const tx = db.transaction(["decks", "cards"], "readwrite"); const decks = tx.objectStore("decks"); const cardStore = tx.objectStore("cards");
  const id = String(deck.id);
  decks.put({ key: ownerKey(owner, id), caregiver_id: owner, elderly_profile_id: profileId, payload: deck, cached_at: new Date().toISOString() });
  const oldCards = await requestValue<{ key: string; deck_id: string; caregiver_id: string }[]>(cardStore.getAll());
  for (const old of oldCards) if (old.caregiver_id === owner && old.deck_id === id) cardStore.delete(old.key);
  for (const card of cards) cardStore.put({ key: ownerKey(owner, String(card.id)), caregiver_id: owner, deck_id: id, payload: card, cached_at: new Date().toISOString() });
  await transactionDone(tx);
}
export async function cacheDeckMetadata(owner: string, profileId: string, deck: Record<string, unknown>) {
  const db = await database(); const tx = db.transaction("decks", "readwrite");
  tx.objectStore("decks").put({ key: ownerKey(owner, String(deck.id)), caregiver_id: owner, elderly_profile_id: profileId, payload: deck, cached_at: new Date().toISOString() });
  await transactionDone(tx);
}
export async function readDecks(owner: string, profileId: string): Promise<Record<string, unknown>[]> {
  const db = await database(); const tx = db.transaction("decks", "readonly");
  const rows = await requestValue<{ caregiver_id: string; elderly_profile_id: string; payload: Record<string, unknown> }[]>(tx.objectStore("decks").getAll()); await transactionDone(tx);
  return rows.filter((row) => row.caregiver_id === owner && row.elderly_profile_id === profileId).map((row) => row.payload);
}
export async function readCards(owner: string, deckId: string): Promise<Record<string, unknown>[]> {
  const db = await database(); const tx = db.transaction("cards", "readonly");
  const rows = await requestValue<{ caregiver_id: string; deck_id: string; payload: Record<string, unknown> }[]>(tx.objectStore("cards").getAll()); await transactionDone(tx);
  return rows.filter((row) => row.caregiver_id === owner && row.deck_id === deckId).map((row) => row.payload).sort((a, b) => Number(a.display_order ?? 0) - Number(b.display_order ?? 0));
}

export async function cacheMedia(owner: string, assetId: string, blob: Blob, storagePath: string, mimeType: string | null) {
  const db = await database(); const tx = db.transaction("media", "readwrite");
  tx.objectStore("media").put({ key: ownerKey(owner, assetId), caregiver_id: owner, asset_id: assetId, blob, storage_path: storagePath, mime_type: mimeType, cached_at: new Date().toISOString() });
  await transactionDone(tx);
}
export async function readMedia(owner: string, assetId: string): Promise<Blob | null> {
  const db = await database(); const tx = db.transaction("media", "readonly");
  const row = await requestValue<{ caregiver_id: string; blob: Blob } | undefined>(tx.objectStore("media").get(ownerKey(owner, assetId))); await transactionDone(tx);
  return row?.caregiver_id === owner ? row.blob : null;
}

export async function cacheDevice(owner: string, deviceUuid: string, deviceId: string, revokedAt: string | null) {
  const db = await database(); const tx = db.transaction("devices", "readwrite");
  tx.objectStore("devices").put({ key: ownerKey(owner, deviceUuid), caregiver_id: owner, device_uuid: deviceUuid, device_id: deviceId, revoked_at: revokedAt });
  await transactionDone(tx);
}
export async function readDevice(owner: string, deviceUuid: string) {
  const db = await database(); const tx = db.transaction("devices", "readonly");
  const row = await requestValue<{ caregiver_id: string; device_id: string; revoked_at: string | null } | undefined>(tx.objectStore("devices").get(ownerKey(owner, deviceUuid))); await transactionDone(tx);
  return row?.caregiver_id === owner ? row : null;
}

async function enqueue(tx: IDBTransaction, entry: OutboxEntry) {
  tx.objectStore("outbox").put(entry);
}
export async function createLocalSession(session: LocalSession) {
  const db = await database(); const tx = db.transaction(["sessions", "outbox"], "readwrite");
  tx.objectStore("sessions").add(session);
  await enqueue(tx, { id: `session:${session.id}`, kind: "session", record_id: session.id, caregiver_id: session.caregiver_id, state: "pending", attempts: 0, next_retry_at: null, last_error: null, updated_at: new Date().toISOString() });
  await transactionDone(tx);
}
export async function saveLocalResponses(sessionId: string, owner: string, responses: LocalResponse[]) {
  const db = await database(); const tx = db.transaction(["sessions", "responses", "outbox"], "readwrite");
  const session = await requestValue<LocalSession | undefined>(tx.objectStore("sessions").get(sessionId));
  if (!session || session.caregiver_id !== owner) { tx.abort(); throw new Error("Activity session is not available for this caregiver."); }
  const responseStore = tx.objectStore("responses"); const outbox = tx.objectStore("outbox");
  for (const response of responses) {
    const existing = await requestValue<LocalResponse | undefined>(responseStore.get(response.id));
    if (existing && (existing.session_id !== sessionId || existing.caregiver_id !== owner)) { tx.abort(); throw new Error("Response identifier conflicts with another saved activity."); }
    if (!existing) responseStore.add(response);
    outbox.put({ id: `response:${response.id}`, kind: "response", record_id: response.id, caregiver_id: owner, state: "pending", attempts: 0, next_retry_at: null, last_error: null, updated_at: new Date().toISOString() } satisfies OutboxEntry);
  }
  await transactionDone(tx);
}
export async function finishLocalSession(sessionId: string, status: "completed" | "abandoned", completedAt: string | null) {
  const db = await database(); const tx = db.transaction(["sessions", "outbox"], "readwrite"); const sessions = tx.objectStore("sessions");
  const session = await requestValue<LocalSession | undefined>(sessions.get(sessionId));
  if (!session) { tx.abort(); throw new Error("Activity session was not found locally."); }
  if (session.status !== "in_progress" && session.status !== status) { tx.abort(); throw new Error("A finalized activity cannot be changed to a different outcome."); }
  sessions.put({ ...session, status, completed_at: completedAt, sync_state: session.sync_state === "synced" ? "pending" : session.sync_state });
  tx.objectStore("outbox").put({ id: `session:${session.id}`, kind: "session", record_id: session.id, caregiver_id: session.caregiver_id, state: "pending", attempts: 0, next_retry_at: null, last_error: null, updated_at: new Date().toISOString() } satisfies OutboxEntry);
  await transactionDone(tx);
}

export async function nextOutbox(owner: string, force: boolean): Promise<OutboxEntry[]> {
  const db = await database(); const tx = db.transaction("outbox", "readonly");
  const rows = await requestValue<OutboxEntry[]>(tx.objectStore("outbox").getAll()); await transactionDone(tx);
  return rows.filter((row) => row.caregiver_id === owner && row.state !== "synced" && (force || !row.next_retry_at || row.next_retry_at <= new Date().toISOString())).sort((a, b) => (a.kind === b.kind ? a.updated_at.localeCompare(b.updated_at) : a.kind === "session" ? -1 : 1));
}
export async function readLocalSession(id: string) { const db = await database(); const tx = db.transaction("sessions", "readonly"); const row = await requestValue<LocalSession | undefined>(tx.objectStore("sessions").get(id)); await transactionDone(tx); return row ?? null; }
export async function readLocalResponse(id: string) { const db = await database(); const tx = db.transaction("responses", "readonly"); const row = await requestValue<LocalResponse | undefined>(tx.objectStore("responses").get(id)); await transactionDone(tx); return row ?? null; }
export async function readLocalSessions(owner: string, profileIds: string[]) { const db = await database(); const tx = db.transaction("sessions", "readonly"); const rows = await requestValue<LocalSession[]>(tx.objectStore("sessions").getAll()); await transactionDone(tx); return rows.filter((row) => row.caregiver_id === owner && profileIds.includes(row.elderly_profile_id)); }
export async function readLocalResponses(sessionId: string) { const db = await database(); const tx = db.transaction("responses", "readonly"); const rows = await requestValue<LocalResponse[]>(tx.objectStore("responses").getAll()); await transactionDone(tx); return rows.filter((row) => row.session_id === sessionId).sort((a, b) => a.response_index - b.response_index); }

export async function setOutboxState(entry: OutboxEntry, state: OutboxEntry["state"], error?: string, expectedSession?: Pick<LocalSession, "status" | "completed_at">): Promise<boolean> {
  const db = await database(); const tx = db.transaction(["outbox", "sessions", "responses"], "readwrite"); const outbox = tx.objectStore("outbox");
  if (entry.kind === "session") {
    const session = await requestValue<LocalSession | undefined>(tx.objectStore("sessions").get(entry.record_id));
    if (state === "synced" && expectedSession && (!session || session.status !== expectedSession.status || session.completed_at !== expectedSession.completed_at)) {
      outbox.put({ ...entry, state: "pending", attempts: 0, next_retry_at: null, last_error: null, updated_at: new Date().toISOString() });
      if (session) tx.objectStore("sessions").put({ ...session, sync_state: "pending" });
      await transactionDone(tx);
      return false;
    }
  }
  if (state === "failed") {
    const attempts = entry.attempts + 1; const delay = [2, 5, 15, 30, 60][Math.min(attempts, 5) - 1];
    outbox.put({ ...entry, state, attempts, last_error: error ?? "Synchronization failed.", next_retry_at: new Date(Date.now() + delay * 60_000).toISOString(), updated_at: new Date().toISOString() });
  } else {
    outbox.put({ ...entry, state, attempts: state === "pending" ? 0 : entry.attempts, last_error: null, next_retry_at: null, updated_at: new Date().toISOString() });
  }
  if (entry.kind === "session") {
    const session = await requestValue<LocalSession | undefined>(tx.objectStore("sessions").get(entry.record_id));
    if (session) tx.objectStore("sessions").put({ ...session, sync_state: state === "synced" ? "synced" : state === "failed" ? "failed" : "pending" });
  } else {
    const response = await requestValue<LocalResponse | undefined>(tx.objectStore("responses").get(entry.record_id));
    if (response) tx.objectStore("responses").put({ ...response, sync_state: state === "synced" ? "synced" : state === "failed" ? "failed" : "pending" });
  }
  await transactionDone(tx);
  return true;
}
export async function outboxCounts(owner: string) {
  const db = await database(); const tx = db.transaction("outbox", "readonly"); const rows = await requestValue<OutboxEntry[]>(tx.objectStore("outbox").getAll()); await transactionDone(tx);
  const active = rows.filter((row) => row.caregiver_id === owner && row.state !== "synced");
  return { pending: active.filter((row) => row.state === "pending" || row.state === "syncing").length, failed: active.filter((row) => row.state === "failed").length };
}
export async function setLastSynced(owner: string) { const db = await database(); const tx = db.transaction("meta", "readwrite"); tx.objectStore("meta").put({ key: owner, last_synced_at: new Date().toISOString() }); await transactionDone(tx); }
export async function getLastSynced(owner: string) { const db = await database(); const tx = db.transaction("meta", "readonly"); const row = await requestValue<{ last_synced_at: string } | undefined>(tx.objectStore("meta").get(owner)); await transactionDone(tx); return row?.last_synced_at ?? null; }

/** Remove cached caregiver content on sign-out while retaining unsynced activity. */
export async function clearSyncedCache(owner: string) {
  const db = await database();
  const tx = db.transaction(TABLES, "readwrite");
  const all = async <T>(table: typeof TABLES[number]) => requestValue<T[]>(tx.objectStore(table).getAll());
  const [profiles, decks, cards, media, devices, sessions, responses, outbox] = await Promise.all([
    all<{ caregiver_id: string; key: IDBValidKey }>("profiles"),
    all<{ caregiver_id: string; key: IDBValidKey }>("decks"),
    all<{ caregiver_id: string; key: IDBValidKey }>("cards"),
    all<{ caregiver_id: string; key: IDBValidKey }>("media"),
    all<{ caregiver_id: string; key: IDBValidKey }>("devices"),
    all<LocalSession>("sessions"),
    all<LocalResponse>("responses"),
    all<OutboxEntry>("outbox"),
  ]);
  const pendingSessions = new Set(outbox.filter((row) => row.caregiver_id === owner && row.state !== "synced" && row.kind === "session").map((row) => row.record_id));
  for (const row of outbox.filter((entry) => entry.caregiver_id === owner && entry.state !== "synced" && entry.kind === "response")) {
    const response = responses.find((item) => item.id === row.record_id && item.caregiver_id === owner);
    if (response) pendingSessions.add(response.session_id);
  }
  const sessionStore = tx.objectStore("sessions");
  const responseStore = tx.objectStore("responses");
  for (const session of sessions.filter((row) => row.caregiver_id === owner && row.sync_state === "synced" && !pendingSessions.has(row.id))) {
    sessionStore.delete(session.id);
    for (const response of responses) if (response.session_id === session.id) responseStore.delete(response.id);
  }
  const outboxStore = tx.objectStore("outbox");
  for (const row of outbox.filter((entry) => entry.caregiver_id === owner && entry.state === "synced")) outboxStore.delete(row.id);
  for (const [table, rows] of [["profiles", profiles], ["decks", decks], ["cards", cards], ["media", media], ["devices", devices]] as const) {
    const store = tx.objectStore(table);
    for (const row of rows) if (row.caregiver_id === owner) store.delete(row.key);
  }
  tx.objectStore("meta").delete(owner);
  await transactionDone(tx);
}
