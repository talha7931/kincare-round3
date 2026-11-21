const oddOneOutActivityKey = 'odd_one_out';
const everydayObjectSortingActivityKey = 'everyday_object_sorting';

bool isCognitiveGameActivityKey(String? key) =>
    key == oddOneOutActivityKey || key == everydayObjectSortingActivityKey;

bool oddOneOutIsCorrect(String selectedItemId, String expectedItemId) =>
    selectedItemId == expectedItemId;

bool sortingIsCorrect(String selectedCategoryId, String expectedCategoryId) =>
    selectedCategoryId == expectedCategoryId;
