import 'package:flutter/material.dart';

class AppTheme {
  static const Color primaryGreen = Color(0xFF0F6B4E);
  static const Color accentGold = Color(0xFFD99B26);
  static const Color surfaceLight = Color(0xFFF6F8F7);

  static const Color bandGreen = Color(0xFF2E9E55);
  static const Color bandOrange = Color(0xFFE08A00);
  static const Color bandRed = Color(0xFFD1344B);

  static ThemeData lightTheme() {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primaryGreen,
        brightness: Brightness.light,
        surface: surfaceLight,
      ),
      fontFamily: 'Cairo',
    );
    return base.copyWith(
      appBarTheme: const AppBarTheme(
        centerTitle: true,
        backgroundColor: primaryGreen,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        elevation: 1,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        color: Colors.white,
      ),
    );
  }
}
