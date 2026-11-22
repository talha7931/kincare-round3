import { describe, expect, it } from "vitest";
import { calculateEngagementMetrics, elapsedDuration, isoWeekStart, responseSummary, utcDay, type ReportingActivityType, type ReportingSession } from "./engagementReporting";

const types: Record<string, ReportingActivityType> = {
  one: { id: "one", stable_key: "odd_one_out", name: "Odd One Out" },
};
const sessions: ReportingSession[] = [
  { id: "a", elderly_profile_id: "p", activity_type_id: "one", started_at: "2026-01-05T01:00:00Z", completed_at: "2026-01-05T01:12:00Z", status: "completed" },
  { id: "b", elderly_profile_id: "p", activity_type_id: "one", started_at: "2026-01-05T20:00:00Z", completed_at: null, status: "abandoned" },
  { id: "c", elderly_profile_id: "p", activity_type_id: "one", started_at: "2026-01-07T20:00:00Z", completed_at: null, status: "in_progress" },
  { id: "outside", elderly_profile_id: "p", activity_type_id: "one", started_at: "2026-01-08T00:00:00Z", completed_at: null, status: "completed" },
];

describe("engagement reporting contract", () => {
  it("uses UTC dates and inclusive period bounds", () => {
    expect(utcDay("2026-01-06T02:00:00+05:30")).toBe("2026-01-05");
    expect(calculateEngagementMetrics(sessions, "2026-01-05", "2026-01-07", types).totalSessions).toBe(3);
    expect(isoWeekStart("2026-01-07")).toBe("2026-01-05");
  });
  it("excludes in-progress sessions from the finalized completion rate", () => {
    const metrics = calculateEngagementMetrics(sessions, "2026-01-05", "2026-01-07", types);
    expect(metrics.completionRate).toBe(0.5);
    expect(metrics.inProgressSessions).toBe(1);
    expect(metrics.sessionsPerDay).toBe(1);
  });
  it("derives duration only from valid stored timestamps", () => {
    expect(elapsedDuration(sessions[0].started_at, sessions[0].completed_at)).toBe("12 min");
    expect(elapsedDuration(sessions[1].started_at, null)).toBe("Unavailable");
    expect(elapsedDuration("2026-01-06T00:00:00Z", "2026-01-05T00:00:00Z")).toBe("Unavailable");
  });
  it("formats memory responses without assigning a correctness score", () => {
    expect(responseSummary("memory_deck", { activity_type: "memory_deck", response_kind: "audio" })).toBe("Recorded a spoken response");
    expect(responseSummary("memory_deck", { activity_type: "memory_deck", text: "I remember" })).toBe("Shared a text response");
  });
});
