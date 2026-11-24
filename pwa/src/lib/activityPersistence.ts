import { supabase } from "./supabase";
import { cacheDevice, createLocalSession, readDevice, readProfiles, saveLocalResponses, finishLocalSession } from "./offlineDb";
import { notifyOfflineQueueChanged } from "./offlineSync";

const DEVICE_UUID_KEY = "kincare.device_uuid";

function isNetworkFailure(error: unknown) {
  const status = typeof error === "object" && error !== null && "status" in error ? Number((error as { status?: unknown }).status) : null;
  if (status !== null && status > 0) return false;
  const message = error instanceof Error ? error.message : String(error);
  return /fetch|network|connection|timeout|offline/i.test(message);
}

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
  const { data: authData } = await supabase.auth.getSession();
  const caregiverId = authData.session?.user.id;
  if (!caregiverId) throw new Error("Sign in again before starting an activity.");
  if (!navigator.onLine) {
    const profiles = await readProfiles(caregiverId);
    if (!profiles.some((profile) => profile.id === profileId)) throw new Error("This profile has not been saved on this device for offline use.");
  }

  let deviceUuid = window.localStorage.getItem(DEVICE_UUID_KEY);
  if (!deviceUuid) {
    deviceUuid = window.crypto.randomUUID();
    window.localStorage.setItem(DEVICE_UUID_KEY, deviceUuid);
  }

  let deviceId: string | null = null;
  const cachedDevice = await readDevice(caregiverId, deviceUuid);
  if (navigator.onLine) {
    try {
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
        .select("id, revoked_at")
        .single();
      if (deviceError) throw deviceError;
      if (device.revoked_at) throw new Error("This device has been revoked.");
      deviceId = device.id;
      await cacheDevice(caregiverId, deviceUuid, device.id, null);
    } catch (error) {
      if (!isNetworkFailure(error) || !cachedDevice || cachedDevice.revoked_at) throw error;
      deviceId = cachedDevice.device_id;
    }
  } else {
    if (!cachedDevice || cachedDevice.revoked_at) {
      throw new Error("Connect this device to KinCare once before using activities offline.");
    }
    deviceId = cachedDevice.device_id;
  }

  let activityTypeId: string | null = null;
  if (navigator.onLine) {
    const { data: activity, error: activityError } = await supabase
      .from("activity_types")
      .select("id")
      .eq("stable_key", activityKey)
      .maybeSingle();
    if (!activityError) activityTypeId = activity?.id ?? null;
  }
  const sessionId = window.crypto.randomUUID();
  await createLocalSession({
    id: sessionId,
    caregiver_id: caregiverId,
    elderly_profile_id: profileId,
    activity_key: activityKey,
    activity_type_id: activityTypeId,
    device_id: deviceId,
    memory_deck_id: null,
    started_at: new Date().toISOString(),
    completed_at: null,
    status: "in_progress",
    sync_state: "pending",
  });
  void notifyOfflineQueueChanged();
  return sessionId;
}

export async function saveActivityResponses(
  sessionId: string,
  responses: ActivityResponseInput[],
) {
  if (responses.length === 0) return;
  const { data } = await supabase.auth.getSession();
  const caregiverId = data.session?.user.id;
  if (!caregiverId) throw new Error("The saved caregiver account is not available on this device.");
  await saveLocalResponses(sessionId, caregiverId, responses.map((response) => ({
    id: response.id,
    session_id: sessionId,
    caregiver_id: caregiverId,
    response_index: response.responseIndex,
    response_payload: response.payload,
    is_correct: response.isCorrect,
    responded_at: new Date().toISOString(),
    sync_state: "pending",
  })));
  void notifyOfflineQueueChanged();
}

export async function completeActivitySession(sessionId: string) {
  await finishLocalSession(sessionId, "completed", new Date().toISOString());
  void notifyOfflineQueueChanged();
}

export async function abandonActivitySession(sessionId: string) {
  await finishLocalSession(sessionId, "abandoned", null);
  void notifyOfflineQueueChanged();
}
