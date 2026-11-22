import 'package:supabase_flutter/supabase_flutter.dart';

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
        payload['activity_type'] == 'memory_deck') {
      final text = payload['text']?.toString().trim();
      if (text != null && text.isNotEmpty) return 'Shared a text response';
      if (payload['response_kind'] == 'audio') {
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
