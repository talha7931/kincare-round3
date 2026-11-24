import { useEffect, useState } from "react";
import { initializeOfflineSync, subscribeSyncStatus, syncNow, type SyncSnapshot } from "../lib/offlineSync";

const initial: SyncSnapshot = { state: navigator.onLine ? "online" : "offline", pending: 0, failed: 0, lastSyncedAt: null };

export function SyncStatusBar({ caregiverId }: { caregiverId: string }) {
  const [status, setStatus] = useState(initial);
  useEffect(() => {
    const unsubscribe = subscribeSyncStatus(setStatus);
    void initializeOfflineSync(caregiverId);
    return () => { unsubscribe(); };
  }, [caregiverId]);

  const message = status.state === "offline"
    ? "Offline · new activity is saved on this device"
    : status.state === "syncing"
      ? "Syncing activity…"
      : status.state === "failed"
        ? `${status.failed} record${status.failed === 1 ? " needs" : "s need"} attention`
        : status.state === "pending"
          ? `${status.pending} activity record${status.pending === 1 ? "" : "s"} waiting to sync`
          : status.lastSyncedAt
            ? `Online · synced ${new Date(status.lastSyncedAt).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}`
            : "Online · ready to sync";
  const icon = status.state === "offline" ? "☁︎" : status.state === "failed" ? "⚠" : status.state === "syncing" ? "↻" : "✓";

  return <div className={`sync-status sync-status--${status.state}`} role="status" aria-live="polite">
    <span aria-hidden="true">{icon}</span><span>{message}</span>
    {status.state !== "offline" && (status.pending + status.failed > 0) && <button type="button" className="btn btn-quiet" disabled={status.state === "syncing"} onClick={() => void syncNow(true)}>Sync Now</button>}
  </div>;
}
