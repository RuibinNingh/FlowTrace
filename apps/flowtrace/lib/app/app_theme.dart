import 'package:flutter/material.dart';

abstract final class AppTheme {
  static ThemeData dark() => _build(Brightness.dark);
  static ThemeData light() => _build(Brightness.light);

  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final colors = ColorScheme.fromSeed(
      seedColor: const Color(0xFF7EA3FA),
      brightness: brightness,
      surface: dark ? const Color(0xFF191919) : const Color(0xFFF8F8FA),
    );
    return ThemeData(
      useMaterial3: true,
      fontFamilyFallback: const ['NotoSansCJKSC'],
      colorScheme: colors,
      scaffoldBackgroundColor: dark
          ? const Color(0xFF090909)
          : const Color(0xFFF2F3F6),
      appBarTheme: AppBarTheme(
        backgroundColor: dark
            ? const Color(0xFF090909)
            : const Color(0xFFF2F3F6),
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        margin: EdgeInsets.zero,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: Color(0xFF3593FD),
        foregroundColor: Colors.white,
        shape: CircleBorder(),
      ),
    );
  }
}
