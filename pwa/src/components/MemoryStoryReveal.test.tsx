import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import { MemoryStoryReveal } from "./MemoryStoryReveal";

describe("MemoryStoryReveal", () => {
  it("keeps story text and answer audio control out of the initial rendered card", () => {
    const markup = renderToStaticMarkup(
      <MemoryStoryReveal
        story="Grandma made mango pickles every summer."
        answerAudioUrl="https://example.test/story.mp3"
        isPlaying={false}
        onToggleAudio={vi.fn()}
      />,
    );

    expect(markup).toContain("Reveal Memory Story");
    expect(markup).not.toContain("Grandma made mango pickles every summer.");
    expect(markup).not.toContain("Memory Story</span>");
    expect(markup).not.toContain("Listen to Story");
    expect(markup).not.toContain("story.mp3");
  });
});
