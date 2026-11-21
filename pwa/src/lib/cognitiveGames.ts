import content from "../../../android_app/assets/cognitive_games.json";

export const cognitiveGameActivityKeys = {
  oddOneOut: "odd_one_out",
  sorting: "everyday_object_sorting",
} as const;
export type CognitiveGameActivityKey =
  (typeof cognitiveGameActivityKeys)[keyof typeof cognitiveGameActivityKeys];

export function isCognitiveGameActivityKey(key: string | null): key is CognitiveGameActivityKey {
  return key === cognitiveGameActivityKeys.oddOneOut || key === cognitiveGameActivityKeys.sorting;
}

export type GameItem = {
  id: string;
  label: string;
  illustration: string;
  category_id?: string;
};

export type OddRound = {
  id: string;
  instruction: string;
  explanation: string;
  expected_item_id: string;
  items: GameItem[];
};

export const oddOneOutRounds = content.odd_one_out as OddRound[];
export const sortingGame = content.everyday_object_sorting as {
  instruction: string;
  categories: GameItem[];
  items: GameItem[];
};

export function oddOneOutIsCorrect(selectedItemId: string, expectedItemId: string) {
  return selectedItemId === expectedItemId;
}

export function sortingIsCorrect(selectedCategoryId: string, expectedCategoryId: string) {
  return selectedCategoryId === expectedCategoryId;
}

export function speechLocale(_languageCode: string) {
  // All bundled instructions and labels are currently English.
  return "en-IN";
}
