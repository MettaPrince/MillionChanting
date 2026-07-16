import 'package:flutter/material.dart';

// Ported 1:1 from index.html's :root CSS variables.
class AppColors {
  static const bg = Color(0xFF0A0A0C);
  static const card = Color(0xFF141416);
  static const textMain = Color(0xFFE0E0E0);
  static const textMuted = Color(0xFF4A4A52);
  static const gold = Color(0xFFD4AF37);
  static const goldLight = Color(0xFFF9E596);
  static const greenCompleted = Color(0xFF2ECC71);
  static const danger = Color(0xFFE74C3C);
  static const debugNeon = Color(0xFFFF2A5F);
}

final appTheme = ThemeData(
  brightness: Brightness.dark,
  scaffoldBackgroundColor: AppColors.bg,
  fontFamily: 'Prompt',
  colorScheme: const ColorScheme.dark(
    primary: AppColors.gold,
    secondary: AppColors.goldLight,
    surface: AppColors.card,
  ),
  useMaterial3: true,
);
