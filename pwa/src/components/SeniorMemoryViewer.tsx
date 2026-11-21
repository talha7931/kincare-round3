import { useCallback, useEffect, useRef, useState } from "react";
import { supabase } from "../lib/supabase";
import { getSignedUrl } from "../lib/mediaUpload";
import type { ElderlyProfile } from "./MemoryDecks";

type SeniorMemoryViewerProps = {
  profile: ElderlyProfile;
  onBack: () => void;
  onHome: () => void;
};

type MemoryDeck = {
  id: string;
  title: string;
  language_code: string;
  created_at: string;
  card_count?: number;
};

type MemoryCard = {
  id: string;
  deck_id: string;
  photo_asset_id: string;
  question_audio_asset_id: string | null;
  answer_audio_asset_id: string | null;
  question_text: string;
  answer_context: string;
  display_order: number;
  photo_url?: string;
  question_audio_url?: string;
  answer_audio_url?: string;
};

const LANG_LABELS: Record<string, string> = {
  en: "English",
  hi: "Hindi",
  mr: "Marathi",
};

export function SeniorMemoryViewer({
  profile,
  onBack,
  onHome,
}: SeniorMemoryViewerProps) {
  const [decks, setDecks] = useState<MemoryDeck[]>([]);
  const [activeDeck, setActiveDeck] = useState<MemoryDeck | null>(null);
  const [cards, setCards] = useState<MemoryCard[]>([]);
  const [cardIndex, setCardIndex] = useState(0);

  const [loadingDecks, setLoadingDecks] = useState(true);
  const [loadingCards, setLoadingCards] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Audio playback
  const [playingRole, setPlayingRole] = useState<"question" | "answer" | null>(
    null
  );
  const audioRef = useRef<HTMLAudioElement | null>(null);

  const stopAudio = useCallback(() => {
    if (audioRef.current) {
      audioRef.current.pause();
      audioRef.current.currentTime = 0;
      audioRef.current = null;
    }
    setPlayingRole(null);
  }, []);

  const playAudio = useCallback(
    (url: string | undefined, role: "question" | "answer") => {
      if (!url) return;
      if (playingRole === role) {
        stopAudio();
        return;
      }
      stopAudio();
      const a = new Audio(url);
      audioRef.current = a;
      setPlayingRole(role);
      a.onended = () => {
        setPlayingRole(null);
        audioRef.current = null;
      };
      a.onerror = () => {
        setPlayingRole(null);
        audioRef.current = null;
      };
      void a.play();
    },
    [playingRole, stopAudio]
  );

  useEffect(() => {
    return () => {
      stopAudio();
    };
  }, [stopAudio]);

  // Load decks for profile
  useEffect(() => {
    async function loadDecks() {
      setLoadingDecks(true);
      setError(null);
      try {
        const { data: deckRows, error: deckErr } = await supabase
          .from("memory_decks")
          .select("id, title, language_code, created_at")
          .eq("elderly_profile_id", profile.id)
          .order("created_at", { ascending: false });

        if (deckErr) throw new Error(deckErr.message);

        const deckList = (deckRows ?? []) as MemoryDeck[];
        const deckIds = deckList.map((d) => d.id);

        if (deckIds.length > 0) {
          const { data: cardRows } = await supabase
            .from("memory_cards")
            .select("deck_id")
            .in("deck_id", deckIds);

          const countMap: Record<string, number> = {};
          (cardRows ?? []).forEach((r: { deck_id: string }) => {
            countMap[r.deck_id] = (countMap[r.deck_id] ?? 0) + 1;
          });

          deckList.forEach((d) => {
            d.card_count = countMap[d.id] ?? 0;
          });
        }

        setDecks(deckList);
      } catch (e) {
        setError(e instanceof Error ? e.message : "Failed to load memory decks");
      } finally {
        setLoadingDecks(false);
      }
    }
    void loadDecks();
  }, [profile.id]);

  // Open a specific deck and resolve card media URLs
  const openDeck = async (deck: MemoryDeck) => {
    stopAudio();
    setActiveDeck(deck);
    setLoadingCards(true);
    setCardIndex(0);
    setError(null);

    try {
      const { data: cardRows, error: cardErr } = await supabase
        .from("memory_cards")
        .select("*")
        .eq("deck_id", deck.id)
        .order("display_order", { ascending: true });

      if (cardErr) throw new Error(cardErr.message);

      const rawCards = (cardRows ?? []) as MemoryCard[];

      // Collect all media asset IDs
      const assetIds: string[] = [];
      rawCards.forEach((c) => {
        if (c.photo_asset_id) assetIds.push(c.photo_asset_id);
        if (c.question_audio_asset_id) assetIds.push(c.question_audio_asset_id);
        if (c.answer_audio_asset_id) assetIds.push(c.answer_audio_asset_id);
      });

      let assetsMap: Record<string, string> = {};
      if (assetIds.length > 0) {
        const { data: assetRows } = await supabase
          .from("media_assets")
          .select("id, storage_path")
          .in("id", assetIds);

        (assetRows ?? []).forEach((a: { id: string; storage_path: string }) => {
          assetsMap[a.id] = a.storage_path;
        });
      }

      // Resolve signed URLs
      const resolved = await Promise.all(
        rawCards.map(async (card) => {
          const photoPath = assetsMap[card.photo_asset_id];
          const qAudioPath = card.question_audio_asset_id
            ? assetsMap[card.question_audio_asset_id]
            : null;
          const aAudioPath = card.answer_audio_asset_id
            ? assetsMap[card.answer_audio_asset_id]
            : null;

          const [photoUrl, qAudioUrl, aAudioUrl] = await Promise.all([
            photoPath
              ? getSignedUrl(photoPath).catch(() => undefined)
              : Promise.resolve(undefined),
            qAudioPath
              ? getSignedUrl(qAudioPath).catch(() => undefined)
              : Promise.resolve(undefined),
            aAudioPath
              ? getSignedUrl(aAudioPath).catch(() => undefined)
              : Promise.resolve(undefined),
          ]);

          return {
            ...card,
            photo_url: photoUrl,
            question_audio_url: qAudioUrl,
            answer_audio_url: aAudioUrl,
          };
        })
      );

      setCards(resolved);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to load cards");
    } finally {
      setLoadingCards(false);
    }
  };

  const handleNext = () => {
    stopAudio();
    if (cardIndex < cards.length - 1) {
      setCardIndex((idx) => idx + 1);
    } else {
      setActiveDeck(null);
    }
  };

  const handlePrevious = () => {
    stopAudio();
    if (cardIndex > 0) {
      setCardIndex((idx) => idx - 1);
    }
  };

  // ---------------------------------------------------------------------------
  // Render
  // ---------------------------------------------------------------------------

  return (
    <section className="senior-content" aria-label="Memory Deck Experience">
      {/* Top navigation */}
      <div className="senior-choice-heading senior-choice-heading--pair">
        <button
          type="button"
          className="senior-back"
          onClick={() => {
            stopAudio();
            if (activeDeck) {
              setActiveDeck(null);
            } else {
              onBack();
            }
          }}
        >
          {activeDeck ? "← Decks" : "← Activities"}
        </button>
        <button
          type="button"
          className="senior-home"
          onClick={() => {
            stopAudio();
            onHome();
          }}
        >
          Home
        </button>
      </div>

      {error && (
        <p className="senior-message senior-error" role="alert">
          {error}
        </p>
      )}

      {/* Stage 1: Deck Selection */}
      {!activeDeck && (
        <div>
          <h2>Memory Decks</h2>
          <p
            style={{
              textAlign: "center",
              fontSize: "22px",
              color: "var(--charcoal)",
              margin: "0 0 24px",
            }}
          >
            Look at familiar photographs and remember special moments.
          </p>

          {loadingDecks ? (
            <div className="loading" aria-live="polite" />
          ) : decks.length === 0 ? (
            <div className="senior-empty">
              <h3>No Memory Decks Yet</h3>
              <p>
                Your caregiver has not added any photo decks for you yet. Ask
                them to add family photographs.
              </p>
            </div>
          ) : (
            <div className="senior-deck-grid">
              {decks.map((deck) => (
                <button
                  type="button"
                  key={deck.id}
                  className="senior-deck-card"
                  onClick={() => void openDeck(deck)}
                >
                  <div className="senior-deck-icon">📷</div>
                  <div className="senior-deck-info">
                    <strong className="senior-deck-title">{deck.title}</strong>
                    <div className="senior-deck-meta">
                      <span>
                        {deck.card_count ?? 0}{" "}
                        {deck.card_count === 1 ? "photo" : "photos"}
                      </span>
                      <span>•</span>
                      <span>
                        {LANG_LABELS[deck.language_code] ?? deck.language_code}
                      </span>
                    </div>
                  </div>
                  <span className="senior-deck-arrow">→</span>
                </button>
              ))}
            </div>
          )}
        </div>
      )}

      {/* Stage 2: Card Viewing Experience */}
      {activeDeck && (
        <div>
          {loadingCards ? (
            <div className="loading" aria-live="polite" />
          ) : cards.length === 0 ? (
            <div className="senior-empty">
              <h3>{activeDeck.title}</h3>
              <p>
                No cards have been added to this deck yet. Ask your caregiver to
                upload photographs.
              </p>
              <button
                type="button"
                className="btn btn-primary"
                style={{
                  minHeight: "64px",
                  fontSize: "20px",
                  marginTop: "16px",
                }}
                onClick={() => setActiveDeck(null)}
              >
                Back to Decks
              </button>
            </div>
          ) : (
            <article className="senior-card-viewer">
              {/* Header: title and card count indicator */}
              <div className="senior-card-header">
                <span className="senior-deck-name">{activeDeck.title}</span>
                <span className="senior-card-badge">
                  {cardIndex + 1} of {cards.length}
                </span>
              </div>

              {/* Big Photograph */}
              <div className="senior-photo-container">
                {cards[cardIndex].photo_url ? (
                  <img
                    src={cards[cardIndex].photo_url}
                    alt={cards[cardIndex].question_text}
                    className="senior-card-image"
                  />
                ) : (
                  <div className="senior-photo-placeholder">
                    <span>📷 Photograph loading...</span>
                  </div>
                )}
              </div>

              {/* Question Text & Audio */}
              <div className="senior-question-box">
                <span className="senior-section-tag">Question</span>
                <h3 className="senior-question-text">
                  {cards[cardIndex].question_text}
                </h3>

                {cards[cardIndex].question_audio_url && (
                  <button
                    type="button"
                    className={`senior-audio-btn ${
                      playingRole === "question" ? "senior-audio-active" : ""
                    }`}
                    onClick={() =>
                      playAudio(
                        cards[cardIndex].question_audio_url,
                        "question"
                      )
                    }
                  >
                    {playingRole === "question" ? "⏹ Stop Question" : "🔊 Listen to Question"}
                  </button>
                )}
              </div>

              {/* Answer Context / Story & Audio */}
              {cards[cardIndex].answer_context && (
                <div className="senior-story-box">
                  <span className="senior-section-tag">Memory Story</span>
                  <p className="senior-story-text">
                    {cards[cardIndex].answer_context}
                  </p>

                  {cards[cardIndex].answer_audio_url && (
                    <button
                      type="button"
                      className={`senior-audio-btn ${
                        playingRole === "answer" ? "senior-audio-active" : ""
                      }`}
                      onClick={() =>
                        playAudio(cards[cardIndex].answer_audio_url, "answer")
                      }
                    >
                      {playingRole === "answer" ? "⏹ Stop Story" : "🔊 Listen to Story"}
                    </button>
                  )}
                </div>
              )}

              {/* Navigation controls */}
              <div className="senior-nav-controls">
                <button
                  type="button"
                  className="senior-nav-btn senior-nav-prev"
                  disabled={cardIndex === 0}
                  onClick={handlePrevious}
                >
                  ← Previous
                </button>
                <button
                  type="button"
                  className="senior-nav-btn senior-nav-next"
                  onClick={handleNext}
                >
                  {cardIndex < cards.length - 1 ? "Next →" : "Finish Deck ✓"}
                </button>
              </div>
            </article>
          )}
        </div>
      )}
    </section>
  );
}

