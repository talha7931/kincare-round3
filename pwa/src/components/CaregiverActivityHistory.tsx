import { useEffect, useState } from "react";
import { supabase } from "../lib/supabase";
import { formatUtcTimestamp, responseSummary } from "../lib/engagementReporting";
import { readLocalResponses, readLocalSessions } from "../lib/offlineDb";
import { supabase as supabaseClient } from "../lib/supabase";

type Profile = { id: string; display_name: string };
type Session = {
  id: string;
  elderly_profile_id: string;
  activity_type_id: string;
  started_at: string;
  completed_at: string | null;
  status: string;
  activity_key?: string;
  sync_state?: string;
};
type ActivityType = { id: string; name: string; stable_key: string };
type ResponseRow = { session_id: string; response_index: number; response_payload: Record<string, unknown> };

export function CaregiverActivityHistory({ profiles }: { profiles: Profile[] }) {
  const [sessions, setSessions] = useState<Session[]>([]);
  const [types, setTypes] = useState<Record<string, ActivityType>>({});
  const [responses, setResponses] = useState<Record<string, ResponseRow[]>>({});
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  useEffect(() => {
    let cancelled = false;
    const load = async () => {
      setLoading(true);
      setError("");
      if (profiles.length === 0) {
        setSessions([]);
        setLoading(false);
        return;
      }
      let loadedSessions: Session[] = [];
      const typeMap: Record<string, ActivityType> = {};
      const grouped: Record<string, ResponseRow[]> = {};
      try {
        const { data: rows, error: sessionError } = await supabase
          .from("activity_sessions")
          .select("id, elderly_profile_id, activity_type_id, started_at, completed_at, status")
          .in("elderly_profile_id", profiles.map((profile) => profile.id))
          .order("started_at", { ascending: false })
          .limit(100);
        if (sessionError) throw sessionError;
        loadedSessions = (rows ?? []) as Session[];
        const typeIds = [...new Set(loadedSessions.map((row) => row.activity_type_id))];
        const sessionIds = loadedSessions.map((row) => row.id);
        const [typeResult, responseResult] = await Promise.all([
          typeIds.length
            ? supabase.from("activity_types").select("id, name, stable_key").in("id", typeIds)
            : Promise.resolve({ data: [], error: null }),
          sessionIds.length
            ? supabase.from("activity_responses").select("session_id, response_index, response_payload").in("session_id", sessionIds).order("response_index")
            : Promise.resolve({ data: [], error: null }),
        ]);
        if (typeResult.error) throw typeResult.error;
        if (responseResult.error) throw responseResult.error;
        (typeResult.data as ActivityType[] | null)?.forEach((row) => { typeMap[row.id] = row; });
        (responseResult.data as ResponseRow[] | null)?.forEach((row) => {
          (grouped[row.session_id] ??= []).push(row);
        });
      } catch (cause) {
        if (!cancelled) setError(cause instanceof Error ? cause.message : "Activity history could not be loaded.");
      }
      try {
        const { data: auth } = await supabaseClient.auth.getSession();
        const owner = auth.session?.user.id;
        if (owner) {
          const local = await readLocalSessions(owner, profiles.map((profile) => profile.id));
          const known = new Set(loadedSessions.map((row) => row.id));
          for (const row of local) {
            if (known.has(row.id) && row.sync_state === "synced") continue;
            const localSession: Session = {
              id: row.id,
              elderly_profile_id: row.elderly_profile_id,
              activity_type_id: row.activity_type_id ?? "",
              activity_key: row.activity_key,
              started_at: row.started_at,
              completed_at: row.completed_at,
              status: row.status,
              sync_state: row.sync_state,
            };
            if (!known.has(row.id)) loadedSessions.push(localSession);
            const localResponses = await readLocalResponses(row.id);
            grouped[row.id] = localResponses.map((response) => ({ session_id: row.id, response_index: response.response_index, response_payload: response.response_payload }));
          }
        }
      } catch (cause) {
        if (!cancelled) setError((previous) => previous || (cause instanceof Error ? cause.message : "Local activity could not be loaded."));
      }
      loadedSessions.sort((a, b) => b.started_at.localeCompare(a.started_at));
      if (!cancelled) {
        setSessions(loadedSessions);
        setTypes(typeMap);
        setResponses(grouped);
        setLoading(false);
      }
    };
    void load();
    return () => { cancelled = true; };
  }, [profiles]);

  const profileNames = Object.fromEntries(profiles.map((profile) => [profile.id, profile.display_name]));

  return (
    <section className="content-panel caregiver-activity-history" aria-label="Activity history">
      <h2>Activity history</h2>
      {error && <p className="error" role="alert">{error}</p>}
      {loading ? <p role="status">Loading activity history…</p>
        : sessions.length === 0 ? <p className="empty-state">No activities have been recorded for these profiles yet.</p>
          : <div className="activity-history-list">
            {sessions.map((session) => (
              <article className="activity-history-card" key={session.id}>
                <h3>{types[session.activity_type_id]?.name ?? (session.activity_key === "odd_one_out" ? "Odd One Out" : session.activity_key === "everyday_object_sorting" ? "Everyday Object Sorting" : "Activity")}</h3>
                <p><strong>Profile:</strong> {profileNames[session.elderly_profile_id] ?? "Profile"}</p>
                <p><strong>Started:</strong> {formatUtcTimestamp(session.started_at)}</p>
                <p><strong>Status:</strong> {session.status === "completed" ? "Completed" : session.status === "abandoned" ? "Stopped early" : "In progress"} · {session.sync_state == null || session.sync_state === "synced" ? "Synced" : session.sync_state === "failed" ? "Sync failed" : "Pending sync"}</p>
                {(responses[session.id] ?? []).map((response) => {
                  const payload = response.response_payload;
                  const description = responseSummary(types[session.activity_type_id]?.stable_key ?? session.activity_key ?? "", payload);
                  return <p className="activity-response-summary" key={`${session.id}-${response.response_index}`}>{description}</p>;
                })}
              </article>
            ))}
          </div>}
    </section>
  );
}
