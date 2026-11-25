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
              '${status.pending} saved change${status.pending == 1 ? '' : 's'} waiting to sync',
              Icons.cloud_upload_outlined,
              KinCareColors.forest
            ),
          OfflineSyncState.syncing => (
              'Syncing saved changes…',
              Icons.sync,
              KinCareColors.forest
            ),
          OfflineSyncState.failed => (
              '${status.failed} change${status.failed == 1 ? '' : 's'} need retry',
              Icons.cloud_queue_outlined,
              KinCareColors.danger
            ),
          OfflineSyncState.conflict => (
              '${status.conflicts} change${status.conflicts == 1 ? '' : 's'} need your review',
              Icons.warning_amber_rounded,
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
              if (status.conflicts > 0)
                TextButton(
                    onPressed: () => _reviewConflicts(context, service),
                    child: const Text('Review')),
            ]),
          ),
        );
      },
    );
  }
}

Future<void> _reviewConflicts(
    BuildContext context, OfflineSyncService service) async {
  final ownerId = Supabase.instance.client.auth.currentUser?.id;
  if (ownerId == null) return;
  final conflicts = await service.store.conflicts(ownerId);
  for (final conflict in conflicts) {
    if (!context.mounted) return;
    final local = Map<String, dynamic>.from(conflict['local_payload'] as Map);
    final remote = Map<String, dynamic>.from(conflict['remote_payload'] as Map);
    final localLabel = _conflictSummary(local);
    final remoteLabel = remote['_remote_deleted'] == true
        ? 'The cloud record was deleted.'
        : _conflictSummary(remote);
    final keepLocal = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Review saved changes'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('On this device: $localLabel'),
              const SizedBox(height: 12),
              Text('In KinCare cloud: $remoteLabel'),
              const SizedBox(height: 12),
              const Text('Choose which version to keep.'),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, null),
              child: const Text('Later')),
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Use cloud version')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Keep this device version')),
        ],
      ),
    );
    if (keepLocal == null) return;
    await service.store.resolveConflict(ownerId,
        conflict['entity_type'].toString(), conflict['entity_id'].toString(),
        keepLocal: keepLocal);
  }
  await service.refresh();
  if (service.snapshot.pending > 0) {
    await service.syncNow(forceRetry: true);
  }
}

String _conflictSummary(Map<String, dynamic> payload) {
  for (final key in [
    'display_name',
    'title',
    'question_text',
    'answer_context'
  ]) {
    final value = payload[key]?.toString().trim();
    if (value != null && value.isNotEmpty) return value;
  }
  if (payload['_remote_deleted'] == true) return 'Deleted';
  return 'Saved version';
}

String _shortTime(String value) {
  final time = DateTime.tryParse(value)?.toLocal();
  if (time == null) return '—';
  final hour = time.hour % 12 == 0 ? 12 : time.hour % 12;
  return '${time.month}/${time.day} $hour:${time.minute.toString().padLeft(2, '0')} ${time.hour < 12 ? 'AM' : 'PM'}';
}
