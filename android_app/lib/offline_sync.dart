import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'offline_store.dart';

enum OfflineSyncState {
  noNetwork,
  noInternet,
  supabaseUnavailable,
  offline,
  pending,
  syncing,
  failed,
  synchronized
}

class OfflineSyncSnapshot {
  final OfflineSyncState state;
  final int pending;
  final int failed;
  final String? lastSyncedAt;
  const OfflineSyncSnapshot(
      this.state, this.pending, this.failed, this.lastSyncedAt);
}

class OfflineSyncService extends ChangeNotifier with WidgetsBindingObserver {
  static OfflineSyncService? _shared;
  final SupabaseClient client;
  final OfflineStore store;
  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  String? _ownerId;
  bool _online = true;
  bool _hasNetwork = true;
  bool _internetAvailable = true;
  bool _supabaseReachable = true;
  bool _syncing = false;
  int _pending = 0;
  int _failed = 0;
  String? _lastSyncedAt;
  bool _disposed = false;
  int _syncGeneration = 0;

  factory OfflineSyncService(SupabaseClient client, {OfflineStore? store}) =>
      _shared ??= OfflineSyncService._(client, store ?? OfflineStore.instance);

  OfflineSyncService._(this.client, this.store) {
    WidgetsBinding.instance.addObserver(this);
    _connectivitySubscription =
        _connectivity.onConnectivityChanged.listen((results) {
      _hasNetwork = results.any((result) => result != ConnectivityResult.none);
      if (!_hasNetwork) _internetAvailable = false;
      _online = _hasNetwork && _internetAvailable && _supabaseReachable;
      _refreshStatus();
      if (_hasNetwork) unawaited(syncNow());
    });
  }

  OfflineSyncSnapshot get snapshot => OfflineSyncSnapshot(
        _syncing
            ? OfflineSyncState.syncing
            : !_hasNetwork
                ? OfflineSyncState.noNetwork
                : !_internetAvailable
                    ? OfflineSyncState.noInternet
                    : !_supabaseReachable
                        ? OfflineSyncState.supabaseUnavailable
                        : !_online
                            ? OfflineSyncState.offline
                            : _failed > 0
                                ? OfflineSyncState.failed
                                : _pending > 0
                                    ? OfflineSyncState.pending
                                    : OfflineSyncState.synchronized,
        _pending,
        _failed,
        _lastSyncedAt,
      );

  Future<void> initialize(String ownerId) async {
    if (_ownerId != null && _ownerId != ownerId) _syncGeneration++;
    _ownerId = ownerId;
    try {
      final values = await _connectivity.checkConnectivity();
      _hasNetwork = values.any((result) => result != ConnectivityResult.none);
    } catch (_) {
      // Keep the last measured reachability state; a plugin error is not proof
      // that the network or Supabase is available.
    }
    _lastSyncedAt = await store.lastSyncedAt(ownerId);
    await _refreshStatus();
    if (_hasNetwork) unawaited(syncNow());
  }

  Future<void> refresh() => _refreshStatus();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(syncNow());
  }

  Future<void> _refreshStatus() async {
    final ownerId = _ownerId;
    if (ownerId == null) return;
    final counts = await store.outboxCounts(ownerId);
    _pending = counts['pending'] ?? 0;
    _failed = counts['failed'] ?? 0;
    _lastSyncedAt = await store.lastSyncedAt(ownerId);
    if (!_disposed) notifyListeners();
  }

  Future<void> syncNow({bool forceRetry = false}) async {
    final ownerId = _ownerId;
    final generation = _syncGeneration;
    if (ownerId == null || _syncing) return;
    try {
      final connection = await _connectivity.checkConnectivity();
      _hasNetwork =
          connection.any((result) => result != ConnectivityResult.none);
    } catch (_) {
      // Keep the last measured reachability state rather than assuming online.
    }
    if (!_hasNetwork) {
      await _refreshStatus();
      return;
    }
    final internet = await _checkInternet();
    _internetAvailable = internet;
    if (!internet) {
      _online = false;
      await _refreshStatus();
      return;
    }
    final user = client.auth.currentUser;
    if (user == null || user.id != ownerId) {
      await _refreshStatus();
      return;
    }
    try {
      await client
          .from('caregivers')
          .select('id')
          .eq('id', ownerId)
          .maybeSingle()
          .timeout(const Duration(seconds: 6));
      _supabaseReachable = true;
      _online = true;
    } on PostgrestException {
      // An HTTP/PostgREST response proves the service answered, even if the
      // request itself was rejected or the query failed.
      _supabaseReachable = true;
      _online = true;
    } catch (_) {
      _supabaseReachable = false;
      _online = false;
      await _refreshStatus();
      return;
    }

    _syncing = true;
    if (!_disposed) notifyListeners();
    var hadError = false;
    try {
      final outbox = await store.nextOutbox(ownerId, force: forceRetry);
      for (final item in outbox) {
        if (generation != _syncGeneration) break;
        final type = item['entity_type']! as String;
        final id = item['entity_id']! as String;
        try {
          final sessionSnapshot =
              type == 'session' ? await store.readSession(id) : null;
          if (type == 'session') {
            await _syncSession(ownerId, id);
          } else if (type == 'response') {
            await _syncResponse(ownerId, id);
          } else {
            throw StateError('Unsupported offline record type: $type');
          }
          if (generation != _syncGeneration) break;
          _assertOwner(ownerId);
          await store.markSynced(type, id,
              expectedStatus: sessionSnapshot?['status']?.toString(),
              expectedCompletedAt:
                  sessionSnapshot?['completed_at']?.toString());
        } catch (error) {
          if (generation != _syncGeneration) break;
          if (_ownerId != ownerId || client.auth.currentUser?.id != ownerId) {
            break;
          }
          hadError = true;
          await store.markFailed(type, id, error.toString());
        }
      }
      if (!hadError && (await store.outboxCounts(ownerId)).isEmpty) {
        await store.markLastSynced(ownerId);
        _lastSyncedAt = await store.lastSyncedAt(ownerId);
      }
    } finally {
      _syncing = false;
      await _refreshStatus();
      final nextOwner = _ownerId;
      if (nextOwner != null && nextOwner != ownerId) unawaited(syncNow());
    }
  }

  void _assertOwner(String ownerId) {
    if (_ownerId != ownerId || client.auth.currentUser?.id != ownerId) {
      throw StateError('Caregiver changed before synchronization completed.');
    }
  }

  Future<bool> _checkInternet() async {
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final request = await http
          .getUrl(Uri.https('connectivitycheck.gstatic.com', 'generate_204'))
          .timeout(const Duration(seconds: 4));
      final response =
          await request.close().timeout(const Duration(seconds: 4));
      return response.statusCode == 204 || response.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      http.close(force: true);
    }
  }

  void stopForSignOut(String ownerId) {
    if (_ownerId != ownerId) return;
    _ownerId = null;
    _syncGeneration++;
    if (!_disposed) notifyListeners();
  }

  Future<void> _syncSession(String ownerId, String id) async {
    _assertOwner(ownerId);
    final row = await store.readSession(id);
    if (row == null || row['caregiver_id'] != ownerId) {
      throw StateError(
          'Local session owner does not match the signed-in caregiver.');
    }
    final profileId = row['profile_id']! as String;
    final deviceId = row['device_id'] as String?;
    if (deviceId == null || deviceId.isEmpty) {
      throw StateError(
          'This device must be enrolled while online before this session can sync.');
    }

    final profile = await client
        .from('elderly_profiles')
        .select('id')
        .eq('id', profileId)
        .maybeSingle();
    if (profile == null) {
      throw StateError(
          'The selected profile is no longer available to this caregiver. The session remains on this device.');
    }
    final device = await client
        .from('enrolled_devices')
        .select('id, revoked_at')
        .eq('id', deviceId)
        .maybeSingle();
    if (device == null || device['revoked_at'] != null) {
      throw StateError(
          'This enrolled device was revoked or is no longer available. The session remains queued.');
    }

    var activityTypeId = row['activity_type_id'] as String?;
    if (activityTypeId == null || activityTypeId.isEmpty) {
      final activity = await client
          .from('activity_types')
          .select('id')
          .eq('stable_key', row['activity_key'].toString())
          .single();
      activityTypeId = activity['id'].toString();
    }
    final remote = await client
        .from('activity_sessions')
        .select('id, elderly_profile_id, device_id, status, completed_at')
        .eq('id', id)
        .maybeSingle();
    final status = row['status']! as String;
    if (remote != null) {
      if (remote['elderly_profile_id'] != profileId ||
          remote['device_id'] != deviceId) {
        throw StateError(
            'A session ID collision was detected; no remote data was changed.');
      }
      final remoteStatus = remote['status']?.toString();
      if (remoteStatus == 'completed' || remoteStatus == 'abandoned') {
        if (status != 'in_progress' && status != remoteStatus) {
          throw StateError(
              'The local and server session have different final states. The local record was retained for review.');
        }
        return;
      }
      if (status != 'in_progress') {
        _assertOwner(ownerId);
        await client
            .from('activity_sessions')
            .update({'status': status, 'completed_at': row['completed_at']}).eq(
                'id', id);
      }
      return;
    }

    _assertOwner(ownerId);
    await client.from('activity_sessions').insert({
      'id': id,
      'elderly_profile_id': profileId,
      'activity_type_id': activityTypeId,
      'device_id': deviceId,
      'memory_deck_id': row['memory_deck_id'],
      'started_at': row['started_at'],
      'completed_at': row['completed_at'],
      'status': status,
    });
  }

  Future<void> _syncResponse(String ownerId, String id) async {
    _assertOwner(ownerId);
    final rows = await store.readResponses(id);
    if (rows.isEmpty || rows.first['caregiver_id'] != ownerId) {
      throw StateError(
          'Local response owner does not match the signed-in caregiver.');
    }
    final row = rows.first;
    final sessionId = row['session_id']! as String;
    final session = await client
        .from('activity_sessions')
        .select('id')
        .eq('id', sessionId)
        .maybeSingle();
    if (session == null) {
      throw StateError(
          'The parent session has not synchronized; it remains queued.');
    }
    final existing = await client
        .from('activity_responses')
        .select('id, session_id')
        .eq('id', id)
        .maybeSingle();
    if (existing != null) {
      if (existing['session_id'] != sessionId) {
        throw StateError(
            'A response ID collision was detected; no remote data was changed.');
      }
      return;
    }
    try {
      _assertOwner(ownerId);
      await client.from('activity_responses').insert({
        'id': id,
        'session_id': sessionId,
        'response_index': row['response_index'],
        'response_payload': jsonDecode(row['payload']! as String),
        'is_correct': row['is_correct'] == null ? null : row['is_correct'] == 1,
        'responded_at': row['responded_at'],
      });
    } catch (insertError) {
      final confirmed = await client
          .from('activity_responses')
          .select('id, session_id')
          .eq('id', id)
          .maybeSingle();
      if (confirmed == null || confirmed['session_id'] != sessionId) rethrow;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _connectivitySubscription?.cancel();
    super.dispose();
  }
}
