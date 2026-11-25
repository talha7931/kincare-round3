import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:record/record.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:path_provider/path_provider.dart';

import 'app_theme.dart';
import 'offline_store.dart';
import 'offline_sync.dart';

// ---------------------------------------------------------------------------
// Media helpers
// ---------------------------------------------------------------------------

Future<String> _getSignedUrl(SupabaseClient client, String storagePath) async {
  final response = await client.storage
      .from('kincare-media')
      .createSignedUrl(storagePath, 3600);
  return response;
}

// ---------------------------------------------------------------------------
// MemoryDecksScreen — deck list for a selected profile
// ---------------------------------------------------------------------------

class MemoryDecksScreen extends StatefulWidget {
  final User user;
  final Map<String, dynamic>? selectedProfile;

  const MemoryDecksScreen({
    super.key,
    required this.user,
    required this.selectedProfile,
  });

  @override
  State<MemoryDecksScreen> createState() => _MemoryDecksScreenState();
}

class _MemoryDecksScreenState extends State<MemoryDecksScreen> {
  final _client = Supabase.instance.client;

  List<Map<String, dynamic>> _decks = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadDecks();
  }

  @override
  void didUpdateWidget(MemoryDecksScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedProfile?['id'] != widget.selectedProfile?['id']) {
      _loadDecks();
    }
  }

  Future<void> _loadDecks() async {
    final profileId = widget.selectedProfile?['id']?.toString();
    if (profileId == null) {
      setState(() {
        _decks = [];
        _loading = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await _client
          .from('memory_decks')
          .select(
              'id, elderly_profile_id, created_by_caregiver_id, title, language_code, created_at, updated_at')
          .eq('elderly_profile_id', profileId)
          .order('created_at')
          .timeout(const Duration(seconds: 8));
      final deckList = List<Map<String, dynamic>>.from(data);
      for (final deck in deckList) {
        final cardSnapshotStartedAt = DateTime.now().toUtc();
        final countResult = await _client
            .from('memory_cards')
            .select(
                'id, deck_id, photo_asset_id, question_audio_asset_id, answer_audio_asset_id, question_text, answer_context, display_order')
            .eq('deck_id', deck['id'])
            .order('display_order');
        final cards = List<Map<String, dynamic>>.from(countResult);
        await OfflineStore.instance.cacheDeck(
            widget.user.id, profileId, deck, cards,
            remoteSnapshotStartedAt: cardSnapshotStartedAt);
      }
      final localDecks =
          await OfflineStore.instance.readDecks(widget.user.id, profileId);
      for (final deck in localDecks) {
        deck['_card_count'] = (await OfflineStore.instance
                .readCards(widget.user.id, deck['id'].toString()))
            .length;
      }
      if (mounted) setState(() => _decks = localDecks);
    } catch (e) {
      final localDecks =
          await OfflineStore.instance.readDecks(widget.user.id, profileId);
      for (final deck in localDecks) {
        deck['_card_count'] = (await OfflineStore.instance
                .readCards(widget.user.id, deck['id'].toString()))
            .length;
      }
      if (mounted) {
        setState(() {
          _decks = localDecks;
          if (localDecks.isEmpty) _error = e.toString();
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _createDeck() async {
    final profileId = widget.selectedProfile?['id']?.toString();
    if (profileId == null) return;

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => _DeckFormDialog(title: 'Create deck'),
    );
    if (result == null) return;

    try {
      final deck = <String, dynamic>{
        'id': const Uuid().v4(),
        'elderly_profile_id': profileId,
        'created_by_caregiver_id': widget.user.id,
        'title': result['title'],
        'language_code': result['language_code'],
        'created_at': DateTime.now().toUtc().toIso8601String(),
      };
      await OfflineStore.instance
          .saveDeckLocal(widget.user.id, profileId, deck);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content:
                Text('Deck saved on this device; waiting to synchronize.')));
      }
      await _loadDecks();
      unawaited(OfflineSyncService(_client).initialize(widget.user.id));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to create deck: $e')),
        );
      }
    }
  }

  Future<void> _editDeck(Map<String, dynamic> deck) async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => _DeckFormDialog(
        title: 'Edit deck',
        initialTitle: deck['title']?.toString(),
        initialLanguage: deck['language_code']?.toString(),
      ),
    );
    if (result == null) return;

    try {
      final updated = <String, dynamic>{
        ...deck,
        'title': result['title'],
        'language_code': result['language_code'],
        'updated_at': DateTime.now().toIso8601String(),
      };
      await OfflineStore.instance.saveDeckLocal(
          widget.user.id, widget.selectedProfile!['id'].toString(), updated);
      await _loadDecks();
      unawaited(OfflineSyncService(_client).initialize(widget.user.id));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update deck: $e')),
        );
      }
    }
  }

  Future<void> _deleteDeck(Map<String, dynamic> deck) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete deck'),
        content: Text(
            'Delete "${deck['title']}"? All cards in this deck will also be deleted.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style:
                FilledButton.styleFrom(backgroundColor: KinCareColors.danger),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await OfflineStore.instance
          .deleteDeckLocal(widget.user.id, deck['id'].toString());
      await _loadDecks();
      unawaited(OfflineSyncService(_client).initialize(widget.user.id));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete deck: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final profileId = widget.selectedProfile?['id']?.toString();

    if (profileId == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(KinCareSpace.x7),
          child: Text(
            'Select an elderly profile on the left to manage their Memory Decks.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              color: KinCareColors.textMuted,
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header bar
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: KinCareSpace.x4,
            vertical: KinCareSpace.x3,
          ),
          decoration: const BoxDecoration(
            border: Border(
              bottom: BorderSide(color: KinCareColors.line),
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.photo_album_outlined,
                  color: KinCareColors.forest, size: 22),
              const SizedBox(width: KinCareSpace.x2),
              Expanded(
                child: Text(
                  'Memory Decks — ${widget.selectedProfile!['display_name']}',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: KinCareColors.forest,
                  ),
                ),
              ),
              FilledButton.icon(
                onPressed: _createDeck,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('New deck'),
              ),
            ],
          ),
        ),

        // Body
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? _ErrorView(error: _error!, onRetry: _loadDecks)
                  : _decks.isEmpty
                      ? _EmptyDecks(onCreateDeck: _createDeck)
                      : _DeckGrid(
                          decks: _decks,
                          onTap: (deck) => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => DeckDetailScreen(
                                deck: deck,
                                user: widget.user,
                                elderlyProfileId: profileId,
                              ),
                            ),
                          ).then((_) => _loadDecks()),
                          onEdit: _editDeck,
                          onDelete: _deleteDeck,
                        ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Deck grid
// ---------------------------------------------------------------------------

class _DeckGrid extends StatelessWidget {
  final List<Map<String, dynamic>> decks;
  final void Function(Map<String, dynamic>) onTap;
  final void Function(Map<String, dynamic>) onEdit;
  final void Function(Map<String, dynamic>) onDelete;

  const _DeckGrid({
    required this.decks,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.all(KinCareSpace.x4),
      itemCount: decks.length,
      separatorBuilder: (_, __) => const SizedBox(height: KinCareSpace.x3),
      itemBuilder: (ctx, i) {
        final deck = decks[i];
        final cardCount = deck['_card_count'] as int? ?? 0;
        final lang = languageLabel(deck['language_code']);

        return Card(
          child: InkWell(
            borderRadius: BorderRadius.circular(KinCareRadii.lg),
            onTap: () => onTap(deck),
            child: Padding(
              padding: const EdgeInsets.all(KinCareSpace.x4),
              child: Row(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: KinCareColors.paleSage,
                      borderRadius: BorderRadius.circular(KinCareRadii.md),
                    ),
                    child: const Icon(Icons.photo_album,
                        color: KinCareColors.forest, size: 28),
                  ),
                  const SizedBox(width: KinCareSpace.x3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          deck['title']?.toString() ?? '(untitled)',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: KinCareColors.forest,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Wrap(
                          spacing: KinCareSpace.x2,
                          runSpacing: KinCareSpace.x1,
                          children: [
                            _Chip(label: lang),
                            _Chip(
                                label:
                                    '$cardCount card${cardCount == 1 ? '' : 's'}'),
                            _Chip(
                                label: _deckSyncLabel(
                                    deck['_sync_state']?.toString() ??
                                        'synced')),
                          ],
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Edit deck',
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    onPressed: () => onEdit(deck),
                  ),
                  IconButton(
                    tooltip: 'Delete deck',
                    icon: const Icon(Icons.delete_outline,
                        size: 20, color: KinCareColors.danger),
                    onPressed: () => onDelete(deck),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  const _Chip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: KinCareColors.paleSage,
        borderRadius: BorderRadius.circular(KinCareRadii.xs),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: KinCareColors.sage,
        ),
      ),
    );
  }
}

String _deckSyncLabel(String state) => switch (state) {
      'pending_create' ||
      'pending_update' ||
      'pending_delete' ||
      'local_only' =>
        'Saved here · waiting to sync',
      'failed' => 'Sync failed',
      'conflict' => 'Needs review',
      _ => 'Synced',
    };

// ---------------------------------------------------------------------------
// Empty + error states
// ---------------------------------------------------------------------------

class _EmptyDecks extends StatelessWidget {
  final VoidCallback onCreateDeck;
  const _EmptyDecks({required this.onCreateDeck});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(KinCareSpace.x7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.photo_album_outlined,
                size: 64, color: KinCareColors.cloud),
            const SizedBox(height: KinCareSpace.x4),
            const Text('No memory decks yet',
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: KinCareColors.forest)),
            const SizedBox(height: KinCareSpace.x2),
            const Text('Create a deck and add photo cards to it.',
                style: TextStyle(color: KinCareColors.textMuted),
                textAlign: TextAlign.center),
            const SizedBox(height: KinCareSpace.x5),
            FilledButton.icon(
              onPressed: onCreateDeck,
              icon: const Icon(Icons.add),
              label: const Text('Create first deck'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  const _ErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(KinCareSpace.x7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline,
                size: 48, color: KinCareColors.danger),
            const SizedBox(height: KinCareSpace.x3),
            Text(error,
                textAlign: TextAlign.center,
                style: const TextStyle(color: KinCareColors.danger)),
            const SizedBox(height: KinCareSpace.x4),
            OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Deck form dialog (create + edit)
// ---------------------------------------------------------------------------

class _DeckFormDialog extends StatefulWidget {
  final String title;
  final String? initialTitle;
  final String? initialLanguage;

  const _DeckFormDialog({
    required this.title,
    this.initialTitle,
    this.initialLanguage,
  });

  @override
  State<_DeckFormDialog> createState() => _DeckFormDialogState();
}

class _DeckFormDialogState extends State<_DeckFormDialog> {
  late final TextEditingController _titleController;
  late String _language;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.initialTitle ?? '');
    _language = widget.initialLanguage ?? 'en';
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _titleController,
            decoration: const InputDecoration(labelText: 'Deck title'),
            autofocus: true,
          ),
          const SizedBox(height: KinCareSpace.x3),
          DropdownButtonFormField<String>(
            initialValue: _language,
            decoration: const InputDecoration(labelText: 'Language'),
            items: const [
              DropdownMenuItem(value: 'en', child: Text('English')),
              DropdownMenuItem(value: 'hi', child: Text('Hindi')),
              DropdownMenuItem(value: 'mr', child: Text('Marathi')),
            ],
            onChanged: (v) => setState(() => _language = v ?? 'en'),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final t = _titleController.text.trim();
            if (t.isEmpty) return;
            Navigator.pop(context, {'title': t, 'language_code': _language});
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// DeckDetailScreen — card list for a deck
// ---------------------------------------------------------------------------

class DeckDetailScreen extends StatefulWidget {
  final Map<String, dynamic> deck;
  final User user;
  final String elderlyProfileId;

  const DeckDetailScreen({
    super.key,
    required this.deck,
    required this.user,
    required this.elderlyProfileId,
  });

  @override
  State<DeckDetailScreen> createState() => _DeckDetailScreenState();
}

class _DeckDetailScreenState extends State<DeckDetailScreen> {
  final _client = Supabase.instance.client;
  final _store = OfflineStore.instance;

  List<Map<String, dynamic>> _cards = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadCards();
  }

  Future<void> _loadCards() async {
    setState(() {
      if (_cards.isEmpty) _loading = true;
      _error = null;
    });
    try {
      final cached =
          await _store.readCards(widget.user.id, widget.deck['id'].toString());
      if (cached.isNotEmpty && mounted) {
        setState(() {
          _cards = cached;
          _loading = false;
        });
      }
      final cardSnapshotStartedAt = DateTime.now().toUtc();
      final data = await _client
          .from('memory_cards')
          .select(
              'id, deck_id, photo_asset_id, question_audio_asset_id, answer_audio_asset_id, question_text, answer_context, display_order')
          .eq('deck_id', widget.deck['id'])
          .order('display_order')
          .timeout(const Duration(seconds: 8));
      final cards = List<Map<String, dynamic>>.from(data);
      await _store.cacheDeck(
          widget.user.id, widget.elderlyProfileId, widget.deck, cards,
          remoteSnapshotStartedAt: cardSnapshotStartedAt);
      final local =
          await _store.readCards(widget.user.id, widget.deck['id'].toString());
      if (mounted) setState(() => _cards = local);
    } catch (e) {
      final local =
          await _store.readCards(widget.user.id, widget.deck['id'].toString());
      if (mounted) {
        setState(() {
          _cards = local;
          if (local.isEmpty) _error = e.toString();
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _deleteCard(Map<String, dynamic> card) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete card'),
        content: const Text('Delete this memory card?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style:
                FilledButton.styleFrom(backgroundColor: KinCareColors.danger),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _store.deleteCardLocal(widget.user.id, card['id'].toString());
      await _loadCards();
      unawaited(OfflineSyncService(_client).initialize(widget.user.id));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete card: $e')),
        );
      }
    }
  }

  Future<void> _reorderCards(int oldIndex, int newIndex) async {
    final reordered = List<Map<String, dynamic>>.from(_cards);
    final card = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, card);
    setState(() => _cards = reordered);
    try {
      await _store.reorderCardsLocal(
          widget.user.id,
          widget.deck['id'].toString(),
          reordered.map((item) => item['id'].toString()).toList());
      await _loadCards();
      unawaited(OfflineSyncService(_client).initialize(widget.user.id));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not reorder cards: $error')),
        );
        await _loadCards();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.deck['title']?.toString() ?? 'Deck'),
        actions: [
          FilledButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => CardEditorScreen(
                  deck: widget.deck,
                  user: widget.user,
                  elderlyProfileId: widget.elderlyProfileId,
                ),
              ),
            ).then((_) => _loadCards()),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add card'),
          ),
          const SizedBox(width: KinCareSpace.x3),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorView(error: _error!, onRetry: _loadCards)
              : _cards.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(KinCareSpace.x7),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.photo_library_outlined,
                                size: 64, color: KinCareColors.cloud),
                            const SizedBox(height: KinCareSpace.x4),
                            const Text('No cards in this deck',
                                style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600,
                                    color: KinCareColors.forest)),
                            const SizedBox(height: KinCareSpace.x2),
                            const Text(
                                'Add a card with a photo, question and answer.',
                                style:
                                    TextStyle(color: KinCareColors.textMuted),
                                textAlign: TextAlign.center),
                            const SizedBox(height: KinCareSpace.x5),
                            FilledButton.icon(
                              onPressed: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => CardEditorScreen(
                                    deck: widget.deck,
                                    user: widget.user,
                                    elderlyProfileId: widget.elderlyProfileId,
                                  ),
                                ),
                              ).then((_) => _loadCards()),
                              icon: const Icon(Icons.add),
                              label: const Text('Add first card'),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ReorderableListView.builder(
                      onReorderItem: _reorderCards,
                      padding: const EdgeInsets.all(KinCareSpace.x4),
                      itemCount: _cards.length,
                      itemBuilder: (ctx, i) => Padding(
                        key: ValueKey(_cards[i]['id']),
                        padding: const EdgeInsets.only(bottom: KinCareSpace.x3),
                        child: ReorderableDelayedDragStartListener(
                          index: i,
                          child: _CardTile(
                            card: _cards[i],
                            client: _client,
                            ownerId: widget.user.id,
                            onEdit: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => CardEditorScreen(
                                  deck: widget.deck,
                                  user: widget.user,
                                  elderlyProfileId: widget.elderlyProfileId,
                                  existingCard: _cards[i],
                                ),
                              ),
                            ).then((_) => _loadCards()),
                            onDelete: () => _deleteCard(_cards[i]),
                          ),
                        ),
                      ),
                    ),
    );
  }
}

// ---------------------------------------------------------------------------
// Card tile (shown in DeckDetailScreen)
// ---------------------------------------------------------------------------

class _CardTile extends StatefulWidget {
  final Map<String, dynamic> card;
  final SupabaseClient client;
  final String ownerId;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _CardTile({
    required this.card,
    required this.client,
    required this.ownerId,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  State<_CardTile> createState() => _CardTileState();
}

class _CardTileState extends State<_CardTile> {
  String? _photoUrl;
  String? _localPhotoPath;
  bool _loadingPhoto = false;

  @override
  void initState() {
    super.initState();
    _loadPhoto();
  }

  Future<void> _loadPhoto() async {
    final assetId = widget.card['photo_asset_id']?.toString();
    if (assetId == null) return;

    try {
      setState(() => _loadingPhoto = true);
      final localPath =
          await OfflineStore.instance.mediaPath(widget.ownerId, assetId);
      if (localPath != null) {
        if (mounted) setState(() => _localPhotoPath = localPath);
        return;
      }
      final assetRow = await widget.client
          .from('media_assets')
          .select('storage_path')
          .eq('id', assetId)
          .maybeSingle();
      if (assetRow == null) return;
      final url = await _getSignedUrl(widget.client, assetRow['storage_path']);
      if (mounted) setState(() => _photoUrl = url);
    } catch (_) {
      // non-fatal
    } finally {
      if (mounted) setState(() => _loadingPhoto = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    final hasQuestionAudio = card['question_audio_asset_id'] != null;
    final hasAnswerAudio = card['answer_audio_asset_id'] != null;
    final syncState = card['_sync_state']?.toString() ?? 'synced';
    final syncMessage = switch (syncState) {
      'pending_create' ||
      'pending_update' ||
      'local_only' =>
        'Saved on this device; waiting to sync.',
      'failed' =>
        'Sync failed. Card is still saved here; use Sync Now to retry.',
      'conflict' => 'Sync needs review. Card is still saved here.',
      _ => null,
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(KinCareSpace.x3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Photo thumbnail
            ClipRRect(
              borderRadius: BorderRadius.circular(KinCareRadii.md),
              child: SizedBox(
                width: 80,
                height: 80,
                child: _loadingPhoto
                    ? const Center(
                        child: SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2)))
                    : _localPhotoPath != null
                        ? Image.file(File(_localPhotoPath!),
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => _photoPlaceholder())
                        : _photoUrl != null
                            ? Image.network(_photoUrl!,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) =>
                                    _photoPlaceholder())
                            : _photoPlaceholder(),
              ),
            ),
            const SizedBox(width: KinCareSpace.x3),
            // Text content
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    card['question_text']?.toString() ?? '',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: KinCareColors.forest,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    card['answer_context']?.toString() ?? '',
                    style: const TextStyle(
                        fontSize: 13, color: KinCareColors.textMuted),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      if (hasQuestionAudio) const _Chip(label: '🎤 Q audio'),
                      if (hasQuestionAudio && hasAnswerAudio)
                        const SizedBox(width: 4),
                      if (hasAnswerAudio) const _Chip(label: '🔊 A audio'),
                    ],
                  ),
                  if (syncMessage != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      syncMessage,
                      style: TextStyle(
                        fontSize: 12,
                        color: syncState == 'failed' || syncState == 'conflict'
                            ? KinCareColors.danger
                            : KinCareColors.textMuted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // Actions
            Column(
              children: [
                IconButton(
                  tooltip: 'Edit',
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  onPressed: widget.onEdit,
                ),
                IconButton(
                  tooltip: 'Delete',
                  icon: const Icon(Icons.delete_outline,
                      size: 20, color: KinCareColors.danger),
                  onPressed: widget.onDelete,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _photoPlaceholder() {
    return Container(
      color: KinCareColors.paleSage,
      child:
          const Icon(Icons.image_outlined, size: 36, color: KinCareColors.sage),
    );
  }
}

// ---------------------------------------------------------------------------
// CardEditorScreen — create / edit a memory card
// ---------------------------------------------------------------------------

class CardEditorScreen extends StatefulWidget {
  final Map<String, dynamic> deck;
  final User user;
  final String elderlyProfileId;
  final Map<String, dynamic>? existingCard;

  const CardEditorScreen({
    super.key,
    required this.deck,
    required this.user,
    required this.elderlyProfileId,
    this.existingCard,
  });

  @override
  State<CardEditorScreen> createState() => _CardEditorScreenState();
}

class _CardEditorScreenState extends State<CardEditorScreen> {
  final _client = Supabase.instance.client;
  final _store = OfflineStore.instance;
  late final String _cardId;

  final _questionController = TextEditingController();
  final _answerController = TextEditingController();
  final _orderController = TextEditingController(text: '0');

  File? _photoFile;
  String? _existingPhotoAssetId;
  String? _existingPhotoUrl;
  bool _photoIsDurable = false;

  File? _questionAudioFile;
  String? _existingQuestionAudioAssetId;
  bool _questionAudioIsDurable = false;
  bool _recordingQuestion = false;

  File? _answerAudioFile;
  String? _existingAnswerAudioAssetId;
  bool _answerAudioIsDurable = false;
  bool _recordingAnswer = false;

  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();
  String? _tempRecordPath;
  bool _playingQuestion = false;
  bool _playingAnswer = false;

  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _cardId = widget.existingCard?['id']?.toString() ?? const Uuid().v4();
    final card = widget.existingCard;
    if (card != null) {
      _questionController.text = card['question_text']?.toString() ?? '';
      _answerController.text = card['answer_context']?.toString() ?? '';
      _orderController.text = card['display_order']?.toString() ?? '0';
      _existingPhotoAssetId = card['photo_asset_id']?.toString();
      _existingQuestionAudioAssetId =
          card['question_audio_asset_id']?.toString();
      _existingAnswerAudioAssetId = card['answer_audio_asset_id']?.toString();
      _loadExistingMedia();
    }

    _player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playingQuestion = false;
          _playingAnswer = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _questionController.dispose();
    _answerController.dispose();
    _orderController.dispose();
    _recorder.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _loadExistingMedia() async {
    final photoId = _existingPhotoAssetId;
    final questionId = _existingQuestionAudioAssetId;
    final answerId = _existingAnswerAudioAssetId;
    try {
      final photoPath = photoId == null
          ? null
          : await _store.mediaPath(widget.user.id, photoId);
      final questionPath = questionId == null
          ? null
          : await _store.mediaPath(widget.user.id, questionId);
      final answerPath = answerId == null
          ? null
          : await _store.mediaPath(widget.user.id, answerId);
      if (mounted && photoPath != null) {
        setState(() {
          _photoFile = File(photoPath);
          _photoIsDurable = true;
        });
      }
      if (mounted && questionPath != null) {
        setState(() {
          _questionAudioFile = File(questionPath);
          _questionAudioIsDurable = true;
        });
      }
      if (mounted && answerPath != null) {
        setState(() {
          _answerAudioFile = File(answerPath);
          _answerAudioIsDurable = true;
        });
      }
      if (photoPath != null || photoId == null) return;
      final row = await _client
          .from('media_assets')
          .select('storage_path')
          .eq('id', photoId)
          .maybeSingle();
      if (row != null && mounted) {
        final url = await _getSignedUrl(_client, row['storage_path']);
        setState(() => _existingPhotoUrl = url);
      }
    } catch (_) {
      // The card can still be edited using its text and stored asset IDs.
    }
  }

  // ---- Photo ---------------------------------------------------------------

  Future<void> _pickPhoto() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
    );
    if (picked != null && mounted) {
      setState(() {
        _photoFile = File(picked.path);
        _photoIsDurable = false;
      });
    }
  }

  // ---- Recording -----------------------------------------------------------

  Future<String> _tempAudioPath() async {
    final root = await getApplicationSupportDirectory();
    final dir =
        Directory('${root.path}${Platform.pathSeparator}pending-recordings');
    await dir.create(recursive: true);
    final id = const Uuid().v4();
    return '${dir.path}/$id.m4a';
  }

  Future<void> _startRecording(String role) async {
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content:
                  Text('Microphone permission denied. Grant it in Settings.')),
        );
      }
      return;
    }
    _tempRecordPath = await _tempAudioPath();
    await _recorder.start(const RecordConfig(), path: _tempRecordPath!);
    if (mounted) {
      setState(() {
        if (role == 'question') _recordingQuestion = true;
        if (role == 'answer') _recordingAnswer = true;
      });
    }
  }

  Future<void> _stopRecording(String role) async {
    final path = await _recorder.stop();
    if (path == null) return;
    final file = File(path);
    if (mounted) {
      setState(() {
        if (role == 'question') {
          _questionAudioFile = file;
          _questionAudioIsDurable = false;
          _recordingQuestion = false;
        }
        if (role == 'answer') {
          _answerAudioFile = file;
          _answerAudioIsDurable = false;
          _recordingAnswer = false;
        }
      });
    }
  }

  // ---- Playback -----------------------------------------------------------

  Future<void> _playLocal(File file, String role) async {
    await _player.stop();
    setState(() {
      _playingQuestion = role == 'question';
      _playingAnswer = role == 'answer';
    });
    await _player.play(DeviceFileSource(file.path));
  }

  Future<void> _playRemote(String assetId, String role) async {
    try {
      final localPath = await _store.mediaPath(widget.user.id, assetId);
      if (localPath != null) {
        await _player.stop();
        setState(() {
          _playingQuestion = role == 'question';
          _playingAnswer = role == 'answer';
        });
        await _player.play(DeviceFileSource(localPath));
        return;
      }
      final row = await _client
          .from('media_assets')
          .select('storage_path')
          .eq('id', assetId)
          .maybeSingle();
      if (row == null) return;
      final url = await _getSignedUrl(_client, row['storage_path']);
      await _player.stop();
      setState(() {
        _playingQuestion = role == 'question';
        _playingAnswer = role == 'answer';
      });
      await _player.play(UrlSource(url));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Playback error: $e')));
      }
    }
  }

  // ---- Save ---------------------------------------------------------------

  Future<void> _save() async {
    final question = _questionController.text.trim();
    final answer = _answerController.text.trim();
    if (question.isEmpty || answer.isEmpty) {
      setState(() => _error = 'Question text and answer context are required.');
      return;
    }
    if (_photoFile == null && _existingPhotoAssetId == null) {
      setState(() => _error = 'A photo is required for each card.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      String photoAssetId = _existingPhotoAssetId ?? '';
      if (_photoFile != null && !_photoIsDurable) {
        photoAssetId = const Uuid().v4();
        final path = await _store.importLocalMedia(
          ownerId: widget.user.id,
          assetId: photoAssetId,
          profileId: widget.elderlyProfileId,
          deckId: widget.deck['id'].toString(),
          cardId: _cardId,
          mediaType: 'photo',
          mimeType: 'image/jpeg',
          source: _photoFile!,
        );
        _photoFile = File(path);
        _photoIsDurable = true;
      }

      String? questionAudioAssetId = _existingQuestionAudioAssetId;
      if (_questionAudioFile != null && !_questionAudioIsDurable) {
        questionAudioAssetId = const Uuid().v4();
        final path = await _store.importLocalMedia(
          ownerId: widget.user.id,
          assetId: questionAudioAssetId,
          profileId: widget.elderlyProfileId,
          deckId: widget.deck['id'].toString(),
          cardId: _cardId,
          mediaType: 'question_audio',
          mimeType: 'audio/m4a',
          source: _questionAudioFile!,
        );
        _questionAudioFile = File(path);
        _questionAudioIsDurable = true;
      }

      String? answerAudioAssetId = _existingAnswerAudioAssetId;
      if (_answerAudioFile != null && !_answerAudioIsDurable) {
        answerAudioAssetId = const Uuid().v4();
        final path = await _store.importLocalMedia(
          ownerId: widget.user.id,
          assetId: answerAudioAssetId,
          profileId: widget.elderlyProfileId,
          deckId: widget.deck['id'].toString(),
          cardId: _cardId,
          mediaType: 'answer_audio',
          mimeType: 'audio/m4a',
          source: _answerAudioFile!,
        );
        _answerAudioFile = File(path);
        _answerAudioIsDurable = true;
      }

      final displayOrder = int.tryParse(_orderController.text) ?? 0;
      final cardData = {
        'id': _cardId,
        'deck_id': widget.deck['id'],
        'photo_asset_id': photoAssetId,
        'question_audio_asset_id': questionAudioAssetId,
        'answer_audio_asset_id': answerAudioAssetId,
        'question_text': question,
        'answer_context': answer,
        'display_order': displayOrder,
      };

      await _store.saveCardLocal(
          widget.user.id, widget.deck['id'].toString(), cardData);
      unawaited(OfflineSyncService(_client).initialize(widget.user.id));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content:
                Text('Card saved on this device; waiting to synchronize.')));
      }

      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() => _error = 'Failed to save card: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ---- UI -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existingCard != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? 'Edit card' : 'Add card'),
        actions: [
          _saving
              ? const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : FilledButton(
                  onPressed: _save,
                  child: const Text('Save'),
                ),
          const SizedBox(width: KinCareSpace.x3),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(KinCareSpace.x4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null) ...[
              Container(
                padding: const EdgeInsets.all(KinCareSpace.x3),
                decoration: BoxDecoration(
                  color: KinCareColors.dangerWash,
                  border: Border.all(color: KinCareColors.dangerLine),
                  borderRadius: BorderRadius.circular(KinCareRadii.sm),
                ),
                child: Text(_error!,
                    style: const TextStyle(color: KinCareColors.danger)),
              ),
              const SizedBox(height: KinCareSpace.x4),
            ],

            // Photo section
            _SectionLabel(label: 'Photo', required: true),
            const SizedBox(height: KinCareSpace.x2),
            _PhotoPicker(
              file: _photoFile,
              existingUrl: _existingPhotoUrl,
              onPick: _pickPhoto,
            ),
            const SizedBox(height: KinCareSpace.x5),

            // Question text
            _SectionLabel(label: 'Question text', required: true),
            const SizedBox(height: KinCareSpace.x2),
            TextField(
              controller: _questionController,
              decoration: const InputDecoration(
                hintText: 'e.g. Who is in this photo?',
              ),
              maxLines: 2,
            ),
            const SizedBox(height: KinCareSpace.x5),

            // Answer context
            _SectionLabel(label: 'Answer context', required: true),
            const SizedBox(height: KinCareSpace.x2),
            TextField(
              controller: _answerController,
              decoration: const InputDecoration(
                hintText: 'e.g. That is your daughter Priya at her wedding.',
              ),
              maxLines: 3,
            ),
            const SizedBox(height: KinCareSpace.x5),

            // Question audio
            _SectionLabel(label: 'Question audio (optional)'),
            const SizedBox(height: KinCareSpace.x2),
            _AudioRecorderWidget(
              label: 'question',
              isRecording: _recordingQuestion,
              hasLocalFile: _questionAudioFile != null,
              hasRemoteAsset: _existingQuestionAudioAssetId != null,
              isPlaying: _playingQuestion,
              onStartRecord: () => _startRecording('question'),
              onStopRecord: () => _stopRecording('question'),
              onPlayLocal: _questionAudioFile != null
                  ? () => _playLocal(_questionAudioFile!, 'question')
                  : null,
              onPlayRemote: _existingQuestionAudioAssetId != null
                  ? () =>
                      _playRemote(_existingQuestionAudioAssetId!, 'question')
                  : null,
              onStopPlay: () async {
                await _player.stop();
                setState(() => _playingQuestion = false);
              },
            ),
            const SizedBox(height: KinCareSpace.x5),

            // Answer audio
            _SectionLabel(label: 'Answer audio (optional)'),
            const SizedBox(height: KinCareSpace.x2),
            _AudioRecorderWidget(
              label: 'answer',
              isRecording: _recordingAnswer,
              hasLocalFile: _answerAudioFile != null,
              hasRemoteAsset: _existingAnswerAudioAssetId != null,
              isPlaying: _playingAnswer,
              onStartRecord: () => _startRecording('answer'),
              onStopRecord: () => _stopRecording('answer'),
              onPlayLocal: _answerAudioFile != null
                  ? () => _playLocal(_answerAudioFile!, 'answer')
                  : null,
              onPlayRemote: _existingAnswerAudioAssetId != null
                  ? () => _playRemote(_existingAnswerAudioAssetId!, 'answer')
                  : null,
              onStopPlay: () async {
                await _player.stop();
                setState(() => _playingAnswer = false);
              },
            ),
            const SizedBox(height: KinCareSpace.x5),

            // Display order
            _SectionLabel(label: 'Display order'),
            const SizedBox(height: KinCareSpace.x2),
            TextField(
              controller: _orderController,
              decoration: const InputDecoration(hintText: '0 = first'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: KinCareSpace.x7),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sub-widgets for CardEditorScreen
// ---------------------------------------------------------------------------

class _SectionLabel extends StatelessWidget {
  final String label;
  final bool required;
  const _SectionLabel({required this.label, this.required = false});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: KinCareColors.charcoal,
          ),
        ),
        if (required)
          const Text(' *',
              style: TextStyle(color: KinCareColors.danger, fontSize: 14)),
      ],
    );
  }
}

class _PhotoPicker extends StatelessWidget {
  final File? file;
  final String? existingUrl;
  final VoidCallback onPick;

  const _PhotoPicker({
    required this.file,
    required this.existingUrl,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    Widget preview;
    if (file != null) {
      preview = Image.file(file!, fit: BoxFit.cover);
    } else if (existingUrl != null) {
      preview = Image.network(existingUrl!,
          fit: BoxFit.cover, errorBuilder: (_, __, ___) => _placeholder());
    } else {
      preview = _placeholder();
    }

    return GestureDetector(
      onTap: onPick,
      child: Container(
        height: 180,
        decoration: BoxDecoration(
          color: KinCareColors.paleSage,
          borderRadius: BorderRadius.circular(KinCareRadii.md),
          border: Border.all(color: KinCareColors.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            preview,
            Positioned(
              right: KinCareSpace.x2,
              bottom: KinCareSpace.x2,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: KinCareSpace.x3, vertical: KinCareSpace.x1),
                decoration: BoxDecoration(
                  color: KinCareColors.forest.withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(KinCareRadii.xs),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.photo_camera,
                        size: 14, color: KinCareColors.white),
                    SizedBox(width: 4),
                    Text('Change photo',
                        style: TextStyle(
                            fontSize: 12,
                            color: KinCareColors.white,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder() {
    return const Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.add_photo_alternate_outlined,
            size: 48, color: KinCareColors.sage),
        SizedBox(height: 8),
        Text('Tap to add photo',
            style: TextStyle(color: KinCareColors.textMuted, fontSize: 14)),
      ],
    );
  }
}

class _AudioRecorderWidget extends StatelessWidget {
  final String label;
  final bool isRecording;
  final bool hasLocalFile;
  final bool hasRemoteAsset;
  final bool isPlaying;
  final VoidCallback onStartRecord;
  final VoidCallback onStopRecord;
  final VoidCallback? onPlayLocal;
  final VoidCallback? onPlayRemote;
  final VoidCallback onStopPlay;

  const _AudioRecorderWidget({
    required this.label,
    required this.isRecording,
    required this.hasLocalFile,
    required this.hasRemoteAsset,
    required this.isPlaying,
    required this.onStartRecord,
    required this.onStopRecord,
    this.onPlayLocal,
    this.onPlayRemote,
    required this.onStopPlay,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(KinCareSpace.x3),
      decoration: BoxDecoration(
        color: KinCareColors.white,
        border: Border.all(color: KinCareColors.lineStrong),
        borderRadius: BorderRadius.circular(KinCareRadii.sm),
      ),
      child: Row(
        children: [
          // Record button
          isRecording
              ? FilledButton.icon(
                  onPressed: onStopRecord,
                  icon: const Icon(Icons.stop_circle_outlined,
                      color: KinCareColors.white),
                  label: const Text('Stop'),
                  style: FilledButton.styleFrom(
                      backgroundColor: KinCareColors.danger),
                )
              : OutlinedButton.icon(
                  onPressed: onStartRecord,
                  icon: const Icon(Icons.mic_outlined),
                  label: const Text('Record'),
                ),
          const SizedBox(width: KinCareSpace.x2),

          // Status
          if (isRecording)
            const Text('Recording…',
                style: TextStyle(color: KinCareColors.danger, fontSize: 13))
          else if (hasLocalFile)
            const Text('Recorded ✓',
                style: TextStyle(
                    color: KinCareColors.sage,
                    fontSize: 13,
                    fontWeight: FontWeight.w600))
          else if (hasRemoteAsset)
            const Text('Saved audio',
                style: TextStyle(
                    color: KinCareColors.sage,
                    fontSize: 13,
                    fontWeight: FontWeight.w600))
          else
            const Text('No audio',
                style: TextStyle(color: KinCareColors.textMuted, fontSize: 13)),

          const Spacer(),

          // Play button
          if (!isRecording && (hasLocalFile || hasRemoteAsset))
            isPlaying
                ? IconButton(
                    tooltip: 'Stop playback',
                    icon: const Icon(Icons.stop_circle_outlined,
                        color: KinCareColors.forest),
                    onPressed: onStopPlay,
                  )
                : IconButton(
                    tooltip: 'Play',
                    icon: const Icon(Icons.play_circle_outline,
                        color: KinCareColors.forest),
                    onPressed: hasLocalFile ? onPlayLocal : onPlayRemote,
                  ),
        ],
      ),
    );
  }
}
