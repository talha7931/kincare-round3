import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_theme.dart';
import 'offline_sync.dart';

class OfflineSyncStatusBar extends StatelessWidget {
  const OfflineSyncStatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    final service = OfflineSyncService(Supabase.instance.client);
    return AnimatedBuilder(
      animation: service,
      builder: (context, _) {
        final status = service.snapshot;
        final (label, icon, color) = switch (status.state) {
          OfflineSyncState.noNetwork => (
              'No network · activity stays on this device',
              Icons.cloud_off_outlined,
              KinCareColors.textMuted
            ),
          OfflineSyncState.noInternet => (
              'Network connected · internet unavailable',
              Icons.cloud_off_outlined,
              KinCareColors.textMuted
            ),
          OfflineSyncState.supabaseUnavailable => (
              'Internet available · KinCare service unreachable',
              Icons.cloud_off_outlined,
              KinCareColors.danger
            ),
          OfflineSyncState.offline => (
              'Offline · activity stays on this device',
              Icons.cloud_off_outlined,
              KinCareColors.textMuted
            ),
          OfflineSyncState.pending => (
              '${status.pending} activity record${status.pending == 1 ? '' : 's'} waiting to sync',
              Icons.cloud_upload_outlined,
              KinCareColors.forest
            ),
          OfflineSyncState.syncing => (
              'Syncing activity…',
              Icons.sync,
              KinCareColors.forest
            ),
          OfflineSyncState.failed => (
              '${status.failed} record${status.failed == 1 ? '' : 's'} need retry',
              Icons.cloud_queue_outlined,
              KinCareColors.danger
            ),
          OfflineSyncState.synchronized => (
              status.lastSyncedAt == null
                  ? 'Online · ready to sync'
                  : 'Online · synced',
              Icons.cloud_done_outlined,
              KinCareColors.forest
            ),
        };
        return Material(
          color: KinCareColors.paleSage,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(label,
                      style: TextStyle(color: color, fontSize: 13))),
              if (status.lastSyncedAt != null &&
                  status.state == OfflineSyncState.synchronized)
                Text('Last sync ${_shortTime(status.lastSyncedAt!)}',
                    style: const TextStyle(
                        fontSize: 12, color: KinCareColors.textMuted)),
              if (status.pending + status.failed > 0)
                TextButton(
                    onPressed: status.state == OfflineSyncState.syncing
                        ? null
                        : () => service.syncNow(forceRetry: true),
                    child: const Text('Sync Now')),
            ]),
          ),
        );
      },
    );
  }
}

String _shortTime(String value) {
  final time = DateTime.tryParse(value)?.toLocal();
  if (time == null) return '—';
  final hour = time.hour % 12 == 0 ? 12 : time.hour % 12;
  return '${time.month}/${time.day} $hour:${time.minute.toString().padLeft(2, '0')} ${time.hour < 12 ? 'AM' : 'PM'}';
}
