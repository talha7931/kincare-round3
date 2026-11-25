import { useRef, useState } from "react";
import type { ElderlyProfile } from "./MemoryDecks";
import { supabase } from "../lib/supabase";
import {
  oddOneOutIsCorrect,
  oddOneOutRounds,
  cognitiveGameActivityKeys,
  type CognitiveGameActivityKey,
  sortingGame,
  sortingIsCorrect,
  speechLocale,
  spokenText,
  supportedSpeechLanguage,
} from "../lib/cognitiveGames";
import {
  completeActivitySession,
  saveActivityResponses,
  startActivitySession,
} from "../lib/activityPersistence";

type CognitiveGamesProps = {
  profile: ElderlyProfile;
  game: CognitiveGameActivityKey;
  onBack: () => void;
  onHome: () => void;
};

type PendingOddResponse = {
  id: string;
  responseIndex: number;
  payload: Record<string, unknown>;
  isCorrect: boolean;
};

function speak(text: string, language: string, queue = false) {
  if (!("speechSynthesis" in window)) return false;
  if (!queue) window.speechSynthesis.cancel();
  const utterance = new SpeechSynthesisUtterance(text);
  utterance.lang = speechLocale(language);
  window.speechSynthesis.speak(utterance);
  return true;
}

export function CognitiveGames({ profile, game, onBack, onHome }: CognitiveGamesProps) {
  const sorting = game === cognitiveGameActivityKeys.sorting;
  const activityKey = game;
  const title = sorting ? "Everyday Object Sorting" : "Odd One Out";
  const [stage, setStage] = useState<"intro" | "playing" | "complete">("intro");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [sessionId, setSessionId] = useState<string | null>(null);
  const [roundIndex, setRoundIndex] = useState(0);
  const [selectedItemId, setSelectedItemId] = useState<string | null>(null);
  const [savedOddResponse, setSavedOddResponse] = useState(false);
  const [feedback, setFeedback] = useState("");
  const [selectedSortingItem, setSelectedSortingItem] = useState<string | null>(null);
  const [placements, setPlacements] = useState<Record<string, string>>({});
  const responseIds = useRef<Record<string, string>>({});
  const language = supportedSpeechLanguage(profile.preferred_language);
  const round = oddOneOutRounds[roundIndex];
  const roundSpeech = round.spoken?.[language];
  const sortingSpeech = sortingGame.spoken?.[language];

  const playInstruction = () => {
    const text = sorting
      ? sortingSpeech?.instruction ?? sortingGame.instruction
      : roundSpeech?.instruction ?? round.instruction;
    if (!speak(text, language)) setError("Audio is unavailable. Please read the instruction shown on screen.");
  };

  const begin = async () => {
    setBusy(true);
    setError("");
    try {
      const id = await startActivitySession(profile.id, activityKey);
      setSessionId(id);
      setStage("playing");
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "The activity could not be started. Check the connection and try again.");
    } finally {
      setBusy(false);
    }
  };

  const finishSession = async (announce = true) => {
    if (!sessionId) return;
    setBusy(true);
    setError("");
    try {
      await completeActivitySession(sessionId);
      setStage("complete");
      setFeedback("Thank you for taking part. You can enjoy another activity whenever you like.");
      const completion = sorting
        ? sortingSpeech?.complete ?? "Activity complete. Thank you for taking part."
        : language === "mr"
          ? "उपक्रम पूर्ण झाला. सहभागी झाल्याबद्दल धन्यवाद."
          : language === "en"
            ? "Activity complete. Thank you for taking part."
            : "गतिविधि पूरी हुई। भाग लेने के लिए धन्यवाद।";
      speak(completion, language, !announce);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "The activity could not be marked complete. Please try again.");
    } finally {
      setBusy(false);
    }
  };

  const leaveActivity = async (home: boolean) => {
    if (busy) return;
    if (sessionId && stage === "playing") {
      setBusy(true);
      setError("");
      try {
        const { error: abandonError } = await supabase
          .from("activity_sessions")
          .update({ status: "abandoned" })
          .eq("id", sessionId);
        if (abandonError) throw abandonError;
      } catch (cause) {
        setError(cause instanceof Error ? cause.message : "The activity could not be closed safely. Please try again.");
        setBusy(false);
        return;
      }
      setBusy(false);
    }
    if (home) onHome();
    else onBack();
  };

  const recordOddChoice = async (itemId: string) => {
    if (!sessionId || busy) return;
    const responseId = responseIds.current[`odd-${roundIndex}`] ?? window.crypto.randomUUID();
    responseIds.current[`odd-${roundIndex}`] = responseId;
    const isCorrect = oddOneOutIsCorrect(itemId, round.expected_item_id);
    const response: PendingOddResponse = {
      id: responseId,
      responseIndex: roundIndex,
      payload: {
        schema_version: 1,
        activity_type: "odd_one_out",
        round_id: round.id,
        selected_item_id: itemId,
        expected_item_id: round.expected_item_id,
      },
      isCorrect,
    };
    setSelectedItemId(itemId);
    setSavedOddResponse(false);
    setBusy(true);
    setError("");
    try {
      await saveActivityResponses(sessionId, [response]);
      setSavedOddResponse(true);
      const spokenExplanation = roundSpeech?.explanation ?? round.explanation;
      setFeedback(isCorrect
        ? `Well done! ${round.explanation}`
        : `That’s okay. ${round.explanation}`);
      speak(`${language === "hi" ? isCorrect ? "बहुत अच्छा।" : "कोई बात नहीं।" : language === "mr" ? isCorrect ? "छान!" : "काही हरकत नाही." : isCorrect ? "Well done!" : "That is okay."} ${spokenExplanation}`, language);
      if (roundIndex === oddOneOutRounds.length - 1) await finishSession(false);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Your answer could not be saved. Please try again.");
    } finally {
      setBusy(false);
    }
  };

  const retryOddSave = async () => {
    if (!sessionId || !selectedItemId) return;
    const responseId = responseIds.current[`odd-${roundIndex}`];
    if (!responseId) return;
    const response: PendingOddResponse = {
      id: responseId,
      responseIndex: roundIndex,
      payload: {
        schema_version: 1,
        activity_type: "odd_one_out",
        round_id: round.id,
        selected_item_id: selectedItemId,
        expected_item_id: round.expected_item_id,
      },
      isCorrect: oddOneOutIsCorrect(selectedItemId, round.expected_item_id),
    };
    setBusy(true);
    setError("");
    try {
      await saveActivityResponses(sessionId, [response]);
      setSavedOddResponse(true);
      setFeedback(response.isCorrect
        ? `Well done! ${round.explanation}`
        : `That’s okay. ${round.explanation}`);
      speak(`${language === "hi" ? response.isCorrect ? "बहुत अच्छा।" : "कोई बात नहीं।" : language === "mr" ? response.isCorrect ? "छान!" : "काही हरकत नाही." : response.isCorrect ? "Well done!" : "That is okay."} ${roundSpeech?.explanation ?? round.explanation}`, language);
      if (roundIndex === oddOneOutRounds.length - 1) await finishSession(false);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Your answer could not be saved. Please try again.");
    } finally {
      setBusy(false);
    }
  };

  const placeSortingItem = (categoryId: string) => {
    if (!selectedSortingItem) return;
    setPlacements((current) => ({ ...current, [selectedSortingItem]: categoryId }));
    const item = sortingGame.items.find((candidate) => candidate.id === selectedSortingItem);
    setFeedback(item ? `${item.label} placed. You can move it by choosing it again.` : "Object placed.");
    const category = sortingGame.categories.find((candidate) => candidate.id === categoryId);
    if (item && category) {
      const pattern = sortingSpeech?.placed ?? "{item} placed in {category}. You can change it if you like.";
      speak(pattern.replace("{item}", spokenText(item.spoken, language, item.label)).replace("{category}", spokenText(category.spoken, language, category.label)), language);
    }
    setSelectedSortingItem(null);
  };

  const finishSorting = async () => {
    if (!sessionId || Object.keys(placements).length !== sortingGame.items.length || busy) return;
    setBusy(true);
    setError("");
    try {
      const responses = sortingGame.items.map((item, index) => {
        const id = responseIds.current[`sort-${item.id}`] ?? window.crypto.randomUUID();
        responseIds.current[`sort-${item.id}`] = id;
        const selectedCategoryId = placements[item.id];
        return {
          id,
          responseIndex: index,
          isCorrect: sortingIsCorrect(selectedCategoryId, item.category_id ?? ""),
          payload: {
            schema_version: 1,
            activity_type: "everyday_object_sorting",
            item_id: item.id,
            selected_category_id: selectedCategoryId,
            expected_category_id: item.category_id,
          },
        };
      });
      await saveActivityResponses(sessionId, responses);
      await completeActivitySession(sessionId);
      setFeedback("Thank you for sorting these familiar foods.");
      setStage("complete");
      speak(sortingSpeech?.complete ?? "Activity complete. Thank you for taking part.", language);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Your choices could not be saved. Please try again.");
    } finally {
      setBusy(false);
    }
  };

  const retrySortingFinish = () => void finishSorting();

  return (
    <section className="senior-content cognitive-game" aria-label={title}>
      <div className="senior-choice-heading senior-choice-heading--pair">
        <button type="button" className="senior-back" disabled={busy} onClick={() => void leaveActivity(false)}>← Activities</button>
        <button type="button" className="senior-home" disabled={busy} onClick={() => void leaveActivity(true)}>Home</button>
      </div>
      <h2 className="cognitive-game-title">{title}</h2>
      {error && <p className="senior-message senior-error" role="alert">{error}</p>}

      {stage === "intro" && (
        <div className="cognitive-panel">
          <p className="cognitive-instruction">
            {sorting ? sortingGame.instruction : oddOneOutRounds[0].instruction}
          </p>
          <button type="button" className="senior-audio-btn" onClick={playInstruction}>🔊 Listen to Instructions</button>
          <button type="button" className="cognitive-primary-btn" disabled={busy} onClick={() => void begin()}>
            {busy ? "Starting…" : "Begin Activity"}
          </button>
        </div>
      )}

      {stage === "playing" && !sorting && (
        <div className="cognitive-panel">
          <div className="cognitive-round-label">Round {roundIndex + 1} of {oddOneOutRounds.length}</div>
          <p className="cognitive-instruction">{round.instruction}</p>
          <button type="button" className="cognitive-replay-btn" onClick={playInstruction}>🔊 Listen again</button>
          <div className="cognitive-object-grid">
            {round.items.map((item) => (
              <button
                type="button"
                key={item.id}
                className={`cognitive-object ${selectedItemId === item.id ? "is-selected" : ""}`}
                disabled={busy || savedOddResponse}
                onClick={() => {
                  if (speak(spokenText(item.spoken, language, item.label), language)) setError("");
                  void recordOddChoice(item.id);
                }}
                aria-label={`Choose ${item.label}`}
              >
                <span aria-hidden="true">{item.illustration}</span>
                <strong>{item.label}</strong>
              </button>
            ))}
          </div>
          {feedback && <p className="cognitive-feedback" role="status">{feedback}</p>}
          {error && selectedItemId && !savedOddResponse && (
            <button type="button" className="cognitive-primary-btn" disabled={busy} onClick={() => void retryOddSave()}>
              Try saving answer again
            </button>
          )}
          {savedOddResponse && roundIndex < oddOneOutRounds.length - 1 && (
            <button type="button" className="cognitive-primary-btn" disabled={busy} onClick={() => {
              setRoundIndex((index) => index + 1);
              setSelectedItemId(null);
              setSavedOddResponse(false);
              setFeedback("");
            }}>Next Round</button>
          )}
          {stage === "playing" && roundIndex === oddOneOutRounds.length - 1 && savedOddResponse && (
            <button type="button" className="cognitive-primary-btn" disabled={busy} onClick={() => void finishSession()}>
              {busy ? "Saving…" : "Finish Activity"}
            </button>
          )}
        </div>
      )}

      {stage === "playing" && sorting && (
        <div className="cognitive-panel">
          <p className="cognitive-instruction">{sortingGame.instruction}</p>
          <button type="button" className="cognitive-replay-btn" onClick={playInstruction}>🔊 Listen again</button>
          <div className="sorting-object-grid">
            {sortingGame.items.map((item) => {
              const categoryId = placements[item.id];
              const category = sortingGame.categories.find((candidate) => candidate.id === categoryId);
              return (
                <button
                  type="button"
                  key={item.id}
                  className={`cognitive-object sorting-object ${selectedSortingItem === item.id ? "is-selected" : ""}`}
                  onClick={() => {
                    setSelectedSortingItem(item.id);
                    setFeedback(`Choose a group for ${item.label}.`);
                    if (speak(spokenText(item.spoken, language, item.label), language)) setError("");
                  }}
                  aria-pressed={selectedSortingItem === item.id}
                >
                  <span aria-hidden="true">{item.illustration}</span>
                  <strong>{item.label}</strong>
                  <span className="sorting-placement">{category ? `Placed in ${category.label}` : "Choose this object"}</span>
                </button>
              );
            })}
          </div>
          <div className="sorting-category-grid" aria-label="Choose a category">
            {sortingGame.categories.map((category) => (
              <button
                type="button"
                key={category.id}
                className="sorting-category-btn"
                disabled={!selectedSortingItem || busy}
                onClick={() => {
                  if (speak(spokenText(category.spoken, language, category.label), language)) setError("");
                  placeSortingItem(category.id);
                }}
              >
                <span aria-hidden="true">{category.illustration}</span>{category.label}
              </button>
            ))}
          </div>
          {feedback && <p className="cognitive-feedback" role="status">{feedback}</p>}
          <button
            type="button"
            className="cognitive-primary-btn"
            disabled={busy || Object.keys(placements).length !== sortingGame.items.length}
            onClick={() => void finishSorting()}
          >
            {busy ? "Saving your choices…" : "Finish Sorting"}
          </button>
          {error && <button type="button" className="cognitive-retry-btn" disabled={busy} onClick={retrySortingFinish}>Try saving again</button>}
        </div>
      )}

      {stage === "complete" && (
        <div className="cognitive-panel cognitive-complete" role="status">
          <span aria-hidden="true">🌿</span>
          <h3>Activity complete</h3>
          <p>{feedback}</p>
          <button type="button" className="cognitive-primary-btn" onClick={onBack}>Back to Activities</button>
        </div>
      )}
    </section>
  );
}
