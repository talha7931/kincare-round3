import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'offline_store.dart';

/// Fetches stable ordered pages until the backend returns a short page.
Future<List<T>> fetchAllPages<T>(
  Future<List<T>> Function(int from, int to) fetchPage, {
  int pageSize = 500,
}) async {
  if (pageSize <= 0) throw ArgumentError.value(pageSize, 'pageSize');
  final rows = <T>[];
  var from = 0;
  while (true) {
    final page = await fetchPage(from, from + pageSize - 1);
    rows.addAll(page);
    if (page.length < pageSize) return rows;
    from += pageSize;
  }
}

class CachePreparationSnapshot {
  final int completed;
  final int total;
  final int failed;
  final bool running;
  final String stage;
  final CachePreparationStatus? explicitStatus;
  const CachePreparationSnapshot(
      this.completed, this.total, this.failed, this.running,
      {this.stage = '', this.explicitStatus});
  double get progress => total == 0 ? 0 : (completed / total).clamp(0.0, 1.0);
  int get pending => (total - completed).clamp(0, total);
  CachePreparationStatus get status {
    if (explicitStatus != null) return explicitStatus!;
    if (running) return CachePreparationStatus.preparing;
    if (total == 0) return CachePreparationStatus.notStarted;
    if (failed == 0) return CachePreparationStatus.ready;
    return completed > failed
        ? CachePreparationStatus.partiallyReady
        : CachePreparationStatus.failed;
  }
}

enum CachePreparationStatus {
  notStarted,
  preparing,
  ready,
  partiallyReady,
  failed,
  waitingForConnection,
  retrying,
}

/// Prepares only rows visible to the authenticated caregiver through RLS.
class OfflineCachePreparation {
  OfflineCachePreparation(this.client, this.store);
  final SupabaseClient client;
  final OfflineStore store;
  final progress =
      ValueNotifier(const CachePreparationSnapshot(0, 0, 0, false));
  int _completed = 0;
  int _total = 0;
  int _failed = 0;
  String _stage = '';
  CachePreparationStatus? _explicitStatus;

  void _publish({bool running = true}) => progress.value =
      CachePreparationSnapshot(_completed, _total, _failed, running,
          stage: _stage, explicitStatus: _explicitStatus);

  void _discover(int count) {
    _total += count;
    _publish();
  }

  void _done() {
    _completed++;
    _publish();
  }

  void _fail() {
    _failed++;
    _completed++;
    _publish();
  }

  void waitForConnection() {
    _stage = 'Waiting for connection';
    _explicitStatus = CachePreparationStatus.waitingForConnection;
    _publish(running: false);
  }

  void _ensureOwner(String owner) {
    if (client.auth.currentUser?.id != owner) {
      throw StateError('Caregiver session changed during offline preparation.');
    }
  }

  Future<void> prepare(String owner, {bool retrying = false}) async {
    if (client.auth.currentUser?.id != owner) {
      throw StateError('Caregiver session changed.');
    }
    _completed = 0;
    _total = 1;
    _failed = 0;
    _stage = 'Loading caregiver';
    _explicitStatus = retrying
        ? CachePreparationStatus.retrying
        : CachePreparationStatus.preparing;
    _publish();
    try {
      final caregiver = await client
          .from('caregivers')
          .select()
          .eq('id', owner)
          .maybeSingle()
          .timeout(const Duration(seconds: 8));
      _ensureOwner(owner);
      if (caregiver == null) {
        throw StateError('Caregiver profile is unavailable.');
      }
      await store.cacheCaregiver(owner, caregiver);
      _done();

      _stage = 'Loading profiles';
      final profiles = await fetchAllPages<Map<String, dynamic>>(
          (from, to) async => List<Map<String, dynamic>>.from(await client
              .from('elderly_profiles')
              .select()
              .eq('caregiver_id', owner)
              .order('id')
              .range(from, to)
              .timeout(const Duration(seconds: 12))));
      _ensureOwner(owner);
      _discover(profiles.length);
      await store.cacheProfiles(owner, profiles);
      _completed += profiles.length;
      _publish();

      final profileIds = profiles.map((p) => p['id'].toString()).toList();
      final sessions = <Map<String, dynamic>>[];
      if (profileIds.isNotEmpty) {
        _stage = 'Loading activity history';
        final activityTypes = List<Map<String, dynamic>>.from(await client
            .from('activity_types')
            .select('id, stable_key, name')
            .timeout(const Duration(seconds: 8)));
        final activityById = {
          for (final type in activityTypes) type['id'].toString(): type,
        };
        final history = await fetchAllPages<Map<String, dynamic>>(
            (from, to) async => List<Map<String, dynamic>>.from(await client
                .from('activity_sessions')
                .select()
                .inFilter('elderly_profile_id', profileIds)
                .order('started_at', ascending: false)
                .order('id', ascending: false)
                .range(from, to)
                .timeout(const Duration(seconds: 15))));
        _ensureOwner(owner);
        final authorizedProfileIds = profileIds.toSet();
        sessions.addAll(history
            .where((row) => authorizedProfileIds
                .contains(row['elderly_profile_id']?.toString()))
            .map((row) {
          final activity = activityById[row['activity_type_id']?.toString()];
          return {
            ...row,
            'caregiver_id': owner,
            '_activity_key': activity?['stable_key'],
            '_activity_name': activity?['name'],
          };
        }));
        _discover(sessions.length);
        for (final session in sessions) {
          await store.cacheHistory(owner, [session], const []);
          await store.setCacheItem(
              owner, 'history', session['id'].toString(), 'ready');
          _completed++;
          _publish();
        }
        final sessionIds = sessions.map((s) => s['id'].toString()).toList();
        final allResponses = <Map<String, dynamic>>[];
        for (var i = 0; i < sessionIds.length; i += 100) {
          final ids = sessionIds.skip(i).take(100).toList();
          final responsePage = await fetchAllPages<Map<String, dynamic>>(
              (from, to) async => List<Map<String, dynamic>>.from(await client
                  .from('activity_responses')
                  .select()
                  .inFilter('session_id', ids)
                  .order('session_id')
                  .order('response_index')
                  .order('id')
                  .range(from, to)
                  .timeout(const Duration(seconds: 15))));
          allResponses.addAll(responsePage);
        }
        _ensureOwner(owner);
        _discover(allResponses.length);
        final sessionsById = {for (final s in sessions) s['id'].toString(): s};
        for (final response in allResponses) {
          final sid = response['session_id']?.toString();
          final parent = sid == null ? null : sessionsById[sid];
          if (parent == null) {
            await store.setCacheItem(
                owner,
                'history-response',
                response['id'].toString(),
                'failed',
                'Parent session is not authorized.');
            _fail();
            continue;
          }
          await store.cacheHistory(owner, [parent], [response]);
          await store.setCacheItem(
              owner, 'history-response', response['id'].toString(), 'ready');
          _completed++;
          _publish();
        }
      }

      for (final profile in profiles) {
        _ensureOwner(owner);
        final profileId = profile['id'].toString();
        _stage = 'Loading Memory Decks';
        final decks = await fetchAllPages<Map<String, dynamic>>(
            (from, to) async => List<Map<String, dynamic>>.from(await client
                .from('memory_decks')
                .select()
                .eq('elderly_profile_id', profileId)
                .order('id')
                .range(from, to)
                .timeout(const Duration(seconds: 12))));
        _ensureOwner(owner);
        _discover(decks.length);
        for (final deck in decks) {
          final deckId = deck['id'].toString();
          var failedDeck = false;
          try {
            _stage = 'Caching cards and media';
            await store.setCacheItem(owner, 'deck', deckId, 'downloading');
            final cardSnapshotStartedAt = DateTime.now().toUtc();
            final cards = await fetchAllPages<Map<String, dynamic>>(
                (from, to) async => List<Map<String, dynamic>>.from(await client
                    .from('memory_cards')
                    .select()
                    .eq('deck_id', deckId)
                    .order('display_order')
                    .order('id')
                    .range(from, to)
                    .timeout(const Duration(seconds: 12))));
            _ensureOwner(owner);
            deck['_card_count'] = cards.length;
            _discover(cards.length);
            await store.cacheDeck(owner, profileId, deck, cards,
                remoteSnapshotStartedAt: cardSnapshotStartedAt);
            final cardsMissingPhotos = cards
                .where((card) =>
                    (card['photo_asset_id']?.toString() ?? '').isEmpty)
                .toList();
            if (cardsMissingPhotos.isNotEmpty) {
              for (final card in cardsMissingPhotos) {
                await store.setCacheItem(owner, 'card', card['id'].toString(),
                    'partial', 'Required photograph is missing.');
                _fail();
              }
              failedDeck = true;
            }

            final assetIds = <String>{};
            for (final card in cards) {
              for (final key in [
                'photo_asset_id',
                'question_audio_asset_id',
                'answer_audio_asset_id'
              ]) {
                final value = card[key]?.toString();
                if (value != null && value.isNotEmpty) assetIds.add(value);
              }
            }
            _discover(assetIds.length);
            final assets = <Map<String, dynamic>>[];
            for (var i = 0; i < assetIds.length; i += 100) {
              final ids = assetIds.skip(i).take(100).toList();
              assets.addAll(List<Map<String, dynamic>>.from(await client
                  .from('media_assets')
                  .select('id, storage_bucket, storage_path, mime_type')
                  .inFilter('id', ids)
                  .timeout(const Duration(seconds: 12))));
            }
            final byId = {
              for (final asset in assets) asset['id'].toString(): asset
            };
            for (final id in assetIds) {
              final asset = byId[id];
              if (asset == null) {
                failedDeck = true;
                _fail();
                await store.setCacheItem(owner, 'media', id, 'failed',
                    'Media metadata is unavailable.');
                continue;
              }
              try {
                _ensureOwner(owner);
                final path = asset['storage_path']?.toString();
                if (path == null || path.isEmpty) {
                  throw StateError('Media path is missing.');
                }
                await store.setCacheItem(owner, 'media', id, 'downloading');
                final local = await store.cacheMediaIfNeeded(
                  owner,
                  id,
                  () => client.storage
                      .from((asset['storage_bucket'] ?? 'kincare-media')
                          .toString())
                      .download(path)
                      .timeout(const Duration(seconds: 20)),
                  asset['mime_type']?.toString(),
                  extension: path.split('.').last,
                );
                if (await store.mediaPath(owner, id) != local) {
                  throw StateError('Local media verification failed.');
                }
                await store.setCacheItem(owner, 'media', id, 'ready');
                _completed++;
                _publish();
              } catch (error) {
                failedDeck = true;
                _fail();
                await store.setCacheItem(
                    owner, 'media', id, 'failed', error.toString());
              }
            }
            for (final card in cards) {
              final cardId = card['id'].toString();
              if (cardsMissingPhotos
                  .any((missing) => missing['id'] == card['id'])) {
                continue;
              }
              final cardAssets = [
                for (final key in [
                  'photo_asset_id',
                  'question_audio_asset_id',
                  'answer_audio_asset_id'
                ])
                  if ((card[key]?.toString() ?? '').isNotEmpty)
                    card[key].toString(),
              ];
              final cardReady = await store.allMediaCached(owner, cardAssets);
              await store.setCacheItem(
                  owner,
                  'card',
                  cardId,
                  cardReady ? 'ready' : 'partial',
                  cardReady
                      ? null
                      : 'One or more card media files are unavailable offline.');
              if (cardReady) {
                _done();
              } else {
                failedDeck = true;
                _fail();
              }
            }
            final ready = !failedDeck &&
                await store.allMediaCached(owner, assetIds.toList());
            await store.setCacheItem(
                owner,
                'deck',
                deckId,
                ready ? 'ready' : 'partial',
                ready
                    ? null
                    : 'Some cards or media are unavailable offline. Retry while connected.');
          } catch (error) {
            failedDeck = true;
            await store.setCacheItem(
                owner, 'deck', deckId, 'failed', error.toString());
          }
          if (failedDeck) {
            // Deck unit is still completed; the failed/partial state is explicit.
            _failed++;
          }
          _completed++;
          _publish();
        }
      }
      _stage =
          _failed == 0 ? 'Offline content ready' : 'Some content needs retry';
      _explicitStatus = _failed == 0
          ? CachePreparationStatus.ready
          : CachePreparationStatus.partiallyReady;
      _publish(running: false);
    } catch (_) {
      _failed++;
      _stage = 'Preparation failed';
      _explicitStatus = CachePreparationStatus.failed;
      _publish(running: false);
      rethrow;
    }
  }
}
