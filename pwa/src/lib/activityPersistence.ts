import { supabase } from "./supabase";

const DEVICE_UUID_KEY = "kincare.device_uuid";

export type ActivityResponseInput = {
  id: string;
  responseIndex: number;
  payload: Record<string, unknown>;
  isCorrect: boolean;
};

export async function startActivitySession(
  profileId: string,
  activityKey: "odd_one_out" | "everyday_object_sorting",
) {
  const { data: authData, error: authError } = await supabase.auth.getUser();
  if (authError) throw authError;
  const caregiverId = authData.user?.id;
  if (!caregiverId) throw new Error("Sign in again before starting an activity.");

  let deviceUuid = window.localStorage.getItem(DEVICE_UUID_KEY);
  if (!deviceUuid) {
    deviceUuid = window.crypto.randomUUID();
    window.localStorage.setItem(DEVICE_UUID_KEY, deviceUuid);
  }

  const { data: device, error: deviceError } = await supabase
    .from("enrolled_devices")
    .upsert(
      {
        caregiver_id: caregiverId,
        device_uuid: deviceUuid,
        device_name: "KinCare PWA device",
        last_seen_at: new Date().toISOString(),
      },
      { onConflict: "caregiver_id,device_uuid" },
    )
    .select("id")
    .single();
  if (deviceError) throw deviceError;

  const { data: activity, error: activityError } = await supabase
    .from("activity_types")
    .select("id")
    .eq("stable_key", activityKey)
    .single();
  if (activityError) throw activityError;

  const sessionId = window.crypto.randomUUID();
  const { error: sessionError } = await supabase.from("activity_sessions").insert({
    id: sessionId,
    elderly_profile_id: profileId,
    activity_type_id: activity.id,
    device_id: device.id,
    status: "in_progress",
  });
  if (sessionError) throw sessionError;
  return sessionId;
}

export async function saveActivityResponses(
  sessionId: string,
  responses: ActivityResponseInput[],
) {
  if (responses.length === 0) return;

  const ids = responses.map((response) => response.id);
  const { data: existing, error: lookupError } = await supabase
    .from("activity_responses")
    .select("id")
    .in("id", ids);
  if (lookupError) throw lookupError;
  const existingIds = new Set((existing ?? []).map((row) => row.id as string));
  const missing = responses.filter((response) => !existingIds.has(response.id));
  if (missing.length === 0) return;

  const rows = missing.map((response) => ({
    id: response.id,
    session_id: sessionId,
    response_index: response.responseIndex,
    response_payload: response.payload,
    is_correct: response.isCorrect,
    responded_at: new Date().toISOString(),
  }));
  const { error: insertError } = await supabase.from("activity_responses").insert(rows);
  if (!insertError) return;

  // The request may have reached Supabase before the connection failed. Confirm
  // stable IDs before asking the user to retry, preserving append-only history.
  const { data: confirmed, error: confirmError } = await supabase
    .from("activity_responses")
    .select("id")
    .in("id", ids);
  if (confirmError) throw insertError;
  const confirmedIds = new Set((confirmed ?? []).map((row) => row.id as string));
  if (ids.some((id) => !confirmedIds.has(id))) throw insertError;
}

export async function completeActivitySession(sessionId: string) {
  const { error } = await supabase
    .from("activity_sessions")
    .update({ status: "completed", completed_at: new Date().toISOString() })
    .eq("id", sessionId);
  if (error) throw error;
}
