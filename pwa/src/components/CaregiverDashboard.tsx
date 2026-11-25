import { useMemo, useState } from "react";
import { calculateEngagementMetrics, formatUtcTimestamp, statusLabel, utcDay, type ReportingProfile } from "../lib/engagementReporting";
import { useReportingData } from "../lib/useReportingData";

const TODAY_UTC = utcDay(new Date());
const THIRTY_DAYS_AGO_UTC = (() => { const date = new Date(`${TODAY_UTC}T00:00:00Z`); date.setUTCDate(date.getUTCDate() - 29); return utcDay(date); })();

export function CaregiverDashboard({ profiles, caregiverName, onOpenProfileReport }: {
  profiles: ReportingProfile[];
  caregiverName: string;
  onOpenProfileReport: (profileId: string) => void;
}) {
  const { sessions, types, loading, error, reload } = useReportingData(profiles);
  const [endDay, setEndDay] = useState(TODAY_UTC);
  const [startDay, setStartDay] = useState(THIRTY_DAYS_AGO_UTC);
  const metrics = useMemo(() => calculateEngagementMetrics(sessions, startDay, endDay, types), [sessions, startDay, endDay, types]);
  const recent = sessions.filter((session) => {
    const day = utcDay(session.started_at); return day >= startDay && day <= endDay;
  }).slice(0, 8);

  return <section className="reporting-dashboard" aria-label="Caregiver engagement overview">
    <div className="reporting-heading"><div><h2>{caregiverName ? `Welcome, ${caregiverName}` : "Engagement overview"}</h2><p>Factual activity history for the people you support.</p></div><button type="button" className="btn btn-quiet" onClick={() => void reload()}>Refresh</button></div>
    <div className="reporting-period"><strong>Reporting period (UTC)</strong><label>From <input type="date" value={startDay} max={endDay} onChange={(event) => { if (event.target.value) setStartDay(event.target.value); }} /></label><label>To <input type="date" value={endDay} min={startDay} onChange={(event) => { if (event.target.value) setEndDay(event.target.value); }} /></label><button type="button" className="btn btn-quiet" onClick={() => { const end = utcDay(new Date()); const start = new Date(`${end}T00:00:00Z`); start.setUTCDate(start.getUTCDate() - 29); setEndDay(end); setStartDay(utcDay(start)); }}>Last 30 days</button></div>
    {error ? <div className="reporting-error" role="alert">Activity data could not be loaded: {error}</div> : loading ? <p role="status">Loading synced activity…</p> : <>
      <div className="reporting-metrics">
        <Metric label="Elderly profiles" value={profiles.length} />
        <Metric label="Activity sessions" value={metrics.totalSessions} />
        <Metric label="Participation days" value={metrics.participationDays} />
        <Metric label="Completion" value={metrics.completionRate == null ? "—" : `${Math.round(metrics.completionRate * 100)}%`} />
      </div>
      <div className="reporting-grid">
        <article className="content-panel"><h3>Sessions by activity</h3>{Object.keys(metrics.sessionsByActivity).length ? Object.entries(metrics.sessionsByActivity).map(([name, count]) => <p className="reporting-line" key={name}><span>{name}</span><strong>{count}</strong></p>) : <p className="empty-state">No activities were recorded in this period.</p>}<p className="reporting-note">Sessions per calendar day: {metrics.sessionsPerDay.toFixed(2)} ({metrics.totalSessions} sessions ÷ {metrics.periodDays} UTC calendar days)</p></article>
        <article className="content-panel"><h3>Weekly activity (UTC)</h3>{Object.keys(metrics.sessionsByWeek).length ? Object.entries(metrics.sessionsByWeek).sort(([a], [b]) => a.localeCompare(b)).slice(-8).map(([week, count]) => <p className="reporting-line" key={week}><span>Week of {week}</span><strong>{count}</strong></p>) : <p className="empty-state">Weekly activity will appear after sessions are recorded.</p>}</article>
      </div>
      <div className="reporting-grid">
        <article className="content-panel"><h3>People you support</h3>{profiles.length ? profiles.map((profile) => <div className="reporting-line" key={profile.id}><span>{profile.display_name}</span><button type="button" className="btn btn-quiet" onClick={() => onOpenProfileReport(profile.id)}>View report</button></div>) : <p className="empty-state">No elderly profiles have been added.</p>}</article>
        <article className="content-panel"><h3>Recent participation</h3>{recent.length ? recent.map((session) => <button type="button" className="reporting-recent" key={session.id} onClick={() => onOpenProfileReport(session.elderly_profile_id)}><strong>{types[session.activity_type_id]?.name ?? "Activity"}</strong><span>{profiles.find((profile) => profile.id === session.elderly_profile_id)?.display_name ?? "Profile"} · {formatUtcTimestamp(session.started_at)}</span><span>{statusLabel(session.status)}</span></button>) : <p className="empty-state">No activity in this reporting period.</p>}</article>
      </div>
      <p className="reporting-disclaimer">Coverage includes synced activity visible to this caregiver under existing access policies. Dates use UTC. This is an engagement summary, not a clinical assessment.</p>
    </>}
  </section>;
}

function Metric({ label, value }: { label: string; value: string | number }) { return <article className="reporting-metric"><span>{label}</span><strong>{value}</strong></article>; }
