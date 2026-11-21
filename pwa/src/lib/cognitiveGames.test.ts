import { describe, expect, it } from "vitest";
import {
  oddOneOutIsCorrect,
  oddOneOutRounds,
  sortingGame,
  sortingIsCorrect,
  speechLocale,
} from "./cognitiveGames";

describe("shared cognitive game content", () => {
  it("gives every Odd One Out round one unambiguous expected choice", () => {
    expect(oddOneOutRounds.length).toBeGreaterThanOrEqual(3);
    for (const round of oddOneOutRounds) {
      expect(round.items).toHaveLength(4);
      expect(round.items.filter((item) => item.id === round.expected_item_id)).toHaveLength(1);
    }
    expect(oddOneOutIsCorrect("chair", "chair")).toBe(true);
    expect(oddOneOutIsCorrect("apple", "chair")).toBe(false);
  });

  it("sorts every familiar object into one of the two provided categories", () => {
    expect(sortingGame.categories).toHaveLength(2);
    for (const item of sortingGame.items) {
      expect(sortingGame.categories.some((category) => category.id === item.category_id)).toBe(true);
    }
    expect(sortingIsCorrect("fruit", "fruit")).toBe(true);
    expect(sortingIsCorrect("vegetable", "fruit")).toBe(false);
  });

  it("uses the selected profile language for spoken instructions", () => {
    expect(speechLocale("en")).toBe("en-IN");
    expect(speechLocale("hi")).toBe("en-IN");
    expect(speechLocale("mr")).toBe("en-IN");
  });
});
