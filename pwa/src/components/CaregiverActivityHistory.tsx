import { useEffect, useState } from "react";
import { supabase } from "../lib/supabase";

type Profile = { id: string; display_name: string };
type Session = {
  id: string;
  elderly_profile_id: string;
  activity_type_id: string;
  started_at: string;
  completed_at: string | null;
  status: string;
};
type ActivityType = { id: string; name: string };
type ResponseRow = { session_id: string; response_index: number; response_payload: Record<string, unknown> };

export function CaregiverActivityHistory({ profiles }: { profiles: Profile[] }) {
  const [sessions, setSessions] = useState<Session[]>([]);
  const [types, setTypes] = useState<Record<string, string>>({});
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
      try {
        const { data: rows, error: sessionError } = await supabase
          .from("activity_sessions")
          .select("id, elderly_profile_id, activity_type_id, started_at, completed_at, status")
          .in("elderly_profile_id", profiles.map((profile) => profile.id))
          .order("started_at", { ascending: false })
          .limit(100);
        if (sessionError) throw sessionError;
        const loadedSessions = (rows ?? []) as Session[];
        const typeIds = [...new Set(loadedSessions.map((row) => row.activity_type_id))];
        const sessionIds = loadedSessions.map((row) => row.id);
        const [typeResult, responseResult] = await Promise.all([
          typeIds.length
            ? supabase.from("activity_types").select("id, name").in("id", typeIds)
            : Promise.resolve({ data: [], error: null }),
          sessionIds.length
            ? supabase.from("activity_responses").select("session_id, response_index, response_payload").in("session_id", sessionIds).order("response_index")
            : Promise.resolve({ data: [], error: null }),
        ]);
        if (typeResult.error) throw typeResult.error;
        if (responseResult.error) throw responseResult.error;
        const typeMap: Record<string, string> = {};
        (typeResult.data as ActivityType[] | null)?.forEach((row) => { typeMap[row.id] = row.name; });
        const grouped: Record<string, ResponseRow[]> = {};
        (responseResult.data as ResponseRow[] | null)?.forEach((row) => {
          (grouped[row.session_id] ??= []).push(row);
        });
        if (!cancelled) {
          setSessions(loadedSessions);
          setTypes(typeMap);
          setResponses(grouped);
        }
      } catch (cause) {
        if (!cancelled) setError(cause instanceof Error ? cause.message : "Activity history could not be loaded.");
      } finally {
        if (!cancelled) setLoading(false);
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
                <h3>{types[session.activity_type_id] ?? "Activity"}</h3>
                <p><strong>Profile:</strong> {profileNames[session.elderly_profile_id] ?? "Profile"}</p>
                <p><strong>Started:</strong> {new Date(session.started_at).toLocaleString()}</p>
                <p><strong>Status:</strong> {session.status === "completed" ? "Completed" : session.status === "abandoned" ? "Stopped early" : "In progress"}</p>
                {(responses[session.id] ?? []).map((response) => {
                  const payload = response.response_payload;
                  const description = payload.activity_type === "odd_one_out"
                    ? `Round ${response.response_index + 1}: selected ${String(payload.selected_item_id ?? "item")}`
                    : `${String(payload.item_id ?? "Object")} placed in ${String(payload.selected_category_id ?? "a group")}`;
                  return <p className="activity-response-summary" key={`${session.id}-${response.response_index}`}>{description}</p>;
                })}
              </article>
            ))}
          </div>}
    </section>
  );
}
