import { useState } from "react";

type MemoryStoryRevealProps = {
  story: string;
  answerAudioUrl?: string;
  isPlaying: boolean;
  onToggleAudio: () => void;
};

export function MemoryStoryReveal({
  story,
  answerAudioUrl,
  isPlaying,
  onToggleAudio,
}: MemoryStoryRevealProps) {
  const [revealed, setRevealed] = useState(false);
  if (!story && !answerAudioUrl) return null;

  if (!revealed) {
    return (
      <button
        type="button"
        className="senior-reveal-btn"
        onClick={() => setRevealed(true)}
      >
        Reveal Memory Story
      </button>
    );
  }

  return (
    <div className="senior-story-box" aria-live="polite">
      <span className="senior-section-tag">Memory Story</span>
      {story && <p className="senior-story-text">{story}</p>}
      {answerAudioUrl && (
        <button
          type="button"
          className={`senior-audio-btn ${isPlaying ? "senior-audio-active" : ""}`}
          onClick={onToggleAudio}
        >
          {isPlaying ? "⏹ Stop Story" : "🔊 Listen to Story"}
        </button>
      )}
    </div>
  );
}
