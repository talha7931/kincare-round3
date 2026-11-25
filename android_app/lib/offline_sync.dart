import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show listEquals, visibleForTesting;
import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_network_diagnostics.dart';
import 'offline_store.dart';

enum OfflineSyncState {
  noNetwork,
  noInternet,
  supabaseUnavailable,
  offline,
  pending,
  syncing,
  failed,
  conflict,
  synchronized
}

class OfflineSyncSnapshot {
  final OfflineSyncState state;
  final int pending;
  final int failed;
  final String? lastSyncedAt;
  final int conflicts;
  const OfflineSyncSnapshot(
      this.state, this.pending, this.failed, this.lastSyncedAt,
      [this.conflicts = 0]);
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
  int _conflicts = 0;
  String? _lastSyncedAt;
  bool _disposed = false;
  int _syncGeneration = 0;
  final Future<bool> Function()? _networkAvailableOverride;
  final Future<bool> Function()? _internetAvailableOverride;
  final String? Function()? _currentUserIdOverride;

  factory OfflineSyncService(SupabaseClient client, {OfflineStore? store}) =>
      _shared ??= OfflineSyncService._(client, store ?? OfflineStore.instance);

  OfflineSyncService._(this.client, this.store)
      : _networkAvailableOverride = null,
        _internetAvailableOverride = null,
        _currentUserIdOverride = null {
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

  @visibleForTesting
  OfflineSyncService.forTesting({
    required this.client,
    required this.store,
    required String ownerId,
    required Future<bool> Function() networkAvailable,
    required Future<bool> Function() internetAvailable,
    required String? Function() currentUserId,
  })  : _networkAvailableOverride = networkAvailable,
        _internetAvailableOverride = internetAvailable,
        _currentUserIdOverride = currentUserId {
    _ownerId = ownerId;
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
                                : _conflicts > 0
                                    ? OfflineSyncState.conflict
                                    : _pending > 0
                                        ? OfflineSyncState.pending
                                        : OfflineSyncState.synchronized,
        _pending,
        _failed,
        _lastSyncedAt,
        _conflicts,
      );

  Future<void> initialize(String ownerId) async {
    if (_ownerId != null && _ownerId != ownerId) _syncGeneration++;
    _ownerId = ownerId;
    try {
      _hasNetwork = await _checkNetworkAvailability();
    } catch (error) {
      AuthNetworkDiagnostics.logFailure(
        operation: 'connectivity_state_check',
        error: error,
        host: 'unavailable',
      );
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
    _conflicts = counts['conflict'] ?? 0;
    _lastSyncedAt = await store.lastSyncedAt(ownerId);
    if (!_disposed) notifyListeners();
  }

  Future<void> syncNow({bool forceRetry = false}) async {
    final ownerId = _ownerId;
    final generation = _syncGeneration;
    if (ownerId == null || _syncing) return;
    try {
      _hasNetwork = await _checkNetworkAvailability();
    } catch (error) {
      AuthNetworkDiagnostics.logFailure(
        operation: 'connectivity_state_check',
        error: error,
        host: 'unavailable',
      );
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
    if (_currentUserId() != ownerId) {
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
    } catch (error) {
      AuthNetworkDiagnostics.logFailure(
        operation: 'supabase_reachability_probe',
        error: error,
        host: Uri.tryParse(client.rest.url)?.host ?? 'unavailable',
      );
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
          Map<String, Object?>? entitySnapshot;
          var entityReady = true;
          if (type == 'session') {
            await _syncSession(ownerId, id);
          } else if (type == 'response') {
            await _syncResponse(ownerId, id);
          } else {
            entitySnapshot = await store.syncEntity(ownerId, type, id);
            entityReady = await _syncEntity(
                ownerId, type, id, item['operation']?.toString() ?? 'upsert');
          }
          if (!entityReady) continue;
          if (generation != _syncGeneration) break;
          _assertOwner(ownerId);
          if (type == 'session' || type == 'response') {
            await store.markSynced(type, id,
                expectedStatus: sessionSnapshot?['status']?.toString(),
                expectedCompletedAt:
                    sessionSnapshot?['completed_at']?.toString(),
                caregiverId: ownerId);
          } else {
            await store.markEntitySynced(
                ownerId, type, id, item['operation']?.toString() ?? 'upsert',
                expectedRevision: entitySnapshot?['sync_revision']?.toString());
          }
        } catch (error) {
          if (generation != _syncGeneration) break;
          if (_ownerId != ownerId || _currentUserId() != ownerId) {
            break;
          }
          hadError = true;
          AuthNetworkDiagnostics.logFailure(
            operation: 'outbox_sync',
            error: error,
            host: Uri.tryParse(client.rest.url)?.host ?? 'unavailable',
          );
          await store.markFailed(type, id, error.toString(),
              caregiverId: ownerId);
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
    if (_ownerId != ownerId || _currentUserId() != ownerId) {
      throw StateError('Caregiver changed before synchronization completed.');
    }
  }

  String? _currentUserId() =>
      _currentUserIdOverride?.call() ?? client.auth.currentUser?.id;

  Future<bool> _checkNetworkAvailability() async {
    final override = _networkAvailableOverride;
    if (override != null) return override();
    final results = await _connectivity.checkConnectivity();
    return results.any((result) => result != ConnectivityResult.none);
  }

  Map<String, dynamic> _cloudPayload(String type, Map<String, dynamic> value) {
    final fields = switch (type) {
      'caregiver' => const ['id', 'display_name'],
      'profile' => const [
          'id',
          'caregiver_id',
          'display_name',
          'preferred_language'
        ],
      'deck' => const [
          'id',
          'elderly_profile_id',
          'created_by_caregiver_id',
          'title',
          'language_code',
          'updated_at'
        ],
      'card' => const [
          'id',
          'deck_id',
          'photo_asset_id',
          'question_audio_asset_id',
          'answer_audio_asset_id',
          'question_text',
          'answer_context',
          'display_order'
        ],
      _ => const <String>[]
    };
    return {
      for (final key in fields)
        if (value.containsKey(key)) key: value[key]
    };
  }

  bool _sameCloudPayload(String type, Map<String, dynamic> first,
          Map<String, dynamic> second) =>
      jsonEncode(_cloudPayload(type, first)) ==
      jsonEncode(_cloudPayload(type, second));

  Future<Map<String, dynamic>?> _remoteEntity(
      String ownerId, String type, String id) async {
    final fields = switch (type) {
      'caregiver' => 'id, display_name',
      'profile' => 'id, caregiver_id, display_name, preferred_language',
      'deck' =>
        'id, elderly_profile_id, created_by_caregiver_id, title, language_code, created_at, updated_at',
      'card' =>
        'id, deck_id, photo_asset_id, question_audio_asset_id, answer_audio_asset_id, question_text, answer_context, display_order',
      _ => throw ArgumentError.value(type, 'type')
    };
    var query = client
        .from(switch (type) {
          'caregiver' => 'caregivers',
          'profile' => 'elderly_profiles',
          'deck' => 'memory_decks',
          'card' => 'memory_cards',
          _ => throw ArgumentError.value(type, 'type')
        })
        .select(fields)
        .eq('id', id);
    if (type == 'profile') query = query.eq('caregiver_id', ownerId);
    if (type == 'deck') {
      query = query.eq('created_by_caregiver_id', ownerId);
    }
    final result = await query.maybeSingle();
    if (result == null) return null;
    final row = Map<String, dynamic>.from(result);
    if (type == 'card') {
      final deck = await client
          .from('memory_decks')
          .select('id, created_by_caregiver_id')
          .eq('id', row['deck_id'])
          .maybeSingle();
      if (deck == null || deck['created_by_caregiver_id'] != ownerId) {
        return null;
      }
    }
    return row;
  }

  Future<bool> _syncEntity(
      String ownerId, String type, String id, String operation) async {
    _assertOwner(ownerId);
    final local = await store.syncEntity(ownerId, type, id);
    if (local == null) return true;
    if (type == 'media') {
      return _syncMedia(ownerId, local, operation);
    }
    final payload = Map<String, dynamic>.from(local['decoded_payload'] as Map);
    final base = local['decoded_base_payload'] == null
        ? null
        : Map<String, dynamic>.from(local['decoded_base_payload'] as Map);
    final state = local['sync_state']?.toString();
    final remote = await _remoteEntity(ownerId, type, id);
    if (operation == 'delete') {
      if (remote == null) return true;
      if (base != null && !_sameCloudPayload(type, remote, base)) {
        await store.recordConflict(
            ownerId, type, id, operation, payload, remote);
        return false;
      }
      _assertOwner(ownerId);
      var query = client
          .from(switch (type) {
            'caregiver' => 'caregivers',
            'profile' => 'elderly_profiles',
            'deck' => 'memory_decks',
            'card' => 'memory_cards',
            _ => throw ArgumentError.value(type, 'type')
          })
          .delete()
          .eq('id', id);
      if (type == 'profile') query = query.eq('caregiver_id', ownerId);
      if (type == 'deck') query = query.eq('created_by_caregiver_id', ownerId);
      await query;
      if (await _remoteEntity(ownerId, type, id) != null) {
        throw StateError('The server did not confirm the requested deletion.');
      }
      return true;
    }
    if (remote != null) {
      if (_sameCloudPayload(type, remote, payload)) return true;
      if (state == 'pending_create' ||
          base == null ||
          !_sameCloudPayload(type, remote, base)) {
        await store.recordConflict(
            ownerId, type, id, operation, payload, remote);
        return false;
      }
      _assertOwner(ownerId);
      var query = client
          .from(switch (type) {
            'caregiver' => 'caregivers',
            'profile' => 'elderly_profiles',
            'deck' => 'memory_decks',
            'card' => 'memory_cards',
            _ => throw ArgumentError.value(type, 'type')
          })
          .update(_cloudPayload(type, payload))
          .eq('id', id);
      if (type == 'profile') query = query.eq('caregiver_id', ownerId);
      if (type == 'deck') query = query.eq('created_by_caregiver_id', ownerId);
      await query;
      final confirmed = await _remoteEntity(ownerId, type, id);
      if (confirmed == null || !_sameCloudPayload(type, confirmed, payload)) {
        throw StateError('The server did not confirm the saved changes.');
      }
      return true;
    }
    final retryingCreate = base == null &&
        (state == 'pending_create' ||
            state == 'local_only' ||
            state == 'failed');
    if (!retryingCreate) {
      await store.recordConflict(
          ownerId, type, id, operation, payload, {'_remote_deleted': true});
      return false;
    }
    final table = switch (type) {
      'caregiver' => 'caregivers',
      'profile' => 'elderly_profiles',
      'deck' => 'memory_decks',
      'card' => 'memory_cards',
      _ => throw ArgumentError.value(type, 'type')
    };
    _assertOwner(ownerId);
    try {
      await client.from(table).insert(_cloudPayload(type, payload));
    } catch (_) {
      // The request may have succeeded before a timeout. Confirm using the
      // same stable identifier before deciding it failed.
      final confirmed = await _remoteEntity(ownerId, type, id);
      if (confirmed == null || !_sameCloudPayload(type, confirmed, payload)) {
        rethrow;
      }
    }
    final confirmed = await _remoteEntity(ownerId, type, id);
    if (confirmed == null || !_sameCloudPayload(type, confirmed, payload)) {
      throw StateError('The server did not confirm the new record.');
    }
    return true;
  }

  Future<bool> _syncMedia(
      String ownerId, Map<String, Object?> local, String operation) async {
    if (operation == 'delete') {
      final bucket = local['storage_bucket']?.toString();
      final path = local['storage_path']?.toString();
      if (bucket != null && path != null && path.isNotEmpty) {
        _assertOwner(ownerId);
        try {
          await client.storage.from(bucket).remove([path]);
        } catch (_) {
          // Confirm metadata below; a retry can safely repeat object removal.
        }
      }
      _assertOwner(ownerId);
      final assetId = local['asset_id']?.toString();
      if (assetId == null || assetId.isEmpty) {
        throw StateError('Local media metadata has no asset ID.');
      }
      await client.from('media_assets').delete().eq('id', assetId);
      return true;
    }
    final profileId = local['profile_id']?.toString();
    final path = local['local_path']?.toString();
    final bucket = local['storage_bucket']?.toString() ?? 'kincare-media';
    final storagePath = local['storage_path']?.toString();
    if (profileId == null || path == null || storagePath == null) {
      throw StateError('Local media metadata is incomplete.');
    }
    final profile = await client
        .from('elderly_profiles')
        .select('id')
        .eq('id', profileId)
        .eq('caregiver_id', ownerId)
        .maybeSingle();
    if (profile == null) {
      throw StateError('This media profile is no longer authorized.');
    }
    final file = File(path);
    if (!await file.exists())
      throw StateError('The saved media file is missing.');
    final size = await file.length();
    if (size <= 0 ||
        (local['file_size'] is int && local['file_size'] != size)) {
      throw StateError('The saved media file failed size verification.');
    }
    final assetId = local['asset_id'].toString();
    final existing = await client
        .from('media_assets')
        .select(
            'id, elderly_profile_id, uploaded_by_caregiver_id, storage_bucket, storage_path, media_type, mime_type')
        .eq('id', assetId)
        .maybeSingle();
    if (existing != null) {
      if (existing['uploaded_by_caregiver_id'] != ownerId ||
          existing['elderly_profile_id'] != profileId ||
          existing['storage_bucket'] != bucket ||
          existing['storage_path'] != storagePath) {
        await store.recordConflict(
            ownerId,
            'media',
            assetId,
            'upload',
            Map<String, dynamic>.from(local),
            Map<String, dynamic>.from(existing));
        return false;
      }
      return true;
    }
    _assertOwner(ownerId);
    try {
      await client.storage.from(bucket).upload(
            storagePath,
            file,
            fileOptions:
                FileOptions(contentType: local['mime_type']?.toString()),
          );
    } catch (uploadError) {
      // A prior upload may have succeeded before a timeout. Verify the existing
      // object bytes before treating the retry as idempotently complete.
      try {
        final remoteBytes =
            await client.storage.from(bucket).download(storagePath);
        final localBytes = await file.readAsBytes();
        if (!listEquals(remoteBytes, localBytes)) rethrow;
      } catch (_) {
        throw uploadError;
      }
    }
    final metadata = {
      'id': assetId,
      'elderly_profile_id': profileId,
      'uploaded_by_caregiver_id': ownerId,
      'storage_bucket': bucket,
      'storage_path': storagePath,
      'media_type': local['media_type'],
      'mime_type': local['mime_type'],
    };
    _assertOwner(ownerId);
    try {
      await client.from('media_assets').insert(metadata);
    } catch (_) {
      final confirmed = await client
          .from('media_assets')
          .select(
              'id, elderly_profile_id, uploaded_by_caregiver_id, storage_bucket, storage_path, media_type, mime_type')
          .eq('id', assetId)
          .maybeSingle();
      if (confirmed == null ||
          confirmed['uploaded_by_caregiver_id'] != ownerId ||
          confirmed['storage_bucket'] != bucket ||
          confirmed['storage_path'] != storagePath) {
        rethrow;
      }
    }
    return true;
  }

  Future<bool> _checkInternet() async {
    final override = _internetAvailableOverride;
    if (override != null) return override();
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final request = await http
          .getUrl(Uri.https('connectivitycheck.gstatic.com', 'generate_204'))
          .timeout(const Duration(seconds: 4));
      final response =
          await request.close().timeout(const Duration(seconds: 4));
      return response.statusCode == 204 || response.statusCode == 200;
    } catch (error) {
      AuthNetworkDiagnostics.logFailure(
        operation: 'internet_reachability_probe',
        error: error,
        host: 'connectivitycheck.gstatic.com',
      );
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
        .select('id, caregiver_id')
        .eq('id', profileId)
        .eq('caregiver_id', ownerId)
        .maybeSingle();
    if (profile == null) {
      throw StateError(
          'The selected profile is no longer available to this caregiver. The session remains on this device.');
    }
    final device = await client
        .from('enrolled_devices')
        .select('id, caregiver_id, revoked_at')
        .eq('id', deviceId)
        .eq('caregiver_id', ownerId)
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
    final payload =
        jsonDecode(row['payload']! as String) as Map<String, dynamic>;
    final audioAssetId = row['response_audio_asset_id']?.toString();
    if (audioAssetId != null && audioAssetId.isNotEmpty) {
      final asset = await client
          .from('media_assets')
          .select('id, uploaded_by_caregiver_id')
          .eq('id', audioAssetId)
          .eq('uploaded_by_caregiver_id', ownerId)
          .maybeSingle();
      if (asset == null) {
        throw StateError('The response audio has not synchronized yet.');
      }
    }
    try {
      _assertOwner(ownerId);
      await client.from('activity_responses').insert({
        'id': id,
        'session_id': sessionId,
        'response_index': row['response_index'],
        'memory_card_id': payload['card_id'] ?? payload['memory_card_id'],
        'response_audio_asset_id': audioAssetId,
        'response_payload': payload,
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
