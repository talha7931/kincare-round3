import { useMemo, useState } from "react";
import { calculateEngagementMetrics, elapsedDuration, formatUtcTimestamp, responseSummary, statusLabel, utcDay, type ReportingProfile } from "../lib/engagementReporting";
import { useReportingData } from "../lib/useReportingData";

const TODAY_UTC = utcDay(new Date());
const THIRTY_DAYS_AGO_UTC = (() => { const date = new Date(`${TODAY_UTC}T00:00:00Z`); date.setUTCDate(date.getUTCDate() - 29); return utcDay(date); })();

export function CaregiverReport({ profiles, caregiverName, initialProfileId }: {
  profiles: ReportingProfile[];
  caregiverName: string;
  initialProfileId?: string | null;
}) {
  const { sessions, types, responses, loading, error, reload } = useReportingData(profiles);
  const [profileId, setProfileId] = useState(initialProfileId && profiles.some((profile) => profile.id === initialProfileId) ? initialProfileId : profiles[0]?.id ?? "");
  const [endDay, setEndDay] = useState(TODAY_UTC);
  const [startDay, setStartDay] = useState(THIRTY_DAYS_AGO_UTC);
  const [notes, setNotes] = useState("");
  const profile = profiles.find((item) => item.id === profileId);
  const profileSessions = sessions.filter((session) => session.elderly_profile_id === profileId);
  const metrics = useMemo(() => calculateEngagementMetrics(profileSessions, startDay, endDay, types), [profileSessions, startDay, endDay, types]);
  const inPeriod = profileSessions.filter((session) => { const day = utcDay(session.started_at); return day >= startDay && day <= endDay; });

  function printReport() {
    document.body.classList.add("reporting-print-mode");
    const cleanUp = () => document.body.classList.remove("reporting-print-mode");
    window.addEventListener("afterprint", cleanUp, { once: true });
    window.print();
    window.setTimeout(cleanUp, 1500);
  }

  return <section className="caregiver-report reporting-report" aria-label="Individual engagement report">
    <div className="reporting-heading reporting-no-print"><div><h2>Individual engagement report</h2><p>Prepare and save a factual summary for one elderly profile.</p></div><button type="button" className="btn btn-quiet" onClick={() => void reload()}>Refresh</button></div>
    {!profiles.length ? <p className="empty-state">Add an elderly profile to prepare a report.</p> : <>
      <div className="reporting-controls reporting-no-print"><label>Elderly profile<select value={profileId} onChange={(event) => setProfileId(event.target.value)}>{profiles.map((item) => <option value={item.id} key={item.id}>{item.display_name}</option>)}</select></label><label>From (UTC)<input type="date" value={startDay} max={endDay} onChange={(event) => { if (event.target.value) setStartDay(event.target.value); }} /></label><label>To (UTC)<input type="date" value={endDay} min={startDay} onChange={(event) => { if (event.target.value) setEndDay(event.target.value); }} /></label><button type="button" className="btn btn-quiet" onClick={() => { const end = utcDay(new Date()); const start = new Date(`${end}T00:00:00Z`); start.setUTCDate(start.getUTCDate() - 29); setEndDay(end); setStartDay(utcDay(start)); }}>Last 30 days</button></div>
      {error ? <div className="reporting-error reporting-no-print" role="alert">Report data could not be loaded: {error}</div> : loading ? <p role="status" className="reporting-no-print">Loading synced activity…</p> : <>
        <div className="reporting-print-title"><h1>KinCare caregiver activity report</h1><p>Prepared {TODAY_UTC} UTC</p></div>
        <article className="content-panel report-summary"><h3>{profile?.display_name ?? "Profile"}</h3><p>Caregiver: {caregiverName || "Not available"}</p><p>Reporting period: {startDay} to {endDay} UTC</p><p>Coverage: synced cloud activity visible to this caregiver under existing access policies.</p>
          <div className="reporting-metrics"><Metric label="Sessions" value={metrics.totalSessions} /><Metric label="Completed" value={metrics.completedSessions} /><Metric label="Stopped early" value={metrics.abandonedSessions} /><Metric label="In progress" value={metrics.inProgressSessions} /></div>
          <p>Completion rate among finalized sessions: {metrics.completionRate == null ? "Unavailable" : `${Math.round(metrics.completionRate * 100)}%`} (completed ÷ completed and stopped early).</p><p>Participation days: {metrics.participationDays} of {metrics.periodDays} calendar days. Session frequency: {metrics.sessionsPerDay.toFixed(2)} sessions per calendar day.</p>
          <h3>Activity type breakdown</h3>{Object.entries(metrics.sessionsByActivity).length ? Object.entries(metrics.sessionsByActivity).map(([name, count]) => <p className="reporting-line" key={name}><span>{name}</span><strong>{count}</strong></p>) : <p>No activity was recorded in this period.</p>}
          <h3>Daily engagement (UTC)</h3>{Object.entries(metrics.sessionsByDay).sort(([a], [b]) => a.localeCompare(b)).map(([day, count]) => <p className="reporting-line" key={day}><span>{day}</span><strong>{count} session{count === 1 ? "" : "s"}</strong></p>)}{!Object.keys(metrics.sessionsByDay).length && <p>No participation days in this period.</p>}
          <h3>Weekly engagement (ISO week, Monday–Sunday UTC)</h3>{Object.entries(metrics.sessionsByWeek).sort(([a], [b]) => a.localeCompare(b)).map(([week, count]) => <p className="reporting-line" key={week}><span>Week of {week}</span><strong>{count} session{count === 1 ? "" : "s"}</strong></p>)}{!Object.keys(metrics.sessionsByWeek).length && <p>No weekly activity in this period.</p>}
        </article>
        <article className="content-panel report-history"><h3>Activity history</h3>{inPeriod.length ? inPeriod.map((session) => <section className="report-session" key={session.id}><h4>{types[session.activity_type_id]?.name ?? "Activity"}</h4><p>{formatUtcTimestamp(session.started_at)} · {statusLabel(session.status)} · Duration: {elapsedDuration(session.started_at, session.completed_at)}</p>{(responses[session.id] ?? []).length ? (responses[session.id] ?? []).map((response) => <p key={`${session.id}-${response.response_index}`}>Response {response.response_index + 1}: {responseSummary(types[session.activity_type_id]?.stable_key ?? "", response.response_payload)}</p>) : <p>No response details were recorded.</p>}</section>) : <p>No sessions are available for this profile and reporting period.</p>}</article>
        <label className="report-notes reporting-no-print">Caregiver observations (optional; included only in this export)<textarea value={notes} onChange={(event) => setNotes(event.target.value)} rows={4} /></label>
        {notes.trim() && <article className="content-panel report-notes-print"><h3>Caregiver observations</h3><p>{notes}</p></article>}
        <p className="reporting-disclaimer">This report summarizes recorded engagement only. It is not a clinical diagnosis or medical assessment.</p>
        <div className="reporting-no-print"><button type="button" className="btn btn-primary" onClick={printReport}>Print or save as PDF</button></div>
      </>}
    </>}
  </section>;
}

function Metric({ label, value }: { label: string; value: string | number }) { return <article className="reporting-metric"><span>{label}</span><strong>{value}</strong></article>; }
