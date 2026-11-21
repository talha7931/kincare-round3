import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_theme.dart';

/// Elderly-facing Memory Deck and Memory Card viewer.
/// Implements the accessible reminiscence experience specified in Phase 2.
class ElderlyMemoryScreen extends StatefulWidget {
  final Map<String, dynamic> selectedProfile;
  final VoidCallback onBack;
  final VoidCallback onHome;

  const ElderlyMemoryScreen({
    super.key,
    required this.selectedProfile,
    required this.onBack,
    required this.onHome,
  });

  @override
  State<ElderlyMemoryScreen> createState() => _ElderlyMemoryScreenState();
}

class _ElderlyMemoryScreenState extends State<ElderlyMemoryScreen> {
  final _client = Supabase.instance.client;

  List<Map<String, dynamic>> _decks = [];
  Map<String, dynamic>? _activeDeck;
  List<Map<String, dynamic>> _cards = [];
  int _cardIndex = 0;
  bool _storyRevealed = false;

  bool _loadingDecks = true;
  bool _loadingCards = false;
  String? _error;

  // Signed URL caches
  final Map<String, String> _urlCache = {};

  // Audio player
  final AudioPlayer _audioPlayer = AudioPlayer();
  String? _currentlyPlayingRole; // 'question' or 'answer'
  StreamSubscription? _playerCompleteSub;

  @override
  void initState() {
    super.initState();
    _playerCompleteSub = _audioPlayer.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() => _currentlyPlayingRole = null);
      }
    });
    _loadDecks();
  }

  @override
  void dispose() {
    _playerCompleteSub?.cancel();
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<String?> _resolveSignedUrl(String? assetId) async {
    if (assetId == null || assetId.isEmpty) return null;
    if (_urlCache.containsKey(assetId)) return _urlCache[assetId];

    try {
      final row = await _client
          .from('media_assets')
          .select('storage_path')
          .eq('id', assetId)
          .maybeSingle();

      if (row == null || row['storage_path'] == null) return null;
      final storagePath = row['storage_path'].toString();

      final signedUrl = await _client.storage
          .from('kincare-media')
          .createSignedUrl(storagePath, 3600);

      _urlCache[assetId] = signedUrl;
      return signedUrl;
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadDecks() async {
    final profileId = widget.selectedProfile['id']?.toString();
    if (profileId == null) {
      setState(() {
        _loadingDecks = false;
        _error = 'No profile selected.';
      });
      return;
    }

    setState(() {
      _loadingDecks = true;
      _error = null;
    });

    try {
      final data = await _client
          .from('memory_decks')
          .select('id, title, language_code, created_at')
          .eq('elderly_profile_id', profileId)
          .order('created_at');

      final deckList = List<Map<String, dynamic>>.from(data);

      for (final deck in deckList) {
        final countResult = await _client
            .from('memory_cards')
            .select('id')
            .eq('deck_id', deck['id']);
        deck['_card_count'] = (countResult as List).length;
      }

      setState(() {
        _decks = deckList;
        _loadingDecks = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Unable to load memory decks: $e';
        _loadingDecks = false;
      });
    }
  }

  Future<void> _openDeck(Map<String, dynamic> deck) async {
    await _stopAudio();
    setState(() {
      _activeDeck = deck;
      _loadingCards = true;
      _cardIndex = 0;
      _storyRevealed = false;
      _cards = [];
    });

    try {
      final cardRows = await _client
          .from('memory_cards')
          .select(
              'id, deck_id, photo_asset_id, question_audio_asset_id, answer_audio_asset_id, question_text, answer_context, display_order')
          .eq('deck_id', deck['id'])
          .order('display_order');

      final loadedCards = List<Map<String, dynamic>>.from(cardRows);

      // Pre-fetch signed URL for the first photo
      if (loadedCards.isNotEmpty) {
        final firstPhotoId = loadedCards.first['photo_asset_id']?.toString();
        if (firstPhotoId != null) {
          await _resolveSignedUrl(firstPhotoId);
        }
      }

      setState(() {
        _cards = loadedCards;
        _loadingCards = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Unable to load cards: $e';
        _loadingCards = false;
      });
    }
  }

  Future<void> _stopAudio() async {
    await _audioPlayer.stop();
    if (mounted) {
      setState(() => _currentlyPlayingRole = null);
    }
  }

  Future<void> _toggleAudio(String? assetId, String role) async {
    if (_currentlyPlayingRole == role) {
      await _stopAudio();
      return;
    }

    await _stopAudio();
    final url = await _resolveSignedUrl(assetId);
    if (url == null || url.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Audio recording could not be loaded.',
              style: TextStyle(fontSize: 18),
            ),
          ),
        );
      }
      return;
    }

    setState(() => _currentlyPlayingRole = role);
    await _audioPlayer.play(UrlSource(url));
  }

  void _nextCard() {
    _stopAudio();
    if (_cardIndex < _cards.length - 1) {
      setState(() {
        _cardIndex++;
        _storyRevealed = false;
      });
      // Preload next photo
      if (_cardIndex + 1 < _cards.length) {
        _resolveSignedUrl(
            _cards[_cardIndex + 1]['photo_asset_id']?.toString());
      }
    } else {
      // Completed deck
      setState(() => _activeDeck = null);
    }
  }

  void _previousCard() {
    _stopAudio();
    if (_cardIndex > 0) {
      setState(() {
        _cardIndex--;
        _storyRevealed = false;
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(
        horizontal: KinCareSpace.x5,
        vertical: KinCareSpace.x4,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildTopNav(),
              const SizedBox(height: KinCareSpace.x5),
              if (_error != null) _buildError(),
              if (_activeDeck == null)
                _buildDeckSelection()
              else
                _buildCardViewer(),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Top Navigation (Back + Home)
  // ---------------------------------------------------------------------------

  Widget _buildTopNav() {
    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: KinCareSenior.controlHeight,
            child: FilledButton.icon(
              onPressed: () {
                _stopAudio();
                if (_activeDeck != null) {
                  setState(() => _activeDeck = null);
                } else {
                  widget.onBack();
                }
              },
              icon: const Icon(Icons.arrow_back, size: 28),
              label: Text(
                _activeDeck != null ? 'Back to Decks' : 'Activities',
                style: const TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                ),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: KinCareColors.sage,
                foregroundColor: KinCareColors.white,
              ),
            ),
          ),
        ),
        const SizedBox(width: KinCareSpace.x4),
        Expanded(
          child: SizedBox(
            height: KinCareSenior.controlHeight,
            child: FilledButton.icon(
              onPressed: () {
                _stopAudio();
                widget.onHome();
              },
              icon: const Icon(Icons.home, size: 28),
              label: const Text(
                'Home',
                style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                ),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: KinCareColors.forest,
                foregroundColor: KinCareColors.white,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildError() {
    return Container(
      margin: const EdgeInsets.only(bottom: KinCareSpace.x5),
      padding: const EdgeInsets.all(KinCareSpace.x5),
      decoration: BoxDecoration(
        color: KinCareColors.dangerWash,
        border: Border.all(color: KinCareColors.dangerLine, width: 2),
        borderRadius: BorderRadius.circular(KinCareRadii.lg),
      ),
      child: Text(
        _error!,
        style: const TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: KinCareColors.danger,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Deck Selection View
  // ---------------------------------------------------------------------------

  Widget _buildDeckSelection() {
    if (_loadingDecks) {
      return Container(
        padding: const EdgeInsets.all(KinCareSpace.x10),
        child: const Center(
          child: CircularProgressIndicator(
            strokeWidth: 4,
            color: KinCareColors.forest,
          ),
        ),
      );
    }

    if (_decks.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(KinCareSpace.x8),
        decoration: BoxDecoration(
          color: KinCareColors.white,
          borderRadius: BorderRadius.circular(KinCareRadii.xl),
          border: Border.all(color: KinCareColors.cloud, width: 2),
        ),
        child: Column(
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: const BoxDecoration(
                color: KinCareColors.paleSage,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.photo_library_outlined,
                size: 44,
                color: KinCareColors.forest,
              ),
            ),
            const SizedBox(height: KinCareSpace.x5),
            const Text(
              'No Memory Decks Yet',
              style: TextStyle(
                fontSize: KinCareSenior.title,
                fontWeight: FontWeight.w700,
                color: KinCareColors.forest,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: KinCareSpace.x3),
            const Text(
              'Your caregiver has not added any photo decks for you yet. Please ask them to create a deck with family photographs.',
              style: TextStyle(
                fontSize: KinCareSenior.body,
                height: 1.45,
                color: KinCareColors.charcoal,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Memory Decks',
          style: const TextStyle(
            fontSize: KinCareSenior.title,
            fontWeight: FontWeight.w700,
            color: KinCareColors.forest,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: KinCareSpace.x2),
        const Text(
          'Choose a deck to view familiar photographs and memories.',
          style: TextStyle(
            fontSize: 22,
            height: 1.4,
            color: KinCareColors.charcoal,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: KinCareSpace.x6),
        for (final deck in _decks) ...[
          _buildDeckCard(deck),
          const SizedBox(height: KinCareSpace.x4),
        ],
      ],
    );
  }

  Widget _buildDeckCard(Map<String, dynamic> deck) {
    final cardCount = deck['_card_count'] as int? ?? 0;
    final lang = languageLabel(deck['language_code']);

    return Material(
      color: KinCareColors.white,
      borderRadius: BorderRadius.circular(KinCareRadii.xl),
      elevation: 0,
      child: InkWell(
        onTap: () => _openDeck(deck),
        borderRadius: BorderRadius.circular(KinCareRadii.xl),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: KinCareSpace.x6,
            vertical: KinCareSpace.x5,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(KinCareRadii.xl),
            border: Border.all(color: KinCareColors.line, width: 2),
          ),
          child: Row(
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: KinCareColors.paleSage,
                  borderRadius: BorderRadius.circular(KinCareRadii.lg),
                ),
                child: const Icon(
                  Icons.photo_album,
                  size: 38,
                  color: KinCareColors.forest,
                ),
              ),
              const SizedBox(width: KinCareSpace.x5),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      deck['title']?.toString() ?? 'Memory Deck',
                      style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        color: KinCareColors.forest,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: KinCareColors.paleSage,
                            borderRadius: BorderRadius.circular(KinCareRadii.xs),
                          ),
                          child: Text(
                            '$cardCount ${cardCount == 1 ? 'photo' : 'photos'}',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: KinCareColors.forest,
                            ),
                          ),
                        ),
                        const SizedBox(width: KinCareSpace.x2),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: KinCareColors.cloud,
                            borderRadius: BorderRadius.circular(KinCareRadii.xs),
                          ),
                          child: Text(
                            lang,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: KinCareColors.charcoal,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.arrow_forward_ios,
                size: 28,
                color: KinCareColors.sage,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Card Viewer (The Core Feature)
  // ---------------------------------------------------------------------------

  Widget _buildCardViewer() {
    if (_loadingCards) {
      return Container(
        padding: const EdgeInsets.all(KinCareSpace.x10),
        child: const Center(
          child: CircularProgressIndicator(
            strokeWidth: 4,
            color: KinCareColors.forest,
          ),
        ),
      );
    }

    if (_cards.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(KinCareSpace.x8),
        decoration: BoxDecoration(
          color: KinCareColors.white,
          borderRadius: BorderRadius.circular(KinCareRadii.xl),
          border: Border.all(color: KinCareColors.cloud, width: 2),
        ),
        child: Column(
          children: [
            const Icon(
              Icons.photo_outlined,
              size: 54,
              color: KinCareColors.textMuted,
            ),
            const SizedBox(height: KinCareSpace.x4),
            Text(
              _activeDeck?['title']?.toString() ?? 'Memory Deck',
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                color: KinCareColors.forest,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: KinCareSpace.x3),
            const Text(
              'No cards have been added to this deck yet. Ask your caregiver to upload photographs.',
              style: TextStyle(
                fontSize: 22,
                color: KinCareColors.charcoal,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    final card = _cards[_cardIndex];
    final totalCards = _cards.length;
    final photoAssetId = card['photo_asset_id']?.toString();
    final questionAudioId = card['question_audio_asset_id']?.toString();
    final answerAudioId = card['answer_audio_asset_id']?.toString();
    final questionText = card['question_text']?.toString() ?? '';
    final answerContext = card['answer_context']?.toString() ?? '';

    final hasQuestionAudio =
        questionAudioId != null && questionAudioId.isNotEmpty;
    final hasAnswerAudio = answerAudioId != null && answerAudioId.isNotEmpty;
    final hasStoryContent = answerContext.isNotEmpty || hasAnswerAudio;

    return Container(
      decoration: BoxDecoration(
        color: KinCareColors.white,
        borderRadius: BorderRadius.circular(KinCareRadii.xl),
        border: Border.all(color: KinCareColors.line, width: 2),
        boxShadow: const [
          BoxShadow(
            color: Color.fromARGB(15, 24, 61, 53),
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
      ),
      padding: const EdgeInsets.all(KinCareSpace.x6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Deck title + Card counter
          Row(
            children: [
              Expanded(
                child: Text(
                  _activeDeck?['title']?.toString() ?? 'Memory Deck',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    color: KinCareColors.textMuted,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: KinCareColors.paleSage,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: KinCareColors.sage, width: 1.5),
                ),
                child: Text(
                  '${_cardIndex + 1} of $totalCards',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: KinCareColors.forest,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: KinCareSpace.x5),

          // Large Photograph
          _buildCardPhoto(photoAssetId),
          const SizedBox(height: KinCareSpace.x6),

          // Question Text (26–28 px bold)
          Container(
            padding: const EdgeInsets.all(KinCareSpace.x4),
            decoration: BoxDecoration(
              color: KinCareColors.offWhite,
              borderRadius: BorderRadius.circular(KinCareRadii.lg),
              border: Border.all(color: KinCareColors.line),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Question',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    color: KinCareColors.sage,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  questionText,
                  style: const TextStyle(
                    fontSize: 26,
                    height: 1.35,
                    fontWeight: FontWeight.w700,
                    color: KinCareColors.forest,
                  ),
                ),
              ],
            ),
          ),

          // Spoken Question Audio Button (min 64–72 px)
          if (hasQuestionAudio) ...[
            const SizedBox(height: KinCareSpace.x4),
            _buildAudioButton(
              role: 'question',
              assetId: questionAudioId,
              idleLabel: 'Listen to Question',
              playingLabel: 'Stop Audio',
            ),
          ],

          const SizedBox(height: KinCareSpace.x5),

          // Story is only added to the widget tree after an explicit reveal.
          if (hasStoryContent && !_storyRevealed) ...[
            SizedBox(
              height: KinCareSenior.controlHeight,
              child: FilledButton.icon(
                onPressed: () => setState(() => _storyRevealed = true),
                icon: const Icon(Icons.auto_stories_outlined, size: 28),
                label: const Text(
                  'Reveal Memory Story',
                  style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: KinCareColors.amber,
                  foregroundColor: KinCareColors.charcoal,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(KinCareRadii.lg),
                  ),
                ),
              ),
            ),
            const SizedBox(height: KinCareSpace.x5),
          ],
          if (answerContext.isNotEmpty && _storyRevealed) ...[
            Container(
              padding: const EdgeInsets.all(KinCareSpace.x5),
              decoration: BoxDecoration(
                color: KinCareColors.paleSage.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(KinCareRadii.lg),
                border: Border.all(
                  color: KinCareColors.sage.withValues(alpha: 0.35),
                  width: 1.5,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(
                        Icons.auto_stories_outlined,
                        size: 22,
                        color: KinCareColors.forest,
                      ),
                      SizedBox(width: 8),
                      Text(
                        'Memory Story',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: KinCareColors.forest,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    answerContext,
                    style: const TextStyle(
                      fontSize: 22,
                      height: 1.45,
                      color: KinCareColors.charcoal,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],

          // Spoken Answer Audio Button
          if (hasAnswerAudio && _storyRevealed) ...[
            const SizedBox(height: KinCareSpace.x4),
            _buildAudioButton(
              role: 'answer',
              assetId: answerAudioId,
              idleLabel: 'Listen to Story',
              playingLabel: 'Stop Story',
            ),
          ],

          const SizedBox(height: KinCareSpace.x7),

          // Previous & Next navigation controls (72 px)
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: KinCareSenior.controlHeight,
                  child: OutlinedButton.icon(
                    onPressed: _cardIndex > 0 ? _previousCard : null,
                    icon: const Icon(Icons.arrow_back, size: 28),
                    label: const Text(
                      'Previous',
                      style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: KinCareColors.forest,
                      side: const BorderSide(
                        color: KinCareColors.sage,
                        width: 2,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(KinCareRadii.lg),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: KinCareSpace.x4),
              Expanded(
                child: SizedBox(
                  height: KinCareSenior.controlHeight,
                  child: FilledButton.icon(
                    onPressed: _nextCard,
                    icon: Icon(
                      _cardIndex < totalCards - 1
                          ? Icons.arrow_forward
                          : Icons.check_circle,
                      size: 28,
                    ),
                    label: Text(
                      _cardIndex < totalCards - 1 ? 'Next' : 'Finish',
                      style: const TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: KinCareColors.forest,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(KinCareRadii.lg),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Card Photo with Private Storage Signed URL
  // ---------------------------------------------------------------------------

  Widget _buildCardPhoto(String? assetId) {
    if (assetId == null || assetId.isEmpty) {
      return Container(
        height: 260,
        decoration: BoxDecoration(
          color: KinCareColors.paleSage,
          borderRadius: BorderRadius.circular(KinCareRadii.xl),
        ),
        child: const Center(
          child: Icon(
            Icons.photo_outlined,
            size: 64,
            color: KinCareColors.sage,
          ),
        ),
      );
    }

    return FutureBuilder<String?>(
      future: _resolveSignedUrl(assetId),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !_urlCache.containsKey(assetId)) {
          return Container(
            height: 300,
            decoration: BoxDecoration(
              color: KinCareColors.paleSage,
              borderRadius: BorderRadius.circular(KinCareRadii.xl),
            ),
            child: const Center(
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: KinCareColors.forest,
              ),
            ),
          );
        }

        final url = snapshot.data ?? _urlCache[assetId];
        if (url == null || url.isEmpty) {
          return Container(
            height: 260,
            decoration: BoxDecoration(
              color: KinCareColors.paleSage,
              borderRadius: BorderRadius.circular(KinCareRadii.xl),
            ),
            child: const Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.broken_image_outlined,
                    size: 48, color: KinCareColors.sage),
                SizedBox(height: 8),
                Text(
                  'Photograph could not be loaded',
                  style: TextStyle(
                    fontSize: 18,
                    color: KinCareColors.textMuted,
                  ),
                ),
              ],
            ),
          );
        }

        return ClipRRect(
          borderRadius: BorderRadius.circular(KinCareRadii.xl),
          child: Image.network(
            url,
            fit: BoxFit.cover,
            height: 320,
            width: double.infinity,
            errorBuilder: (_, __, ___) => Container(
              height: 260,
              color: KinCareColors.paleSage,
              child: const Center(
                child: Icon(
                  Icons.broken_image_outlined,
                  size: 48,
                  color: KinCareColors.danger,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // High-Contrast Large Audio Button (64–72 px)
  // ---------------------------------------------------------------------------

  Widget _buildAudioButton({
    required String role,
    required String? assetId,
    required String idleLabel,
    required String playingLabel,
  }) {
    final isPlaying = _currentlyPlayingRole == role;

    return SizedBox(
      height: KinCareSenior.controlHeight,
      child: FilledButton.icon(
        onPressed: () => _toggleAudio(assetId, role),
        icon: Icon(
          isPlaying ? Icons.stop_circle : Icons.volume_up_rounded,
          size: 32,
        ),
        label: Text(
          isPlaying ? playingLabel : idleLabel,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
        ),
        style: FilledButton.styleFrom(
          backgroundColor:
              isPlaying ? KinCareColors.amber : KinCareColors.sage,
          foregroundColor:
              isPlaying ? KinCareColors.charcoal : KinCareColors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(KinCareRadii.lg),
          ),
        ),
      ),
    );
  }
}

