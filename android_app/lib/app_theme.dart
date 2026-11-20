import 'package:flutter/material.dart';

/// KinCare brand palette. These eight values are fixed by the design brief;
/// the remaining colours are alpha tints of them, never new hues.
abstract final class KinCareColors {
  static const Color forest = Color(0xFF183D35);
  static const Color sage = Color(0xFF477568);
  static const Color offWhite = Color(0xFFF4F4F3);
  static const Color white = Color(0xFFFFFFFF);
  static const Color paleSage = Color(0xFFE5EEE8);
  static const Color cloud = Color(0xFFE2E9ED);
  static const Color amber = Color(0xFFD9A45B);
  static const Color charcoal = Color(0xFF263238);
  static const Color textMuted = Color(0xFF5F6C68);
  static const Color danger = Color(0xFF8E3D37);

  /// 12% charcoal — panel borders and hairline row separators.
  static const Color line = Color.fromARGB(31, 38, 50, 56);

  /// 20% charcoal — input and quiet-button borders.
  static const Color lineStrong = Color.fromARGB(51, 38, 50, 56);

  /// 16% white — rules inside the forest sidebar.
  static const Color lineInvert = Color.fromARGB(41, 255, 255, 255);

  /// 4% forest — hover on light surfaces.
  static const Color tintHover = Color.fromARGB(10, 24, 61, 53);

  /// 12% sage — input focus halo.
  static const Color sageWash = Color.fromARGB(31, 71, 117, 104);

  /// 18% amber — prototype note and wellbeing note backgrounds.
  static const Color amberWash = Color.fromARGB(46, 217, 164, 91);

  /// 45% amber — borders on amber-wash surfaces.
  static const Color amberLine = Color.fromARGB(115, 217, 164, 91);

  /// 9% danger — error surface background.
  static const Color dangerWash = Color.fromARGB(23, 142, 61, 55);

  /// 32% danger — error surface border.
  static const Color dangerLine = Color.fromARGB(82, 142, 61, 55);
}

/// Corner radii shared by every surface, sorted from tightest to softest.
abstract final class KinCareRadii {
  static const double xs = 8;
  static const double sm = 10;
  static const double md = 14;
  static const double lg = 20;
  static const double xl = 22;
}

/// 4px-based spacing scale.
abstract final class KinCareSpace {
  static const double x1 = 4;
  static const double x2 = 8;
  static const double x3 = 12;
  static const double x4 = 16;
  static const double x5 = 20;
  static const double x6 = 24;
  static const double x7 = 32;
  static const double x8 = 40;
  static const double x9 = 48;
  static const double x10 = 64;
}

/// Elderly-mode floors from the brief: 64–72px controls, 22–28px text.
abstract final class KinCareSenior {
  static const double label = 22;
  static const double body = 24;
  static const double name = 27;
  static const double title = 32;
  static const double display = 38;
  static const double controlHeight = 72;
  static const double controlMin = 64;
  static const double tileMin = 176;
  static const double tileMinNarrow = 132;
}

/// Language codes are stored in Supabase; elderly and caregiver surfaces show
/// full names instead of the raw code.
const Map<String, String> kLanguageLabels = {
  'en': 'English',
  'hi': 'Hindi',
  'mr': 'Marathi',
};

String languageLabel(Object? code) {
  final value = code?.toString() ?? '';
  return kLanguageLabels[value] ?? value.toUpperCase();
}

String profileInitial(Object? displayName) {
  final trimmed = displayName?.toString().trim() ?? '';
  if (trimmed.isEmpty) return '\u2014';
  return trimmed.substring(0, 1).toUpperCase();
}

abstract final class KinCareTheme {
  static ThemeData build() {
    final ColorScheme colors = ColorScheme.fromSeed(
      seedColor: KinCareColors.sage,
      primary: KinCareColors.forest,
      brightness: Brightness.light,
    ).copyWith(
      secondary: KinCareColors.sage,
      surface: KinCareColors.white,
      onSurface: KinCareColors.charcoal,
      error: KinCareColors.danger,
    );

    const TextStyle headlineLarge = TextStyle(
      fontSize: 30,
      height: 1.25,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.4,
      color: KinCareColors.forest,
    );
    const TextStyle headlineMedium = TextStyle(
      fontSize: KinCareSenior.title,
      height: 1.3,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.3,
      color: KinCareColors.forest,
    );
    const TextStyle titleLarge = TextStyle(
      fontSize: 21,
      height: 1.35,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.2,
      color: KinCareColors.forest,
    );
    const TextStyle titleMedium = TextStyle(
      fontSize: 17,
      height: 1.4,
      fontWeight: FontWeight.w600,
      color: KinCareColors.forest,
    );
    const TextStyle bodyLarge = TextStyle(
      fontSize: 15,
      height: 1.6,
      color: KinCareColors.charcoal,
    );
    const TextStyle bodyMedium = TextStyle(
      fontSize: 14.5,
      height: 1.5,
      color: KinCareColors.charcoal,
    );
    const TextStyle labelLarge = TextStyle(
      fontSize: 15,
      height: 1.4,
      fontWeight: FontWeight.w600,
      color: KinCareColors.charcoal,
    );
    const TextStyle labelSmall = TextStyle(
      fontSize: 13,
      height: 1.45,
      fontWeight: FontWeight.w600,
      color: KinCareColors.textMuted,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colors,
      scaffoldBackgroundColor: KinCareColors.offWhite,
      splashFactory: NoSplash.splashFactory,
      textTheme: const TextTheme(
        headlineLarge: headlineLarge,
        headlineMedium: headlineMedium,
        headlineSmall: headlineLarge,
        titleLarge: titleLarge,
        titleMedium: titleMedium,
        bodyLarge: bodyLarge,
        bodyMedium: bodyMedium,
        labelLarge: labelLarge,
        labelSmall: labelSmall,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: KinCareColors.white,
        foregroundColor: KinCareColors.forest,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
          color: KinCareColors.forest,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: KinCareColors.white,
        isDense: false,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: KinCareSpace.x4,
          vertical: KinCareSpace.x3,
        ),
        labelStyle: const TextStyle(
          fontSize: 14,
          height: 1.4,
          fontWeight: FontWeight.w600,
          color: KinCareColors.charcoal,
        ),
        floatingLabelStyle: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: KinCareColors.forest,
        ),
        hintStyle: const TextStyle(color: KinCareColors.textMuted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(KinCareRadii.sm),
          borderSide: const BorderSide(color: KinCareColors.lineStrong),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(KinCareRadii.sm),
          borderSide: const BorderSide(color: KinCareColors.lineStrong),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(KinCareRadii.sm),
          borderSide: const BorderSide(color: KinCareColors.sage, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(KinCareRadii.sm),
          borderSide: const BorderSide(color: KinCareColors.danger),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: KinCareColors.forest,
          foregroundColor: KinCareColors.white,
          disabledBackgroundColor: KinCareColors.forest,
          disabledForegroundColor: KinCareColors.white,
          minimumSize: const Size(0, KinCareSpace.x9),
          padding: const EdgeInsets.symmetric(horizontal: KinCareSpace.x5),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(KinCareRadii.md),
          ),
          textStyle: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: KinCareColors.forest,
          side: BorderSide(color: KinCareColors.sage.withValues(alpha: 0.35)),
          minimumSize: const Size(0, KinCareSpace.x9),
          padding: const EdgeInsets.symmetric(horizontal: KinCareSpace.x5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(KinCareRadii.md),
          ),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: KinCareColors.sage,
          minimumSize: const Size(0, KinCareSpace.x8),
          padding: const EdgeInsets.symmetric(horizontal: KinCareSpace.x3),
          textStyle: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: KinCareColors.line,
        thickness: 1,
        space: 1,
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: KinCareSpace.x4,
          vertical: KinCareSpace.x2,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(KinCareRadii.md),
        ),
      ),
      cardTheme: CardThemeData(
        color: KinCareColors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(KinCareRadii.lg),
          side: const BorderSide(color: KinCareColors.line),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: KinCareColors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(KinCareRadii.lg),
        ),
        titleTextStyle: titleLarge,
        contentTextStyle: bodyLarge,
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        textStyle: bodyLarge,
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: KinCareColors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(KinCareRadii.sm),
            borderSide: const BorderSide(color: KinCareColors.lineStrong),
          ),
        ),
      ),
    );
  }
}
