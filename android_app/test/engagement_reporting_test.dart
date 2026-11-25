import 'package:flutter_test/flutter_test.dart';
import 'package:kincare_android/engagement_reporting.dart';

void main() {
  DateTime utc(String value) => DateTime.parse(value).toUtc();

  ActivitySessionRecord session({
    required String id,
    required String status,
    required String startedAt,
    String activityName = 'Odd One Out',
    DateTime? completedAt,
    List<ActivityResponseRecord> responses = const [],
  }) =>
      ActivitySessionRecord(
        id: id,
        profileId: 'profile-1',
        activityTypeId: 'type-1',
        activityKey: 'odd_one_out',
        activityName: activityName,
        startedAtUtc: utc(startedAt),
        completedAtUtc: completedAt,
        status: status,
        responses: responses,
      );

  test('completion excludes in-progress sessions and days group in UTC weeks',
      () {
    final sessions = [
      session(id: '1', status: 'completed', startedAt: '2026-06-01T23:45:00Z'),
      session(id: '2', status: 'abandoned', startedAt: '2026-06-02T00:10:00Z'),
      session(
          id: '3', status: 'in_progress', startedAt: '2026-06-08T08:00:00Z'),
      session(id: '4', status: 'completed', startedAt: '2026-05-31T23:59:59Z'),
    ];

    final metrics = EngagementMetrics.calculate(
      sessions,
      DateTime.utc(2026, 6, 1),
      DateTime.utc(2026, 6, 7),
    );

    expect(metrics.totalSessions, 2);
    expect(metrics.completedSessions, 1);
    expect(metrics.abandonedSessions, 1);
    expect(metrics.inProgressSessions, 0);
    expect(metrics.completionRate, 0.5);
    expect(metrics.participationDays, 2);
    expect(metrics.periodDays, 7);
    expect(metrics.sessionsPerDay, closeTo(2 / 7, 0.0001));
    expect(metrics.sessionsByWeek[DateTime.utc(2026, 6, 1)], 2);
  });

  test('completion rate is unavailable when there are no finalized sessions',
      () {
    final metrics = EngagementMetrics.calculate(
      [
        session(
            id: '1', status: 'in_progress', startedAt: '2026-06-01T08:00:00Z')
      ],
      DateTime.utc(2026, 6, 1),
      DateTime.utc(2026, 6, 1),
    );
    expect(metrics.totalSessions, 1);
    expect(metrics.completionRate, isNull);
  });

  test('duration is derived only from stored timestamps', () {
    final completed = session(
      id: '1',
      status: 'completed',
      startedAt: '2026-06-01T10:00:00Z',
      completedAt: utc('2026-06-01T10:18:00Z'),
    );
    final incomplete = session(
      id: '2',
      status: 'abandoned',
      startedAt: '2026-06-01T10:00:00Z',
    );
    expect(completed.elapsedDuration, const Duration(minutes: 18));
    expect(incomplete.elapsedDuration, isNull);
  });

  test('memory responses are not misreported as sorting responses', () {
    final spoken = ActivityResponseRecord(
      index: 0,
      payload: const {'activity_type': 'memory_deck', 'response_kind': 'audio'},
      isCorrect: null,
    );
    final text = ActivityResponseRecord(
      index: 0,
      payload: const {
        'activity_type': 'memory_deck',
        'response_kind': 'text',
        'text': 'Hello'
      },
      isCorrect: null,
    );
    expect(spoken.summary('memory_decks'), 'Recorded a spoken response');
    expect(text.summary('memory_decks'), 'Shared a text response');
    expect(spoken.summary('memory_decks'), isNot(contains('placed in')));
  });
}
