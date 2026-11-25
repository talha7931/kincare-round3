import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'offline_store.dart';

class ActivityResponseRecord {
  final int index;
  final Map<String, dynamic> payload;
  final bool? isCorrect;

  const ActivityResponseRecord({
    required this.index,
    required this.payload,
    required this.isCorrect,
  });

  String summary(String activityKey) {
    if (activityKey == 'odd_one_out') {
      final selected = payload['selected_item_id'];
      return selected == null ? 'Response recorded' : 'Selected $selected';
    }
    if (activityKey == 'everyday_object_sorting') {
      final item = payload['item_id'];
      final category = payload['selected_category_id'];
      return item == null || category == null
          ? 'Response recorded'
          : '$item placed in $category';
    }
    if (activityKey == 'memory_decks' ||
        payload['activity_type'] == 'memory_deck' ||
        payload['activity_type'] == 'memory_decks') {
      final text = payload['text']?.toString().trim();
      if (text != null && text.isNotEmpty) return 'Shared a text response';
      if (payload['response_kind'] == 'audio' ||
          payload['response_kind'] == 'text_and_audio') {
        return 'Recorded a spoken response';
      }
    }
    return 'Response recorded';
  }
}

class ActivitySessionRecord {
  final String id;
  final String profileId;
  final String activityTypeId;
  final String activityKey;
  final String activityName;
  final DateTime startedAtUtc;
  final DateTime? completedAtUtc;
  final String status;
  final List<ActivityResponseRecord> responses;
  final String syncState;

  const ActivitySessionRecord({
    required this.id,
    required this.profileId,
    required this.activityTypeId,
    required this.activityKey,
    required this.activityName,
    required this.startedAtUtc,
    required this.completedAtUtc,
    required this.status,
    required this.responses,
    this.syncState = 'synced',
  });

  Duration? get elapsedDuration {
    final completed = completedAtUtc;
    if (completed == null || completed.isBefore(startedAtUtc)) return null;
    return completed.difference(startedAtUtc);
  }

  String get displayStatus => switch (status) {
        'completed' => 'Completed',
        'abandoned' => 'Stopped early',
        'in_progress' => 'In progress',
        _ => 'Status unavailable',
      };
}

class ReportingData {
  final List<ActivitySessionRecord> sessions;
  const ReportingData(this.sessions);
}

/// Loads only caregiver-visible cloud rows. Existing RLS remains the access
/// boundary; no service-role access or client-side ownership substitute is used.
Future<ReportingData> loadCaregiverReportingData(
  SupabaseClient client,
  List<Map<String, dynamic>> profiles,
) async {
  if (profiles.isEmpty) return const ReportingData([]);
  final profileIds = profiles.map((row) => row['id'].toString()).toList();

  final typeRows = List<Map<String, dynamic>>.from(
    await client.from('activity_types').select('id, stable_key, name'),
  );
  final typeById = <String, Map<String, String>>{
    for (final row in typeRows)
      row['id'].toString(): {
        'key': row['stable_key']?.toString() ?? '',
        'name': row['name']?.toString() ?? 'Activity',
      },
  };

  const pageSize = 500;
  final sessionRows = <Map<String, dynamic>>[];
  var offset = 0;
  while (true) {
    final page = List<Map<String, dynamic>>.from(
      await client
          .from('activity_sessions')
          .select(
              'id, elderly_profile_id, activity_type_id, started_at, completed_at, status')
          .inFilter('elderly_profile_id', profileIds)
          .order('started_at', ascending: false)
          .range(offset, offset + pageSize - 1),
    );
    sessionRows.addAll(page);
    if (page.length < pageSize) break;
    offset += pageSize;
  }
  if (sessionRows.isEmpty) return const ReportingData([]);

  final responsesBySession = <String, List<ActivityResponseRecord>>{};
  const responseSessionBatchSize = 100;
  final sessionIds = sessionRows.map((row) => row['id'].toString()).toList();
  for (var offset = 0;
      offset < sessionIds.length;
      offset += responseSessionBatchSize) {
    final ids = sessionIds.skip(offset).take(responseSessionBatchSize).toList();
    final rows = List<Map<String, dynamic>>.from(
      await client
          .from('activity_responses')
          .select('session_id, response_index, response_payload, is_correct')
          .inFilter('session_id', ids)
          .order('response_index'),
    );
    for (final row in rows) {
      final payload = row['response_payload'];
      (responsesBySession[row['session_id'].toString()] ??= []).add(
        ActivityResponseRecord(
          index: (row['response_index'] as num?)?.toInt() ?? 0,
          payload: payload is Map
              ? Map<String, dynamic>.from(payload)
              : const <String, dynamic>{},
          isCorrect: row['is_correct'] as bool?,
        ),
      );
    }
  }

  return ReportingData([
    for (final row in sessionRows)
      ActivitySessionRecord(
        id: row['id'].toString(),
        profileId: row['elderly_profile_id'].toString(),
        activityTypeId: row['activity_type_id'].toString(),
        activityKey: typeById[row['activity_type_id'].toString()]?['key'] ?? '',
        activityName:
            typeById[row['activity_type_id'].toString()]?['name'] ?? 'Activity',
        startedAtUtc: DateTime.parse(row['started_at'].toString()).toUtc(),
        completedAtUtc: row['completed_at'] == null
            ? null
            : DateTime.parse(row['completed_at'].toString()).toUtc(),
        status: row['status']?.toString() ?? 'unknown',
        responses: List.unmodifiable(
          responsesBySession[row['id'].toString()] ?? const [],
        ),
      ),
  ]);
}

/// Loads local and authorized cloud records, retaining pending local versions
/// by stable ID. When the network is unavailable, SQLite remains sufficient
/// for the report and PDF flows.
Future<ReportingData> loadCaregiverReportingDataLocalFirst(
  SupabaseClient client,
  OfflineStore store,
  String ownerId,
  List<Map<String, dynamic>> profiles,
) async {
  final local = await loadLocalCaregiverReportingData(store, ownerId, profiles);
  try {
    final cloud = await loadCaregiverReportingData(client, profiles);
    final byId = {for (final session in cloud.sessions) session.id: session};
    for (final session in local.sessions) {
      final existing = byId[session.id];
      if (existing == null || session.syncState != 'synced') {
        byId[session.id] = session;
      }
    }
    final merged = byId.values.toList()
      ..sort((a, b) => b.startedAtUtc.compareTo(a.startedAtUtc));
    return ReportingData(merged);
  } catch (_) {
    return local;
  }
}

Future<ReportingData> loadLocalCaregiverReportingData(
  OfflineStore store,
  String ownerId,
  List<Map<String, dynamic>> profiles,
) async {
  final profileIds = profiles.map((row) => row['id'].toString()).toList();
  if (ownerId.isEmpty || profileIds.isEmpty) return const ReportingData([]);
  final sessions = <String, Map<String, dynamic>>{};
  for (final row in await store.cachedHistory(ownerId, profileIds)) {
    sessions[row['id'].toString()] = {...row, '_sync_state': 'synced'};
  }
  for (final row in await store.localSessions(ownerId, profileIds)) {
    sessions[row['id'].toString()] = {
      ...row,
      'elderly_profile_id': row['profile_id'],
      'activity_type_id': row['activity_type_id'],
      '_activity_key': row['activity_key'],
      '_sync_state': row['sync_state'],
      'started_at': row['started_at'],
      'completed_at': row['completed_at'],
    };
  }
  if (sessions.isEmpty) return const ReportingData([]);
  final responseRows = <String, List<Map<String, dynamic>>>{};
  final cachedResponses =
      await store.cachedResponses(ownerId, sessions.keys.toList());
  for (final row in cachedResponses) {
    (responseRows[row['session_id'].toString()] ??= []).add(row);
  }
  for (final sessionId in sessions.keys) {
    final localResponses = await store.localResponses(sessionId);
    final list = responseRows.putIfAbsent(sessionId, () => []);
    for (final row in localResponses) {
      if (!list
          .any((cached) => cached['response_index'] == row['response_index'])) {
        list.add({
          'id': row['id'],
          'session_id': sessionId,
          'response_index': row['response_index'],
          'response_payload': jsonDecode(row['payload']! as String),
          'is_correct':
              row['is_correct'] == null ? null : row['is_correct'] == 1,
        });
      }
    }
  }
  const names = {
    'memory_decks': 'Memory Decks',
    'odd_one_out': 'Odd One Out',
    'everyday_object_sorting': 'Everyday Object Sorting',
  };
  final records = <ActivitySessionRecord>[];
  for (final row in sessions.values) {
    final id = row['id'].toString();
    final activityKey = row['_activity_key']?.toString() ?? '';
    final rawResponses = responseRows[id] ?? const [];
    rawResponses.sort((a, b) => ((a['response_index'] as num?)?.toInt() ?? 0)
        .compareTo((b['response_index'] as num?)?.toInt() ?? 0));
    records.add(ActivitySessionRecord(
      id: id,
      profileId: (row['elderly_profile_id'] ?? row['profile_id']).toString(),
      activityTypeId: row['activity_type_id']?.toString() ?? '',
      activityKey: activityKey,
      activityName:
          row['_activity_name']?.toString() ?? names[activityKey] ?? 'Activity',
      startedAtUtc:
          DateTime.tryParse(row['started_at']?.toString() ?? '')?.toUtc() ??
              DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      completedAtUtc: row['completed_at'] == null
          ? null
          : DateTime.tryParse(row['completed_at'].toString())?.toUtc(),
      status: row['status']?.toString() ?? 'unknown',
      syncState: row['_sync_state']?.toString() ?? 'synced',
      responses: [
        for (final response in rawResponses)
          ActivityResponseRecord(
            index: (response['response_index'] as num?)?.toInt() ?? 0,
            payload: response['response_payload'] is Map
                ? Map<String, dynamic>.from(response['response_payload'] as Map)
                : const <String, dynamic>{},
            isCorrect: response['is_correct'] is bool
                ? response['is_correct'] as bool
                : response['is_correct'] == null
                    ? null
                    : response['is_correct'] == 1,
          ),
      ],
    ));
  }
  records.sort((a, b) => b.startedAtUtc.compareTo(a.startedAtUtc));
  return ReportingData(records);
}

DateTime reportingUtcDate(DateTime date) =>
    DateTime.utc(date.year, date.month, date.day);

class EngagementMetrics {
  final int totalSessions;
  final int completedSessions;
  final int abandonedSessions;
  final int inProgressSessions;
  final int participationDays;
  final int periodDays;
  final double? completionRate;
  final double? sessionsPerDay;
  final Map<String, int> sessionsByActivity;
  final Map<DateTime, int> sessionsByDay;
  final Map<DateTime, int> sessionsByWeek;

  const EngagementMetrics({
    required this.totalSessions,
    required this.completedSessions,
    required this.abandonedSessions,
    required this.inProgressSessions,
    required this.participationDays,
    required this.periodDays,
    required this.completionRate,
    required this.sessionsPerDay,
    required this.sessionsByActivity,
    required this.sessionsByDay,
    required this.sessionsByWeek,
  });

  factory EngagementMetrics.calculate(
    Iterable<ActivitySessionRecord> source,
    DateTime startUtc,
    DateTime endUtc,
  ) {
    final start = reportingUtcDate(startUtc);
    final end = reportingUtcDate(endUtc);
    final sessions = source.where((session) {
      final day = reportingUtcDate(session.startedAtUtc);
      return !day.isBefore(start) && !day.isAfter(end);
    }).toList();
    final completed = sessions.where((row) => row.status == 'completed').length;
    final abandoned = sessions.where((row) => row.status == 'abandoned').length;
    final inProgress =
        sessions.where((row) => row.status == 'in_progress').length;
    final finalCount = completed + abandoned;
    final byActivity = <String, int>{};
    final byDay = <DateTime, int>{};
    final byWeek = <DateTime, int>{};
    for (final session in sessions) {
      byActivity.update(session.activityName, (count) => count + 1,
          ifAbsent: () => 1);
      final day = reportingUtcDate(session.startedAtUtc);
      byDay.update(day, (count) => count + 1, ifAbsent: () => 1);
      final week = day.subtract(Duration(days: day.weekday - DateTime.monday));
      byWeek.update(week, (count) => count + 1, ifAbsent: () => 1);
    }
    final periodDays = end.difference(start).inDays + 1;
    return EngagementMetrics(
      totalSessions: sessions.length,
      completedSessions: completed,
      abandonedSessions: abandoned,
      inProgressSessions: inProgress,
      participationDays: byDay.length,
      periodDays: periodDays,
      completionRate: finalCount == 0 ? null : completed / finalCount,
      sessionsPerDay: periodDays <= 0 ? null : sessions.length / periodDays,
      sessionsByActivity: Map.unmodifiable(byActivity),
      sessionsByDay: Map.unmodifiable(byDay),
      sessionsByWeek: Map.unmodifiable(byWeek),
    );
  }
}
