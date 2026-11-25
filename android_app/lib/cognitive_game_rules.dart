const oddOneOutActivityKey = 'odd_one_out';
const everydayObjectSortingActivityKey = 'everyday_object_sorting';

bool isCognitiveGameActivityKey(String? key) =>
    key == oddOneOutActivityKey || key == everydayObjectSortingActivityKey;

bool oddOneOutIsCorrect(String selectedItemId, String expectedItemId) =>
    selectedItemId == expectedItemId;

bool sortingIsCorrect(String selectedCategoryId, String expectedCategoryId) =>
    selectedCategoryId == expectedCategoryId;

String supportedSpeechLanguage(String? languageCode) {
  final code = languageCode?.toLowerCase().split(RegExp('[-_]')).first;
  return const {'en', 'hi', 'mr'}.contains(code) ? code! : 'hi';
}

String speechLocale(String? languageCode) =>
    '${supportedSpeechLanguage(languageCode)}-IN';

String spokenEncouragement(String? languageCode, {required bool correct}) {
  final language = supportedSpeechLanguage(languageCode);
  if (language == 'mr') return correct ? 'छान!' : 'काही हरकत नाही.';
  if (language == 'en') return correct ? 'Well done!' : 'That is okay.';
  return correct ? 'बहुत अच्छा!' : 'कोई बात नहीं।';
}

String spokenCompletion(String? languageCode) {
  switch (supportedSpeechLanguage(languageCode)) {
    case 'en':
      return 'Activity complete. Thank you for taking part.';
    case 'mr':
      return 'उपक्रम पूर्ण झाला. सहभागी झाल्याबद्दल धन्यवाद.';
    default:
      return 'गतिविधि पूरी हुई। भाग लेने के लिए धन्यवाद।';
  }
}

String spokenPlacement(String? languageCode, String item, String category) {
  switch (supportedSpeechLanguage(languageCode)) {
    case 'en':
      return '$item placed in $category. You can change it if you like.';
    case 'mr':
      return 'तुम्ही $item ही वस्तू $category गटात ठेवली आहे. हवे असल्यास ती बदलू शकता.';
    default:
      return 'आपने $item को $category वाले समूह में रखा है। चाहें तो इसे बदल सकते हैं।';
  }
}

String spokenText(Object? translations, String? languageCode,
    {String fallback = ''}) {
  if (translations is String) return translations;
  if (translations is! Map) return fallback;
  final language = supportedSpeechLanguage(languageCode);
  return translations[language]?.toString() ?? fallback;
}
