import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_theme.dart';
import 'offline_store.dart';

class CaregiverActivityHistoryScreen extends StatefulWidget {
  final List<Map<String, dynamic>> profiles;

  const CaregiverActivityHistoryScreen({super.key, required this.profiles});

  @override
  State<CaregiverActivityHistoryScreen> createState() =>
      _CaregiverActivityHistoryScreenState();
}

class _CaregiverActivityHistoryScreenState
    extends State<CaregiverActivityHistoryScreen> {
  final _client = Supabase.instance.client;
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _sessions = [];
  Map<String, String> _activityNames = {};
  Map<String, List<Map<String, dynamic>>> _responses = {};
  final Map<String, String> _localActivityKeys = {};
  final Map<String, String> _localSyncStates = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final loaded = <Map<String, dynamic>>[];
    final names = <String, String>{};
    final responseMap = <String, List<Map<String, dynamic>>>{};
    final localKeys = <String, String>{};
    final localStates = <String, String>{};
    final profileIds = widget.profiles.map((p) => p['id'].toString()).toList();
    try {
      if (profileIds.isNotEmpty) {
        var offset = 0;
        const pageSize = 100;
        while (true) {
          final page = List<Map<String, dynamic>>.from(await _client
              .from('activity_sessions')
              .select(
                  'id, elderly_profile_id, activity_type_id, started_at, completed_at, status')
              .inFilter('elderly_profile_id', profileIds)
              .order('started_at', ascending: false)
              .order('id', ascending: false)
              .range(offset, offset + pageSize - 1));
          loaded.addAll(page);
          if (page.length < pageSize) break;
          offset += pageSize;
        }
        final typeIds = loaded
            .map((row) => row['activity_type_id'].toString())
            .toSet()
            .toList();
        final types = typeIds.isEmpty
            ? <Map<String, dynamic>>[]
            : List<Map<String, dynamic>>.from(await _client
                .from('activity_types')
                .select('id, name, stable_key')
                .inFilter('id', typeIds));
        for (final row in types) {
          names[row['id'].toString()] = row['name'].toString();
          localKeys[row['id'].toString()] = row['stable_key']?.toString() ?? '';
        }
        final sessionIds = loaded.map((row) => row['id'].toString()).toList();
        for (var start = 0; start < sessionIds.length; start += 100) {
          final ids = sessionIds.skip(start).take(100).toList();
          final responseRows = List<Map<String, dynamic>>.from(await _client
              .from('activity_responses')
              .select(
                  'id, session_id, response_index, response_payload, is_correct')
              .inFilter('session_id', ids)
              .order('response_index'));
          for (final response in responseRows) {
            final sessionId = response['session_id'].toString();
            final list = responseMap.putIfAbsent(sessionId, () => []);
            if (!list.any((item) =>
                item['response_index'] == response['response_index'])) {
              list.add(response);
            }
          }
        }
      }
    } catch (error) {
      _error = 'Cloud history could not refresh: $error';
    }
    try {
      final ownerId = _client.auth.currentUser?.id;
      if (ownerId != null) {
        final cached =
            await OfflineStore.instance.cachedHistory(ownerId, profileIds);
        final knownCloud = loaded.map((row) => row['id'].toString()).toSet();
        for (final row in cached) {
          final id = row['id'].toString();
          localKeys[id] = row['_activity_key']?.toString() ?? '';
          if (!names.containsKey(row['activity_type_id']?.toString())) {
            final label = row['_activity_name']?.toString();
            if (label != null && label.isNotEmpty) {
              names[row['activity_type_id'].toString()] = label;
            }
          }
          if (!knownCloud.contains(id)) loaded.add(row);
        }
        final cachedResponses = await OfflineStore.instance.cachedResponses(
            ownerId, cached.map((row) => row['id'].toString()).toList());
        for (final response in cachedResponses) {
          final sessionId = response['session_id'].toString();
          final list = responseMap.putIfAbsent(sessionId, () => []);
          if (list.any(
              (row) => row['response_index'] == response['response_index']))
            continue;
          list.add({
            'id': response['id'],
            'response_index': response['response_index'],
            'response_payload': response['response_payload'],
            'is_correct': response['is_correct'],
          });
        }
        final localRows =
            await OfflineStore.instance.localSessions(ownerId, profileIds);
        final known = loaded.map((row) => row['id'].toString()).toSet();
        for (final local in localRows) {
          final id = local['id'].toString();
          localKeys[id] = local['activity_key'].toString();
          localStates[id] = local['sync_state'].toString();
          final localSession = {
            'id': id,
            'elderly_profile_id': local['profile_id'],
            'activity_type_id': local['activity_type_id'],
            'started_at': local['started_at'],
            'completed_at': local['completed_at'],
            'status': local['status']
          };
          if (!known.contains(id)) {
            loaded.add(localSession);
          } else if (local['sync_state'] != 'synced') {
            final existingIndex =
                loaded.indexWhere((row) => row['id'].toString() == id);
            if (existingIndex >= 0) loaded[existingIndex] = localSession;
          }
          final localResponses = await OfflineStore.instance.localResponses(id);
          final responseList = responseMap.putIfAbsent(id, () => []);
          for (final row in localResponses) {
            if (responseList
                .any((item) => item['response_index'] == row['response_index']))
              continue;
            responseList.add({
              'id': row['id'],
              'response_index': row['response_index'],
              'response_payload': row['payload'] == null
                  ? <String, dynamic>{}
                  : jsonDecode(row['payload']! as String),
              'is_correct':
                  row['is_correct'] == null ? null : row['is_correct'] == 1,
            });
          }
        }
      }
    } catch (error) {
      _error ??= 'Offline activity could not be loaded: $error';
    }
    loaded.sort((a, b) =>
        (DateTime.tryParse(b['started_at']?.toString() ?? '') ?? DateTime(0))
            .compareTo(DateTime.tryParse(a['started_at']?.toString() ?? '') ??
                DateTime(0)));
    if (mounted)
      setState(() {
        _sessions = loaded;
        _activityNames = names;
        _responses = responseMap;
        _localActivityKeys
          ..clear()
          ..addAll(localKeys);
        _localSyncStates
          ..clear()
          ..addAll(localStates);
        _loading = false;
      });
  }

  @override
  Widget build(BuildContext context) {
    final profileNames = {
      for (final profile in widget.profiles)
        profile['id'].toString(): profile['display_name'].toString(),
    };
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null && _sessions.isEmpty) {
      return Center(
          child: Padding(
        padding: const EdgeInsets.all(KinCareSpace.x5),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_error!, style: const TextStyle(color: KinCareColors.danger)),
          const SizedBox(height: KinCareSpace.x3),
          FilledButton(onPressed: _load, child: const Text('Try again')),
        ]),
      ));
    }
    if (_sessions.isEmpty) {
      return const Center(
          child: Padding(
        padding: EdgeInsets.all(KinCareSpace.x6),
        child: Text('No activities have been recorded for these profiles yet.',
            textAlign: TextAlign.center, style: TextStyle(fontSize: 20)),
      ));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.all(KinCareSpace.x4),
        itemCount: _sessions.length,
        separatorBuilder: (_, __) => const SizedBox(height: KinCareSpace.x3),
        itemBuilder: (context, index) {
          final session = _sessions[index];
          final sessionId = session['id'].toString();
          final started =
              DateTime.tryParse(session['started_at'].toString())?.toLocal();
          final responseRows = _responses[sessionId] ?? const [];
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(KinCareSpace.x4),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        _activityNames[
                                session['activity_type_id']?.toString() ??
                                    ''] ??
                            _activityName(_localActivityKeys[sessionId] ?? ''),
                        style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: KinCareColors.forest)),
                    const SizedBox(height: KinCareSpace.x2),
                    Text(
                        'Profile: ${profileNames[session['elderly_profile_id'].toString()] ?? 'Profile'}'),
                    Text(
                        'Started: ${started?.toString() ?? session['started_at']}'),
                    Text(
                        'Status: ${session['status']} · ${_localSyncStates.containsKey(sessionId) ? _syncLabel(_localSyncStates[sessionId]!) : 'Synced'}'),
                    for (final response in responseRows) ...[
                      const SizedBox(height: KinCareSpace.x1),
                      Text(_responseSummary(
                          response['response_payload'] as Map<String, dynamic>,
                          response['response_index'] as int)),
                    ],
                  ]),
            ),
          );
        },
      ),
    );
  }

  String _responseSummary(Map<String, dynamic> payload, int index) {
    if (payload['activity_type'] == 'odd_one_out') {
      return 'Round ${index + 1}: selected ${payload['selected_item_id']}';
    }
    if (payload['activity_type'] == 'everyday_object_sorting')
      return '${payload['item_id']} placed in ${payload['selected_category_id']}';
    if (payload['activity_type'] == 'memory_deck' ||
        payload['activity_type'] == 'memory_decks')
      return payload['response_kind'] == 'audio' ||
              payload['response_kind'] == 'text_and_audio'
          ? 'Recorded a spoken response'
          : (payload['text']?.toString().isNotEmpty == true
              ? 'Shared a text response'
              : 'Response recorded');
    return 'Response recorded';
  }

  String _activityName(String key) => key == 'odd_one_out'
      ? 'Odd One Out'
      : key == 'everyday_object_sorting'
          ? 'Everyday Object Sorting'
          : key == 'memory_decks'
              ? 'Memory Decks'
              : 'Activity';
  String _syncLabel(String state) => state == 'synced'
      ? 'Synced'
      : state == 'failed'
          ? 'Sync failed'
          : 'Pending sync';
}
