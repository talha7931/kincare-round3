import { supabase } from "./supabase";
import {
  getLastSynced,
  nextOutbox,
  outboxCounts,
  readLocalResponse,
  readLocalSession,
  setLastSynced,
  setOutboxState,
  type OutboxEntry,
} from "./offlineDb";

export type SyncState = "online" | "offline" | "pending" | "syncing" | "failed";
export type SyncSnapshot = { state: SyncState; pending: number; failed: number; lastSyncedAt: string | null };
const listeners = new Set<(snapshot: SyncSnapshot) => void>();
let ownerId: string | null = null;
let online = typeof navigator === "undefined" ? false : navigator.onLine;
let syncing = false;
let pending = 0;
let failed = 0;
let lastSyncedAt: string | null = null;
let started = false;
let syncGeneration = 0;

function snapshot(): SyncSnapshot {
  return { state: syncing ? "syncing" : !online ? "offline" : failed ? "failed" : pending ? "pending" : "online", pending, failed, lastSyncedAt };
}
function emit() { const value = snapshot(); for (const listener of listeners) listener(value); }
async function refresh() {
  if (!ownerId) return;
  const [counts, last] = await Promise.all([outboxCounts(ownerId), getLastSynced(ownerId)]);
  pending = counts.pending; failed = counts.failed; lastSyncedAt = last; emit();
}

export function subscribeSyncStatus(listener: (value: SyncSnapshot) => void) {
  listeners.add(listener); listener(snapshot());
  return () => listeners.delete(listener);
}

export async function initializeOfflineSync(caregiverId: string) {
  ownerId = caregiverId;
  if (navigator.storage?.persist) void navigator.storage.persist().catch(() => false);
  if (!started) {
    started = true;
    window.addEventListener("online", () => { online = true; emit(); void syncNow(false); });
    window.addEventListener("offline", () => { online = false; emit(); void refresh(); });
    document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible") void syncNow(false); });
  }
  online = navigator.onLine;
  await refresh();
  if (online) await syncNow(false);
}

export async function notifyOfflineQueueChanged() {
  await refresh();
  if (online) void syncNow(false);
}

export function stopOfflineSync(owner: string) {
  if (ownerId !== owner) return;
  ownerId = null;
  syncGeneration++;
  emit();
}

export async function syncNow(forceRetry = true) {
  const owner = ownerId;
  const generation = syncGeneration;
  if (!owner || syncing) return;
  online = navigator.onLine;
  if (!online) { await refresh(); return; }
  try {
    const { data: sessionResult, error } = await supabase.auth.getSession();
    if (error || sessionResult.session?.user.id !== owner) { await refresh(); return; }
  } catch {
    await refresh();
    return;
  }
  syncing = true; emit();
  let failedDuringRun = false;
  try {
    const entries = await nextOutbox(owner, forceRetry);
    for (const entry of entries) {
      if (generation !== syncGeneration) break;
      await setOutboxState(entry, "syncing");
      try {
        const sessionSnapshot = entry.kind === "session" ? await readLocalSession(entry.record_id) : null;
        if (entry.kind === "session") await syncSession(owner, entry.record_id);
        else await syncResponse(owner, entry.record_id);
        if (generation !== syncGeneration) break;
        await setOutboxState(entry, "synced", undefined, sessionSnapshot ?? undefined);
      } catch (error) {
        if (generation !== syncGeneration) break;
        failedDuringRun = true;
        await setOutboxState(entry, "failed", error instanceof Error ? error.message : String(error));
      }
    }
    const counts = await outboxCounts(owner);
    if (!failedDuringRun && counts.pending === 0 && counts.failed === 0) {
      await setLastSynced(owner);
      lastSyncedAt = await getLastSynced(owner);
    }
  } finally {
    syncing = false;
    await refresh();
  }
}

async function syncSession(owner: string, id: string) {
  const row = await readLocalSession(id);
  if (!row || row.caregiver_id !== owner) throw new Error("Local session belongs to another caregiver.");
  if (!row.device_id) throw new Error("This device has not been enrolled online yet; the session remains on this device.");
  const { data: profile, error: profileError } = await supabase.from("elderly_profiles").select("id").eq("id", row.elderly_profile_id).maybeSingle();
  if (profileError) throw profileError;
  if (!profile) throw new Error("The selected profile is not available to this caregiver. The local session is retained.");
  const { data: device, error: deviceError } = await supabase.from("enrolled_devices").select("id, revoked_at").eq("id", row.device_id).maybeSingle();
  if (deviceError) throw deviceError;
  if (!device || device.revoked_at) throw new Error("This enrolled device was revoked or is no longer available. The local session is retained.");
  let activityTypeId = row.activity_type_id;
  if (!activityTypeId) {
    const { data: activity, error } = await supabase.from("activity_types").select("id").eq("stable_key", row.activity_key).single();
    if (error) throw error;
    activityTypeId = activity.id;
  }
  const { data: existing, error: existingError } = await supabase.from("activity_sessions").select("id, elderly_profile_id, device_id, status, completed_at").eq("id", id).maybeSingle();
  if (existingError) throw existingError;
  if (existing) {
    if (existing.elderly_profile_id !== row.elderly_profile_id || existing.device_id !== row.device_id) throw new Error("Session identifier collision; remote data was not changed.");
    if (existing.status === "completed" || existing.status === "abandoned") {
      if (row.status !== "in_progress" && row.status !== existing.status) throw new Error("Local and server session final states conflict; the local record is retained.");
      return;
    }
    if (row.status !== "in_progress") {
      const { error } = await supabase.from("activity_sessions").update({ status: row.status, completed_at: row.completed_at }).eq("id", id);
      if (error) throw error;
    }
    return;
  }
  const { error } = await supabase.from("activity_sessions").insert({
    id: row.id,
    elderly_profile_id: row.elderly_profile_id,
    activity_type_id: activityTypeId,
    device_id: row.device_id,
    memory_deck_id: row.memory_deck_id,
    started_at: row.started_at,
    completed_at: row.completed_at,
    status: row.status,
  });
  if (error) {
    const { data: confirmed, error: confirmError } = await supabase.from("activity_sessions").select("id, elderly_profile_id, device_id").eq("id", id).maybeSingle();
    if (confirmError || !confirmed || confirmed.elderly_profile_id !== row.elderly_profile_id || confirmed.device_id !== row.device_id) throw error;
  }
}

async function syncResponse(owner: string, id: string) {
  const row = await readLocalResponse(id);
  if (!row || row.caregiver_id !== owner) throw new Error("Local response belongs to another caregiver.");
  const { data: parent, error: parentError } = await supabase.from("activity_sessions").select("id").eq("id", row.session_id).maybeSingle();
  if (parentError) throw parentError;
  if (!parent) throw new Error("The parent activity session has not synced yet.");
  const { data: existing, error: existingError } = await supabase.from("activity_responses").select("id, session_id").eq("id", id).maybeSingle();
  if (existingError) throw existingError;
  if (existing) {
    if (existing.session_id !== row.session_id) throw new Error("Response identifier collision; remote data was not changed.");
    return;
  }
  const insert = {
    id: row.id,
    session_id: row.session_id,
    response_index: row.response_index,
    response_payload: row.response_payload,
    is_correct: row.is_correct,
    responded_at: row.responded_at,
  };
  const { error } = await supabase.from("activity_responses").insert(insert);
  if (error) {
    const { data: confirmed, error: confirmError } = await supabase.from("activity_responses").select("id, session_id").eq("id", id).maybeSingle();
    if (confirmError || !confirmed || confirmed.session_id !== row.session_id) throw error;
  }
}

export async function responseSyncFailure(entry: OutboxEntry, message: string) {
  await setOutboxState(entry, "failed", message);
  await refresh();
}
