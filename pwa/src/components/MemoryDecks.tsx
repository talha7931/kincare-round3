import { useCallback, useEffect, useRef, useState } from "react";
import type { User } from "@supabase/supabase-js";
import { supabase } from "../lib/supabase";
import { uploadMedia, getSignedUrl } from "../lib/mediaUpload";

// ── Types ────────────────────────────────────────────────────────────────────

export type ElderlyProfile = {
  id: string;
  display_name: string;
  preferred_language: string;
};

type MemoryDeck = {
  id: string;
  elderly_profile_id: string;
  created_by_caregiver_id: string;
  title: string;
  language_code: string;
  created_at: string;
  updated_at: string;
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
  // resolved URLs — not in DB, computed client-side
  photo_url?: string;
  question_audio_url?: string;
  answer_audio_url?: string;
};

type MediaAsset = {
  id: string;
  storage_path: string;
  media_type: string;
  mime_type: string;
};

type View =
  | { name: "deck-list" }
  | { name: "create-deck" }
  | { name: "edit-deck"; deck: MemoryDeck }
  | { name: "deck-detail"; deck: MemoryDeck }
  | { name: "create-card"; deck: MemoryDeck }
  | { name: "edit-card"; deck: MemoryDeck; card: MemoryCard };

// ── Audio recorder hook ───────────────────────────────────────────────────────

type RecorderState = "idle" | "recording" | "done" | "denied";

function useAudioRecorder() {
  const [state, setState] = useState<RecorderState>("idle");
  const [blob, setBlob] = useState<Blob | null>(null);
  const mediaRecorderRef = useRef<MediaRecorder | null>(null);
  const chunksRef = useRef<BlobPart[]>([]);

  const start = useCallback(async () => {
    setBlob(null);
    chunksRef.current = [];
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      const mr = new MediaRecorder(stream);
      mediaRecorderRef.current = mr;
      mr.ondataavailable = (e) => {
        if (e.data.size > 0) chunksRef.current.push(e.data);
      };
      mr.onstop = () => {
        const mimeType = mr.mimeType || "audio/webm";
        const recorded = new Blob(chunksRef.current, { type: mimeType });
        setBlob(recorded);
        stream.getTracks().forEach((t) => t.stop());
        setState("done");
      };
      mr.start();
      setState("recording");
    } catch {
      setState("denied");
    }
  }, []);

  const stop = useCallback(() => {
    if (mediaRecorderRef.current?.state === "recording") {
      mediaRecorderRef.current.stop();
    }
  }, []);

  const reset = useCallback(() => {
    setState("idle");
    setBlob(null);
  }, []);

  return { state, blob, start, stop, reset };
}

// ── Helpers ───────────────────────────────────────────────────────────────────

const LANG_LABELS: Record<string, string> = { en: "English", hi: "Hindi", mr: "Marathi" };

function fmt(dateStr: string) {
  try {
    return new Date(dateStr).toLocaleDateString(undefined, {
      year: "numeric",
      month: "short",
      day: "numeric",
    });
  } catch {
    return dateStr;
  }
}

async function resolveCardUrls(
  card: MemoryCard,
  assets: MediaAsset[]
): Promise<MemoryCard> {
  const pathFor = (id: string | null) =>
    id ? assets.find((a) => a.id === id)?.storage_path ?? null : null;

  const photoPath = pathFor(card.photo_asset_id);
  const qAudioPath = pathFor(card.question_audio_asset_id);
  const aAudioPath = pathFor(card.answer_audio_asset_id);

  const [photoUrl, qAudioUrl, aAudioUrl] = await Promise.all([
    photoPath ? getSignedUrl(photoPath).catch(() => "") : Promise.resolve(""),
    qAudioPath ? getSignedUrl(qAudioPath).catch(() => "") : Promise.resolve(""),
    aAudioPath ? getSignedUrl(aAudioPath).catch(() => "") : Promise.resolve(""),
  ]);

  return {
    ...card,
    photo_url: photoUrl || undefined,
    question_audio_url: qAudioUrl || undefined,
    answer_audio_url: aAudioUrl || undefined,
  };
}

// ── Sub-components ────────────────────────────────────────────────────────────

type AudioFieldProps = {
  label: string;
  existingUrl?: string;
  recorder: ReturnType<typeof useAudioRecorder>;
  onFileChosen: (file: File) => void;
  disabled?: boolean;
};

function AudioField({ label, existingUrl, recorder, onFileChosen, disabled }: AudioFieldProps) {
  const fileInputRef = useRef<HTMLInputElement>(null);
  const [previewUrl, setPreviewUrl] = useState<string | null>(null);

  // Build a preview URL from the recorded blob whenever it changes
  useEffect(() => {
    if (recorder.blob) {
      const url = URL.createObjectURL(recorder.blob);
      setPreviewUrl(url);
      return () => URL.revokeObjectURL(url);
    }
    setPreviewUrl(null);
  }, [recorder.blob]);

  const handleFileChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const f = e.target.files?.[0];
    if (f) onFileChosen(f);
  };

  const playUrl = previewUrl || existingUrl;

  return (
    <div className="audio-field">
      <span className="audio-field-label">{label}</span>
      <div className="audio-controls">
        {/* Record / Stop */}
        {recorder.state === "idle" || recorder.state === "done" ? (
          <button
            type="button"
            className="btn btn-quiet"
            onClick={recorder.start}
            disabled={disabled}
          >
            🎙 {recorder.state === "done" ? "Re-record" : "Record"}
          </button>
        ) : recorder.state === "recording" ? (
          <button
            type="button"
            className="btn btn-danger"
            onClick={recorder.stop}
            disabled={disabled}
          >
            ⏹ Stop
          </button>
        ) : null}

        {recorder.state === "denied" && (
          <span className="audio-denied">Microphone access denied</span>
        )}

        {/* Upload file alternative */}
        <button
          type="button"
          className="btn btn-quiet"
          onClick={() => fileInputRef.current?.click()}
          disabled={disabled}
        >
          📁 Upload file
        </button>
        <input
          ref={fileInputRef}
          type="file"
          accept="audio/*"
          style={{ display: "none" }}
          onChange={handleFileChange}
          disabled={disabled}
        />

        {/* Playback */}
        {playUrl && (
          // eslint-disable-next-line jsx-a11y/media-has-caption
          <audio controls src={playUrl} className="audio-player" />
        )}
        {!playUrl && existingUrl === undefined && recorder.state === "idle" && (
          <span className="audio-none">No audio</span>
        )}
      </div>
    </div>
  );
}

// ── DeckList ─────────────────────────────────────────────────────────────────

type DeckListProps = {
  profile: ElderlyProfile;
  onCreateDeck: () => void;
  onEditDeck: (deck: MemoryDeck) => void;
  onOpenDeck: (deck: MemoryDeck) => void;
  userId: string;
};

function DeckList({ profile, onCreateDeck, onEditDeck, onOpenDeck, userId }: DeckListProps) {
  const [decks, setDecks] = useState<MemoryDeck[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [deleting, setDeleting] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      // Fetch decks
      const { data: deckRows, error: deckErr } = await supabase
        .from("memory_decks")
        .select("*")
        .eq("elderly_profile_id", profile.id)
        .order("created_at", { ascending: false });

      if (deckErr) throw new Error(deckErr.message);

      // Fetch card counts for each deck
      const deckIds = (deckRows ?? []).map((d: MemoryDeck) => d.id);
      let countMap: Record<string, number> = {};
      if (deckIds.length > 0) {
        const { data: cardRows, error: cardErr } = await supabase
          .from("memory_cards")
          .select("deck_id")
          .in("deck_id", deckIds);
        if (!cardErr && cardRows) {
          cardRows.forEach((r: { deck_id: string }) => {
            countMap[r.deck_id] = (countMap[r.deck_id] ?? 0) + 1;
          });
        }
      }

      setDecks(
        (deckRows ?? []).map((d: MemoryDeck) => ({
          ...d,
          card_count: countMap[d.id] ?? 0,
        }))
      );
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to load decks");
    } finally {
      setLoading(false);
    }
  }, [profile.id]);

  useEffect(() => { void load(); }, [load]);

  const handleDelete = async (deck: MemoryDeck) => {
    if (!confirm(`Delete deck "${deck.title}"? All cards will also be deleted.`)) return;
    setDeleting(deck.id);
    try {
      const { error: err } = await supabase
        .from("memory_decks")
        .delete()
        .eq("id", deck.id)
        .eq("created_by_caregiver_id", userId);
      if (err) throw new Error(err.message);
      setDecks((prev) => prev.filter((d) => d.id !== deck.id));
    } catch (e) {
      setError(e instanceof Error ? e.message : "Delete failed");
    } finally {
      setDeleting(null);
    }
  };

  if (loading) return <div className="loading" aria-live="polite" />;
  if (error) return <p className="error" role="alert">{error}</p>;

  return (
    <div className="memory-decks-layout">
      <div className="panel-heading">
        <h2>Memory Decks — {profile.display_name}</h2>
        <button className="btn btn-primary" onClick={onCreateDeck}>+ New Deck</button>
      </div>

      {decks.length === 0 ? (
        <p className="empty-state">
          No memory decks yet. Create one to start adding photographs and stories.
        </p>
      ) : (
        <div className="deck-grid">
          {decks.map((deck) => (
            <div key={deck.id} className="deck-card">
              <div className="deck-card-body" onClick={() => onOpenDeck(deck)} role="button" tabIndex={0} onKeyDown={(e) => e.key === "Enter" && onOpenDeck(deck)}>
                <div className="deck-card-title">{deck.title}</div>
                <div className="deck-card-meta">
                  <span>{LANG_LABELS[deck.language_code] ?? deck.language_code}</span>
                  <span>{deck.card_count ?? 0} card{deck.card_count !== 1 ? "s" : ""}</span>
                  <span>Updated {fmt(deck.updated_at)}</span>
                </div>
              </div>
              <div className="deck-card-actions">
                <button
                  className="btn btn-quiet"
                  onClick={(e) => { e.stopPropagation(); onEditDeck(deck); }}
                  disabled={deleting === deck.id}
                >
                  Edit
                </button>
                <button
                  className="btn btn-danger"
                  onClick={(e) => { e.stopPropagation(); void handleDelete(deck); }}
                  disabled={deleting === deck.id}
                >
                  {deleting === deck.id ? "Deleting…" : "Delete"}
                </button>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

// ── DeckForm ──────────────────────────────────────────────────────────────────

type DeckFormProps = {
  profile: ElderlyProfile;
  userId: string;
  existing?: MemoryDeck;
  onSaved: () => void;
  onCancel: () => void;
};

function DeckForm({ profile, userId, existing, onSaved, onCancel }: DeckFormProps) {
  const [title, setTitle] = useState(existing?.title ?? "");
  const [language, setLanguage] = useState(existing?.language_code ?? profile.preferred_language ?? "en");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!title.trim()) { setError("Title is required"); return; }
    setSaving(true);
    setError(null);

    try {
      if (existing) {
        const { error: err } = await supabase
          .from("memory_decks")
          .update({ title: title.trim(), language_code: language, updated_at: new Date().toISOString() })
          .eq("id", existing.id)
          .eq("created_by_caregiver_id", userId);
        if (err) throw new Error(err.message);
      } else {
        const { error: err } = await supabase.from("memory_decks").insert({
          id: crypto.randomUUID(),
          elderly_profile_id: profile.id,
          created_by_caregiver_id: userId,
          title: title.trim(),
          language_code: language,
        });
        if (err) throw new Error(err.message);
      }
      onSaved();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Save failed");
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="content-panel" style={{ maxWidth: 520 }}>
      <div className="panel-heading">
        <h2>{existing ? "Edit Deck" : "New Memory Deck"}</h2>
      </div>
      {error && <p className="error" role="alert">{error}</p>}
      <form className="management-form" onSubmit={(e) => { void handleSubmit(e); }}>
        <label className="field">
          Title
          <input
            type="text"
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            placeholder="e.g. Family Holidays"
            maxLength={120}
            required
            autoFocus
          />
        </label>
        <label className="field">
          Language
          <select value={language} onChange={(e) => setLanguage(e.target.value)}>
            <option value="en">English</option>
            <option value="hi">Hindi</option>
            <option value="mr">Marathi</option>
          </select>
        </label>
        <div className="actions">
          <button type="submit" className="btn btn-primary" disabled={saving}>
            {saving ? "Saving…" : existing ? "Save changes" : "Create deck"}
          </button>
          <button type="button" className="btn btn-quiet" onClick={onCancel} disabled={saving}>
            Cancel
          </button>
        </div>
      </form>
    </div>
  );
}

// ── DeckDetail ────────────────────────────────────────────────────────────────

type DeckDetailProps = {
  deck: MemoryDeck;
  userId: string;
  onAddCard: () => void;
  onEditCard: (card: MemoryCard) => void;
  onBack: () => void;
};

function DeckDetail({ deck, userId: _userId, onAddCard, onEditCard, onBack }: DeckDetailProps) {
  const [cards, setCards] = useState<MemoryCard[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [deleting, setDeleting] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const { data: cardRows, error: cardErr } = await supabase
        .from("memory_cards")
        .select("*")
        .eq("deck_id", deck.id)
        .order("display_order", { ascending: true });

      if (cardErr) throw new Error(cardErr.message);

      // Collect all asset IDs we need
      const assetIds: string[] = [];
      (cardRows ?? []).forEach((c: MemoryCard) => {
        if (c.photo_asset_id) assetIds.push(c.photo_asset_id);
        if (c.question_audio_asset_id) assetIds.push(c.question_audio_asset_id);
        if (c.answer_audio_asset_id) assetIds.push(c.answer_audio_asset_id);
      });

      let assets: MediaAsset[] = [];
      if (assetIds.length > 0) {
        const { data: assetRows } = await supabase
          .from("media_assets")
          .select("id, storage_path, media_type, mime_type")
          .in("id", assetIds);
        assets = assetRows ?? [];
      }

      const resolved = await Promise.all(
        (cardRows ?? []).map((c: MemoryCard) => resolveCardUrls(c, assets))
      );
      setCards(resolved);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to load cards");
    } finally {
      setLoading(false);
    }
  }, [deck.id]);

  useEffect(() => { void load(); }, [load]);

  const handleDelete = async (card: MemoryCard) => {
    if (!confirm("Delete this memory card?")) return;
    setDeleting(card.id);
    try {
      const { error: err } = await supabase
        .from("memory_cards")
        .delete()
        .eq("id", card.id);
      if (err) throw new Error(err.message);
      setCards((prev) => prev.filter((c) => c.id !== card.id));
    } catch (e) {
      setError(e instanceof Error ? e.message : "Delete failed");
    } finally {
      setDeleting(null);
    }
  };

  if (loading) return <div className="loading" aria-live="polite" />;

  return (
    <div className="memory-decks-layout">
      <div className="panel-heading">
        <h2>{deck.title}</h2>
        <div style={{ display: "flex", gap: 8 }}>
          <button className="btn btn-quiet" onClick={onBack}>← Back</button>
          <button className="btn btn-primary" onClick={onAddCard}>+ Add Card</button>
        </div>
      </div>
      {error && <p className="error" role="alert">{error}</p>}

      {cards.length === 0 ? (
        <p className="empty-state">No cards yet. Add the first memory card.</p>
      ) : (
        <div className="deck-grid">
          {cards.map((card) => (
            <div key={card.id} className="deck-card memory-card-item">
              {card.photo_url ? (
                <img
                  src={card.photo_url}
                  alt={card.question_text}
                  className="photo-thumbnail"
                />
              ) : (
                <div className="photo-placeholder">📷</div>
              )}
              <div className="deck-card-body">
                <div className="deck-card-title">{card.question_text}</div>
                <div className="deck-card-meta answer-preview">{card.answer_context}</div>
                <div className="audio-indicators">
                  {card.question_audio_url && <span className="audio-badge" title="Question audio">🎵 Q</span>}
                  {card.answer_audio_url && <span className="audio-badge" title="Answer audio">🎵 A</span>}
                </div>
              </div>
              <div className="deck-card-actions">
                <button
                  className="btn btn-quiet"
                  onClick={() => onEditCard(card)}
                  disabled={deleting === card.id}
                >
                  Edit
                </button>
                <button
                  className="btn btn-danger"
                  onClick={() => void handleDelete(card)}
                  disabled={deleting === card.id}
                >
                  {deleting === card.id ? "Deleting…" : "Delete"}
                </button>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

// ── CardEditor ────────────────────────────────────────────────────────────────

type CardEditorProps = {
  deck: MemoryDeck;
  profile: ElderlyProfile;
  userId: string;
  existing?: MemoryCard;
  existingCardCount: number;
  onSaved: () => void;
  onCancel: () => void;
};

function CardEditor({
  deck,
  profile,
  userId,
  existing,
  existingCardCount,
  onSaved,
  onCancel,
}: CardEditorProps) {
  const [questionText, setQuestionText] = useState(existing?.question_text ?? "");
  const [answerContext, setAnswerContext] = useState(existing?.answer_context ?? "");
  const [displayOrder, setDisplayOrder] = useState(
    existing?.display_order ?? existingCardCount
  );
  const [photoFile, setPhotoFile] = useState<File | null>(null);
  const [photoPreview, setPhotoPreview] = useState<string | null>(existing?.photo_url ?? null);
  const [qAudioFile, setQAudioFile] = useState<File | null>(null);
  const [aAudioFile, setAAudioFile] = useState<File | null>(null);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const qRecorder = useAudioRecorder();
  const aRecorder = useAudioRecorder();

  const photoInputRef = useRef<HTMLInputElement>(null);

  const handlePhotoChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const f = e.target.files?.[0];
    if (!f) return;
    if (f.size > 10 * 1024 * 1024) {
      setError("Photo must be under 10 MB");
      return;
    }
    setPhotoFile(f);
    const url = URL.createObjectURL(f);
    setPhotoPreview(url);
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!questionText.trim()) { setError("Question text is required"); return; }
    if (!answerContext.trim()) { setError("Answer context is required"); return; }
    if (!existing && !photoFile) { setError("A photo is required"); return; }

    setSaving(true);
    setError(null);

    try {
      // 1. Upload photo (if new/replaced)
      let photoAssetId = existing?.photo_asset_id ?? "";
      if (photoFile) {
        const result = await uploadMedia(photoFile, profile.id, "photo", userId);
        photoAssetId = result.assetId;
      }

      // 2. Upload question audio (file or recording)
      let qAudioAssetId: string | null = existing?.question_audio_asset_id ?? null;
      const qSource = qAudioFile ?? (qRecorder.blob ? new File([qRecorder.blob], `q_audio.${qRecorder.blob.type.includes("ogg") ? "ogg" : "webm"}`, { type: qRecorder.blob.type }) : null);
      if (qSource) {
        const result = await uploadMedia(qSource, profile.id, "question_audio", userId);
        qAudioAssetId = result.assetId;
      }

      // 3. Upload answer audio (file or recording)
      let aAudioAssetId: string | null = existing?.answer_audio_asset_id ?? null;
      const aSource = aAudioFile ?? (aRecorder.blob ? new File([aRecorder.blob], `a_audio.${aRecorder.blob.type.includes("ogg") ? "ogg" : "webm"}`, { type: aRecorder.blob.type }) : null);
      if (aSource) {
        const result = await uploadMedia(aSource, profile.id, "answer_audio", userId);
        aAudioAssetId = result.assetId;
      }

      // 4. Upsert card
      const cardId = existing?.id ?? crypto.randomUUID();
      const { error: upsertErr } = await supabase.from("memory_cards").upsert({
        id: cardId,
        deck_id: deck.id,
        photo_asset_id: photoAssetId,
        question_audio_asset_id: qAudioAssetId,
        answer_audio_asset_id: aAudioAssetId,
        question_text: questionText.trim(),
        answer_context: answerContext.trim(),
        display_order: displayOrder,
      });
      if (upsertErr) throw new Error(upsertErr.message);

      // 5. Touch deck updated_at
      await supabase
        .from("memory_decks")
        .update({ updated_at: new Date().toISOString() })
        .eq("id", deck.id);

      onSaved();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Save failed");
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="card-editor content-panel" style={{ maxWidth: 640 }}>
      <div className="panel-heading">
        <h2>{existing ? "Edit Card" : "Add Memory Card"}</h2>
      </div>
      {error && <p className="error" role="alert">{error}</p>}

      <form
        className="management-form"
        onSubmit={(e) => { void handleSubmit(e); }}
      >
        {/* Photo */}
        <div className="photo-upload">
          <span className="field" style={{ display: "block", marginBottom: 8 }}>
            Photo {!existing && <span style={{ color: "var(--danger)" }}>*</span>}
          </span>
          {photoPreview && (
            <div className="photo-preview">
              <img src={photoPreview} alt="Preview" />
            </div>
          )}
          <button
            type="button"
            className="btn btn-quiet"
            onClick={() => photoInputRef.current?.click()}
            disabled={saving}
          >
            {photoPreview ? "Change photo" : "Choose photo"}
          </button>
          <input
            ref={photoInputRef}
            type="file"
            accept="image/*"
            style={{ display: "none" }}
            onChange={handlePhotoChange}
            disabled={saving}
          />
          <span style={{ marginLeft: 8, fontSize: "var(--fs-caption)", color: "var(--text-muted)" }}>
            Max 10 MB
          </span>
        </div>

        {/* Question text */}
        <label className="field">
          Question text
          <textarea
            value={questionText}
            onChange={(e) => setQuestionText(e.target.value)}
            placeholder="What is happening in this photo?"
            rows={2}
            maxLength={500}
            required
            style={{ resize: "vertical", padding: "10px 14px" }}
          />
        </label>

        {/* Answer context */}
        <label className="field">
          Answer context
          <textarea
            value={answerContext}
            onChange={(e) => setAnswerContext(e.target.value)}
            placeholder="Background and expected answer to help the caregiver guide the session."
            rows={3}
            maxLength={1000}
            required
            style={{ resize: "vertical", padding: "10px 14px" }}
          />
        </label>

        {/* Question audio */}
        <AudioField
          label="Question audio (optional)"
          existingUrl={existing?.question_audio_url}
          recorder={qRecorder}
          onFileChosen={setQAudioFile}
          disabled={saving}
        />

        {/* Answer audio */}
        <AudioField
          label="Answer audio (optional)"
          existingUrl={existing?.answer_audio_url}
          recorder={aRecorder}
          onFileChosen={setAAudioFile}
          disabled={saving}
        />

        {/* Display order */}
        <label className="field" style={{ maxWidth: 160 }}>
          Display order
          <input
            type="number"
            value={displayOrder}
            onChange={(e) => setDisplayOrder(Number(e.target.value))}
            min={0}
            step={1}
          />
        </label>

        <div className="actions">
          <button type="submit" className="btn btn-primary" disabled={saving}>
            {saving ? "Saving…" : existing ? "Save changes" : "Add card"}
          </button>
          <button type="button" className="btn btn-quiet" onClick={onCancel} disabled={saving}>
            Cancel
          </button>
        </div>
      </form>
    </div>
  );
}

// ── Root component ────────────────────────────────────────────────────────────

type MemoryDecksProps = {
  user: User;
  selectedProfile: ElderlyProfile | null;
};

export function MemoryDecks({ user, selectedProfile }: MemoryDecksProps) {
  const [view, setView] = useState<View>({ name: "deck-list" });
  // Track existing card count for new cards' default display_order
  const [deckCardCount, setDeckCardCount] = useState(0);

  // Reset to list when profile changes
  useEffect(() => {
    setView({ name: "deck-list" });
  }, [selectedProfile?.id]);

  if (!selectedProfile) {
    return (
      <section className="content-panel feature-placeholder">
        <h2>Memory Decks</h2>
        <p className="empty-state">Select an elderly profile from the sidebar to manage their memory decks.</p>
      </section>
    );
  }

  // ── View routing ────────────────────────────────────────────────────────────

  if (view.name === "deck-list") {
    return (
      <section className="content-panel">
        <DeckList
          profile={selectedProfile}
          userId={user.id}
          onCreateDeck={() => setView({ name: "create-deck" })}
          onEditDeck={(deck) => setView({ name: "edit-deck", deck })}
          onOpenDeck={async (deck) => {
            // Pre-fetch card count for default display_order
            const { count } = await supabase
              .from("memory_cards")
              .select("id", { count: "exact", head: true })
              .eq("deck_id", deck.id);
            setDeckCardCount(count ?? 0);
            setView({ name: "deck-detail", deck });
          }}
        />
      </section>
    );
  }

  if (view.name === "create-deck") {
    return (
      <section className="content-panel">
        <DeckForm
          profile={selectedProfile}
          userId={user.id}
          onSaved={() => setView({ name: "deck-list" })}
          onCancel={() => setView({ name: "deck-list" })}
        />
      </section>
    );
  }

  if (view.name === "edit-deck") {
    return (
      <section className="content-panel">
        <DeckForm
          profile={selectedProfile}
          userId={user.id}
          existing={view.deck}
          onSaved={() => setView({ name: "deck-list" })}
          onCancel={() => setView({ name: "deck-list" })}
        />
      </section>
    );
  }

  if (view.name === "deck-detail") {
    return (
      <section className="content-panel">
        <DeckDetail
          deck={view.deck}
          userId={user.id}
          onBack={() => setView({ name: "deck-list" })}
          onAddCard={() => setView({ name: "create-card", deck: view.deck })}
          onEditCard={(card) => setView({ name: "edit-card", deck: view.deck, card })}
        />
      </section>
    );
  }

  if (view.name === "create-card") {
    return (
      <section className="content-panel">
        <CardEditor
          deck={view.deck}
          profile={selectedProfile}
          userId={user.id}
          existingCardCount={deckCardCount}
          onSaved={() => setView({ name: "deck-detail", deck: view.deck })}
          onCancel={() => setView({ name: "deck-detail", deck: view.deck })}
        />
      </section>
    );
  }

  if (view.name === "edit-card") {
    return (
      <section className="content-panel">
        <CardEditor
          deck={view.deck}
          profile={selectedProfile}
          userId={user.id}
          existing={view.card}
          existingCardCount={deckCardCount}
          onSaved={() => setView({ name: "deck-detail", deck: view.deck })}
          onCancel={() => setView({ name: "deck-detail", deck: view.deck })}
        />
      </section>
    );
  }

  return null;
}
