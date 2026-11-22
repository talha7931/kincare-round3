import { useEffect, useState } from "react";
import { loadReportingData, type ReportingData, type ReportingProfile } from "./engagementReporting";

export function useReportingData(profiles: ReportingProfile[]) {
  const [data, setData] = useState<ReportingData>({ sessions: [], types: {}, responses: {} });
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const profileKey = profiles.map((profile) => profile.id).join(",");

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError("");
    void loadReportingData(profiles).then((result) => {
      if (!cancelled) setData(result);
    }).catch((cause: unknown) => {
      if (!cancelled) setError(cause instanceof Error ? cause.message : "Reporting data could not be loaded.");
    }).finally(() => {
      if (!cancelled) setLoading(false);
    });
    return () => { cancelled = true; };
    // A stable profile key avoids refetching when the parent recreates the same array.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [profileKey]);

  return { ...data, loading, error, reload: () => {
    setLoading(true);
    setError("");
    void loadReportingData(profiles).then(setData).catch((cause: unknown) => setError(cause instanceof Error ? cause.message : "Reporting data could not be loaded.")).finally(() => setLoading(false));
  } };
}
