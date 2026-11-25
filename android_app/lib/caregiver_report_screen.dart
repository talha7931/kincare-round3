import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_theme.dart';
import 'engagement_reporting.dart';
import 'offline_store.dart';

class CaregiverReportScreen extends StatefulWidget {
  final List<Map<String, dynamic>> profiles;
  final String caregiverName;
  final String? initialProfileId;
  final String? ownerId;

  const CaregiverReportScreen({
    super.key,
    required this.profiles,
    required this.caregiverName,
    this.initialProfileId,
    this.ownerId,
  });

  @override
  State<CaregiverReportScreen> createState() => _CaregiverReportScreenState();
}

class _CaregiverReportScreenState extends State<CaregiverReportScreen> {
  final _notesController = TextEditingController();
  bool _loading = true;
  bool _exporting = false;
  String? _error;
  String? _selectedProfileId;
  List<ActivitySessionRecord> _sessions = [];
  late DateTime _startUtc;
  late DateTime _endUtc;

  @override
  void initState() {
    super.initState();
    _selectedProfileId = widget.initialProfileId ??
        (widget.profiles.isEmpty
            ? null
            : widget.profiles.first['id'].toString());
    _endUtc = reportingUtcDate(DateTime.now().toUtc());
    _startUtc = _endUtc.subtract(const Duration(days: 29));
    _load();
  }

  @override
  void didUpdateWidget(covariant CaregiverReportScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final validIds = widget.profiles.map((row) => row['id'].toString()).toSet();
    if (!validIds.contains(_selectedProfileId)) {
      _selectedProfileId = widget.initialProfileId ??
          (widget.profiles.isEmpty
              ? null
              : widget.profiles.first['id'].toString());
      _load();
    }
  }

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = Supabase.instance.client;
      final data = await loadCaregiverReportingDataLocalFirst(
        client,
        OfflineStore.instance,
        widget.ownerId ?? client.auth.currentUser?.id ?? '',
        widget.profiles,
      );
      if (mounted)
        setState(() {
          _sessions = data.sessions;
          _loading = false;
        });
    } catch (error) {
      if (mounted)
        setState(() {
          _error = error.toString();
          _loading = false;
        });
    }
  }

  Future<void> _pickDate({required bool start}) async {
    final selected = await showDatePicker(
      context: context,
      initialDate: start ? _startUtc : _endUtc,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      helpText: start ? 'UTC period start' : 'UTC period end',
    );
    if (selected == null || !mounted) return;
    final day = DateTime.utc(selected.year, selected.month, selected.day);
    setState(() {
      if (start) {
        _startUtc = day;
        if (_startUtc.isAfter(_endUtc)) _endUtc = _startUtc;
      } else {
        _endUtc = day;
        if (_endUtc.isBefore(_startUtc)) _startUtc = _endUtc;
      }
    });
  }

  List<ActivitySessionRecord> get _profileSessions =>
      _sessions.where((row) => row.profileId == _selectedProfileId).toList();

  List<ActivitySessionRecord> get _periodSessions {
    return _profileSessions.where((session) {
      final date = reportingUtcDate(session.startedAtUtc);
      return !date.isBefore(_startUtc) && !date.isAfter(_endUtc);
    }).toList();
  }

  Map<String, dynamic>? get _selectedProfile {
    for (final profile in widget.profiles) {
      if (profile['id'].toString() == _selectedProfileId) return profile;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final metrics =
        EngagementMetrics.calculate(_profileSessions, _startUtc, _endUtc);
    return ListView(
      padding: const EdgeInsets.all(KinCareSpace.x4),
      children: [
        Text('Individual engagement report',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: KinCareColors.forest, fontWeight: FontWeight.w700)),
        const SizedBox(height: KinCareSpace.x3),
        Text(
            'Locally available: ${_sessions.length} activities · ${_sessions.where((row) => row.syncState != 'synced').length} waiting to sync. Cloud-confirmed records refresh when connected.',
            style: const TextStyle(color: KinCareColors.textMuted)),
        const SizedBox(height: KinCareSpace.x3),
        if (widget.profiles.isEmpty)
          const Card(
              child: Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('Add an elderly profile to prepare a report.')))
        else ...[
          DropdownButtonFormField<String>(
            value: _selectedProfileId,
            decoration: const InputDecoration(labelText: 'Elderly profile'),
            items: [
              for (final profile in widget.profiles)
                DropdownMenuItem(
                    value: profile['id'].toString(),
                    child:
                        Text(profile['display_name']?.toString() ?? 'Profile')),
            ],
            onChanged: (value) => setState(() => _selectedProfileId = value),
          ),
          const SizedBox(height: KinCareSpace.x3),
          _periodPicker(),
          const SizedBox(height: KinCareSpace.x3),
          if (_error != null)
            Card(
                child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(children: [
                      Text(_error!,
                          style: const TextStyle(color: KinCareColors.danger)),
                      const SizedBox(height: 12),
                      FilledButton(
                          onPressed: _load, child: const Text('Try again'))
                    ])))
          else if (_loading)
            const Center(
                child: Padding(
                    padding: EdgeInsets.all(28),
                    child: CircularProgressIndicator()))
          else ...[
            _summary(metrics),
            const SizedBox(height: KinCareSpace.x3),
            _sessionHistory(),
            const SizedBox(height: KinCareSpace.x3),
            TextField(
              controller: _notesController,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'Caregiver observations (optional)',
                helperText:
                    'Included only in this PDF; it is not saved to Supabase.',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: KinCareSpace.x3),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: _exporting ? null : () => _exportPdf(metrics),
                icon: const Icon(Icons.picture_as_pdf_outlined),
                label:
                    Text(_exporting ? 'Preparing PDF…' : 'Share or save PDF'),
              ),
            ),
            const SizedBox(height: KinCareSpace.x3),
            const Text(
                'This report summarizes recorded engagement. It is not a clinical diagnosis or medical assessment.',
                style: TextStyle(color: KinCareColors.textMuted)),
          ],
        ],
      ],
    );
  }

  Widget _periodPicker() => Card(
        child: Padding(
          padding: const EdgeInsets.all(KinCareSpace.x3),
          child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('Reporting period (UTC)'),
                OutlinedButton(
                    onPressed: () => _pickDate(start: true),
                    child: Text(_formatDay(_startUtc))),
                const Text('to'),
                OutlinedButton(
                    onPressed: () => _pickDate(start: false),
                    child: Text(_formatDay(_endUtc))),
                TextButton(
                    onPressed: () => setState(() {
                          _endUtc = reportingUtcDate(DateTime.now().toUtc());
                          _startUtc =
                              _endUtc.subtract(const Duration(days: 29));
                        }),
                    child: const Text('Last 30 days')),
              ]),
        ),
      );

  Widget _summary(EngagementMetrics metrics) => Card(
        child: Padding(
          padding: const EdgeInsets.all(KinCareSpace.x4),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_selectedProfile?['display_name']?.toString() ?? 'Profile',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(color: KinCareColors.forest)),
            Text(
                'Synced cloud activity · ${_formatDay(_startUtc)} to ${_formatDay(_endUtc)} UTC',
                style: const TextStyle(color: KinCareColors.textMuted)),
            const SizedBox(height: 12),
            Text('Sessions: ${metrics.totalSessions}'),
            Text(
                'Completed: ${metrics.completedSessions} · Stopped early: ${metrics.abandonedSessions} · In progress: ${metrics.inProgressSessions}'),
            Text(
                'Completion among finalized sessions: ${metrics.completionRate == null ? 'Unavailable' : '${(metrics.completionRate! * 100).round()}%'}'),
            Text(
                'Participation days: ${metrics.participationDays} of ${metrics.periodDays} calendar days'),
            Text(
                'Session frequency: ${metrics.sessionsPerDay?.toStringAsFixed(2) ?? 'Unavailable'} per calendar day'),
            const Divider(height: 24),
            const Text('Activity type breakdown',
                style: TextStyle(fontWeight: FontWeight.w700)),
            if (metrics.sessionsByActivity.isEmpty)
              const Text('No activity was recorded in this period.'),
            for (final entry in metrics.sessionsByActivity.entries)
              Text('${entry.key}: ${entry.value}'),
            const SizedBox(height: 12),
            const Text('Daily engagement',
                style: TextStyle(fontWeight: FontWeight.w700)),
            if (metrics.sessionsByDay.isEmpty)
              const Text('No participation days in this period.'),
            for (final entry
                in (metrics.sessionsByDay.entries.toList()
                  ..sort((a, b) => a.key.compareTo(b.key))))
              Text(
                  '${_formatDay(entry.key)} UTC: ${entry.value} session${entry.value == 1 ? '' : 's'}'),
            const SizedBox(height: 12),
            const Text('Weekly engagement (ISO week, Monday–Sunday UTC)',
                style: TextStyle(fontWeight: FontWeight.w700)),
            if (metrics.sessionsByWeek.isEmpty)
              const Text('No weekly activity in this period.'),
            for (final entry
                in (metrics.sessionsByWeek.entries.toList()
                  ..sort((a, b) => a.key.compareTo(b.key))))
              Text(
                  'Week of ${_formatDay(entry.key)}: ${entry.value} session${entry.value == 1 ? '' : 's'}'),
          ]),
        ),
      );

  Widget _sessionHistory() => Card(
        child: Padding(
          padding: const EdgeInsets.all(KinCareSpace.x4),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Activity history',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(color: KinCareColors.forest)),
            if (_periodSessions.isEmpty)
              const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text(
                      'No sessions are available for this profile and reporting period.'))
            else
              for (final session in _periodSessions)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(session.activityName),
                  subtitle: Text(
                      '${_formatTimestamp(session.startedAtUtc)} · ${session.displayStatus} · Duration: ${_formatDuration(session.elapsedDuration)}'),
                  children: [
                    if (session.responses.isEmpty)
                      const ListTile(
                          title: Text('No response details were recorded.'))
                    else
                      for (final response in session.responses)
                        ListTile(
                          dense: true,
                          title: Text(response.summary(session.activityKey)),
                          subtitle: Text('Response ${response.index + 1}'),
                        ),
                  ],
                ),
          ]),
        ),
      );

  Future<void> _exportPdf(EngagementMetrics metrics) async {
    final profile = _selectedProfile;
    if (profile == null) return;
    setState(() => _exporting = true);
    try {
      final document = pw.Document();
      final generatedAt = DateTime.now().toUtc();
      final activityRows = metrics.sessionsByActivity.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      final sessions = _periodSessions;
      final pendingLocal =
          sessions.where((row) => row.syncState != 'synced').length;
      final cloudConfirmed = sessions.length - pendingLocal;
      document.addPage(pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(36),
        header: (_) => pw.Container(
          padding: const pw.EdgeInsets.only(bottom: 10),
          decoration: const pw.BoxDecoration(
              border: pw.Border(
                  bottom: pw.BorderSide(color: PdfColor.fromInt(0xFF477568)))),
          child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text('KinCare',
                    style: pw.TextStyle(
                        fontSize: 18,
                        fontWeight: pw.FontWeight.bold,
                        color: const PdfColor.fromInt(0xFF183D35))),
                pw.Text('Engagement summary',
                    style: const pw.TextStyle(fontSize: 10)),
              ]),
        ),
        footer: (context) => pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text(
              'Page ${context.pageNumber} · Generated ${_formatTimestamp(generatedAt)}',
              style: const pw.TextStyle(
                  fontSize: 8, color: PdfColor.fromInt(0xFF5F6C68))),
        ),
        build: (_) => [
          pw.SizedBox(height: 16),
          pw.Text('Caregiver activity report',
              style: pw.TextStyle(
                  fontSize: 22,
                  fontWeight: pw.FontWeight.bold,
                  color: const PdfColor.fromInt(0xFF183D35))),
          pw.SizedBox(height: 12),
          pw.Text('Elderly profile: ${profile['display_name'] ?? 'Profile'}'),
          if (widget.caregiverName.trim().isNotEmpty)
            pw.Text('Caregiver: ${widget.caregiverName.trim()}'),
          pw.Text(
              'Reporting period: ${_formatDay(_startUtc)} to ${_formatDay(_endUtc)} UTC'),
          pw.Text('Generated: ${_formatTimestamp(generatedAt)}'),
          pw.SizedBox(height: 14),
          pw.Text('Coverage and metrics',
              style:
                  pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold)),
          pw.Text(
              'Coverage: $cloudConfirmed cloud-synchronized activities; $pendingLocal locally saved and waiting to synchronize; ${sessions.length} total available for this profile and period.'),
          pw.Text(
              'Sessions: ${metrics.totalSessions} · Completed: ${metrics.completedSessions} · Stopped early: ${metrics.abandonedSessions} · In progress: ${metrics.inProgressSessions}'),
          pw.Text(
              'Finalized-session completion rate: ${metrics.completionRate == null ? 'Unavailable' : '${(metrics.completionRate! * 100).round()}%'}'),
          pw.Text(
              'Participation days: ${metrics.participationDays} of ${metrics.periodDays} calendar days.'),
          pw.Text(
              'Session frequency: ${metrics.sessionsPerDay?.toStringAsFixed(2) ?? 'Unavailable'} sessions per calendar day.'),
          pw.Text(
              'Dates and trend groupings use UTC. Elapsed duration is shown only when stored start and completion timestamps are available.'),
          pw.SizedBox(height: 14),
          pw.Text('Activity type breakdown',
              style:
                  pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold)),
          if (activityRows.isEmpty)
            pw.Text('No activity was recorded in this period.')
          else
            pw.TableHelper.fromTextArray(
              headers: const ['Activity', 'Sessions'],
              data: [
                for (final row in activityRows) [row.key, row.value.toString()]
              ],
              headerDecoration:
                  const pw.BoxDecoration(color: PdfColor.fromInt(0xFFE5EEE8)),
              cellStyle: const pw.TextStyle(fontSize: 9),
              headerStyle:
                  pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
            ),
          pw.SizedBox(height: 14),
          pw.Text('Daily engagement (UTC)',
              style:
                  pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold)),
          if (metrics.sessionsByDay.isEmpty)
            pw.Text('No participation days in this period.')
          else
            for (final entry
                in (metrics.sessionsByDay.entries.toList()
                  ..sort((a, b) => a.key.compareTo(b.key))))
              pw.Text(
                  '${_formatDay(entry.key)}: ${entry.value} session${entry.value == 1 ? '' : 's'}'),
          pw.SizedBox(height: 14),
          pw.Text('Weekly engagement (ISO week, Monday–Sunday UTC)',
              style:
                  pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold)),
          if (metrics.sessionsByWeek.isEmpty)
            pw.Text('No weekly activity in this period.')
          else
            for (final entry
                in (metrics.sessionsByWeek.entries.toList()
                  ..sort((a, b) => a.key.compareTo(b.key))))
              pw.Text(
                  'Week of ${_formatDay(entry.key)}: ${entry.value} session${entry.value == 1 ? '' : 's'}'),
          pw.SizedBox(height: 14),
          pw.Text('Activity history',
              style:
                  pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold)),
          if (sessions.isEmpty)
            pw.Text('No sessions are available for this profile and period.')
          else
            for (final session in sessions) ...[
              pw.SizedBox(height: 7),
              pw.Text(
                  '${session.activityName} · ${_formatTimestamp(session.startedAtUtc)}'),
              pw.Text(
                  'Status: ${session.displayStatus} · Duration: ${_formatDuration(session.elapsedDuration)}',
                  style: const pw.TextStyle(fontSize: 9)),
              if (session.responses.isEmpty)
                pw.Text('No response details recorded.',
                    style: const pw.TextStyle(fontSize: 9))
              else
                for (final response in session.responses)
                  pw.Text('• ${response.summary(session.activityKey)}',
                      style: const pw.TextStyle(fontSize: 9)),
            ],
          if (_notesController.text.trim().isNotEmpty) ...[
            pw.SizedBox(height: 14),
            pw.Text('Caregiver observations',
                style:
                    pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold)),
            pw.Text(_notesController.text.trim()),
          ],
          pw.SizedBox(height: 18),
          pw.Container(
            padding: const pw.EdgeInsets.all(10),
            color: const PdfColor.fromInt(0xFFE5EEE8),
            child: pw.Text(
                'This report summarizes recorded engagement only. It is not a clinical diagnosis or medical assessment.',
                style:
                    pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
          ),
        ],
      ));
      final bytes = await document.save();
      final safeName = (profile['display_name']?.toString() ?? 'profile')
          .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
      await Printing.sharePdf(
        bytes: bytes,
        filename: 'kincare_${safeName}_${_formatDay(_endUtc)}.pdf',
      );
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('The PDF could not be prepared: $error')),
        );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }
}

String _formatDay(DateTime utc) =>
    '${utc.year.toString().padLeft(4, '0')}-${utc.month.toString().padLeft(2, '0')}-${utc.day.toString().padLeft(2, '0')}';

String _formatTimestamp(DateTime utc) =>
    '${_formatDay(utc)} ${utc.hour.toString().padLeft(2, '0')}:${utc.minute.toString().padLeft(2, '0')} UTC';

String _formatDuration(Duration? duration) {
  if (duration == null) return 'Unavailable';
  if (duration.inMinutes == 0) return 'Under 1 minute';
  if (duration.inHours == 0) return '${duration.inMinutes} min';
  final minutes = duration.inMinutes.remainder(60);
  return minutes == 0
      ? '${duration.inHours} hr'
      : '${duration.inHours} hr $minutes min';
}
