import { supabase } from "./supabase";

export type ReportingProfile = { id: string; display_name: string };

export type ReportingSession = {
  id: string;
  elderly_profile_id: string;
  activity_type_id: string;
  started_at: string;
  completed_at: string | null;
  status: string;
};

export type ReportingResponse = {
  session_id: string;
  response_index: number;
  response_payload: Record<string, unknown>;
  is_correct?: boolean | null;
};

export type ReportingActivityType = { id: string; stable_key: string; name: string };

export type ReportingData = {
  sessions: ReportingSession[];
  types: Record<string, ReportingActivityType>;
  responses: Record<string, ReportingResponse[]>;
};

export function statusLabel(status: string): string {
  return status === "completed" ? "Completed" : status === "abandoned" ? "Stopped early" : status === "in_progress" ? "In progress" : "Status unavailable";
}

export async function loadReportingData(profiles: ReportingProfile[]): Promise<ReportingData> {
  if (!profiles.length) return { sessions: [], types: {}, responses: {} };
  const { data: typeRows, error: typeError } = await supabase
    .from("activity_types")
    .select("id, stable_key, name");
  if (typeError) throw typeError;
  const types = Object.fromEntries(((typeRows ?? []) as ReportingActivityType[]).map((type) => [type.id, type]));
  const sessions: ReportingSession[] = [];
  const profileIds = profiles.map((profile) => profile.id);
  for (let start = 0; ; start += 500) {
    const { data, error } = await supabase
      .from("activity_sessions")
      .select("id, elderly_profile_id, activity_type_id, started_at, completed_at, status")
      .in("elderly_profile_id", profileIds)
      .order("started_at", { ascending: false })
      .range(start, start + 499);
    if (error) throw error;
    const page = (data ?? []) as ReportingSession[];
    sessions.push(...page);
    if (page.length < 500) break;
  }
  const responses: Record<string, ReportingResponse[]> = {};
  for (let start = 0; start < sessions.length; start += 100) {
    const ids = sessions.slice(start, start + 100).map((session) => session.id);
    const { data, error } = await supabase
      .from("activity_responses")
      .select("session_id, response_index, response_payload, is_correct")
      .in("session_id", ids)
      .order("response_index");
    if (error) throw error;
    for (const response of (data ?? []) as ReportingResponse[]) {
      (responses[response.session_id] ??= []).push(response);
    }
  }
  return { sessions, types, responses };
}

export type EngagementMetrics = {
  totalSessions: number;
  completedSessions: number;
  abandonedSessions: number;
  inProgressSessions: number;
  participationDays: number;
  periodDays: number;
  completionRate: number | null;
  sessionsPerDay: number;
  sessionsByActivity: Record<string, number>;
  sessionsByDay: Record<string, number>;
  sessionsByWeek: Record<string, number>;
};

export function utcDay(value: string | Date): string {
  const date = value instanceof Date ? value : new Date(value);
  return `${date.getUTCFullYear()}-${String(date.getUTCMonth() + 1).padStart(2, "0")}-${String(date.getUTCDate()).padStart(2, "0")}`;
}

export function formatUtcTimestamp(value: string): string {
  return `${new Intl.DateTimeFormat("en-GB", { dateStyle: "medium", timeStyle: "short", timeZone: "UTC" }).format(new Date(value))} UTC`;
}

export function isoWeekStart(day: string): string {
  const date = new Date(`${day}T00:00:00.000Z`);
  date.setUTCDate(date.getUTCDate() - ((date.getUTCDay() + 6) % 7));
  return utcDay(date);
}

export function calculateEngagementMetrics(
  source: ReportingSession[],
  startDay: string,
  endDay: string,
  types: Record<string, ReportingActivityType>,
): EngagementMetrics {
  const sessions = source.filter((session) => {
    const day = utcDay(session.started_at);
    return day >= startDay && day <= endDay;
  });
  const completedSessions = sessions.filter((row) => row.status === "completed").length;
  const abandonedSessions = sessions.filter((row) => row.status === "abandoned").length;
  const inProgressSessions = sessions.filter((row) => row.status === "in_progress").length;
  const sessionsByActivity: Record<string, number> = {};
  const sessionsByDay: Record<string, number> = {};
  const sessionsByWeek: Record<string, number> = {};
  for (const session of sessions) {
    const name = types[session.activity_type_id]?.name ?? "Activity";
    const day = utcDay(session.started_at);
    const week = isoWeekStart(day);
    sessionsByActivity[name] = (sessionsByActivity[name] ?? 0) + 1;
    sessionsByDay[day] = (sessionsByDay[day] ?? 0) + 1;
    sessionsByWeek[week] = (sessionsByWeek[week] ?? 0) + 1;
  }
  const periodDays = Math.max(1, Math.round((Date.parse(`${endDay}T00:00:00Z`) - Date.parse(`${startDay}T00:00:00Z`)) / 86_400_000) + 1);
  const finalized = completedSessions + abandonedSessions;
  return {
    totalSessions: sessions.length,
    completedSessions,
    abandonedSessions,
    inProgressSessions,
    participationDays: Object.keys(sessionsByDay).length,
    periodDays,
    completionRate: finalized ? completedSessions / finalized : null,
    sessionsPerDay: sessions.length / periodDays,
    sessionsByActivity,
    sessionsByDay,
    sessionsByWeek,
  };
}

export function responseSummary(activityKey: string, payload: Record<string, unknown>): string {
  const kind = String(payload.activity_type ?? activityKey);
  if (kind === "odd_one_out") {
    return `Selected ${String(payload.selected_item_id ?? "item")}`;
  }
  if (kind === "everyday_object_sorting") {
    return `${String(payload.item_id ?? "Object")} placed in ${String(payload.selected_category_id ?? "a group")}`;
  }
  if (kind === "memory_deck") {
    const text = typeof payload.text === "string" ? payload.text.trim() : "";
    if (text) return "Shared a text response";
    return payload.response_kind === "audio" ? "Recorded a spoken response" : "Response recorded";
  }
  return "Response recorded";
}

export function elapsedDuration(startedAt: string, completedAt: string | null): string {
  if (!completedAt) return "Unavailable";
  const elapsed = Date.parse(completedAt) - Date.parse(startedAt);
  if (!Number.isFinite(elapsed) || elapsed < 0) return "Unavailable";
  const minutes = Math.floor(elapsed / 60_000);
  if (minutes === 0) return "Under 1 minute";
  if (minutes < 60) return `${minutes} min`;
  const hours = Math.floor(minutes / 60);
  return minutes % 60 ? `${hours} hr ${minutes % 60} min` : `${hours} hr`;
}
