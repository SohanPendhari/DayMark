import 'package:flutter/material.dart';
import 'daymark_tokens.dart';

/// Semantic colours Material's ColorScheme has no slot for.
@immutable
class DmSemanticColors extends ThemeExtension<DmSemanticColors> {
  const DmSemanticColors({
    required this.gold,
    required this.goldText,
    required this.success,
    required this.warning,
    required this.surfaceMuted,
    required this.border,
    required this.controlBorder,
  });

  final Color gold; // accents, progress fills, focus indicators
  final Color goldText; // gold-family text; AA on its theme background
  final Color success, warning;
  final Color surfaceMuted, border, controlBorder;

  static const light = DmSemanticColors(
    gold: DmColors.gold,
    goldText: DmColors.goldInk,
    success: DmColors.successLight,
    warning: DmColors.warningLight,
    surfaceMuted: DmColors.lightSurfaceMuted,
    border: DmColors.lightBorder,
    controlBorder: DmColors.lightControlBorder,
  );

  static const dark = DmSemanticColors(
    gold: DmColors.gold,
    goldText: DmColors.goldSoft,
    success: DmColors.successDark,
    warning: DmColors.warningDark,
    surfaceMuted: DmColors.darkSurfaceMuted,
    border: DmColors.darkBorder,
    controlBorder: DmColors.darkControlBorder,
  );

  @override
  DmSemanticColors copyWith({Color? gold, Color? goldText, Color? success, Color? warning,
          Color? surfaceMuted, Color? border, Color? controlBorder}) =>
      DmSemanticColors(
        gold: gold ?? this.gold,
        goldText: goldText ?? this.goldText,
        success: success ?? this.success,
        warning: warning ?? this.warning,
        surfaceMuted: surfaceMuted ?? this.surfaceMuted,
        border: border ?? this.border,
        controlBorder: controlBorder ?? this.controlBorder,
      );

  @override
  DmSemanticColors lerp(ThemeExtension<DmSemanticColors>? other, double t) {
    if (other is! DmSemanticColors) return this;
    return DmSemanticColors(
      gold: Color.lerp(gold, other.gold, t)!,
      goldText: Color.lerp(goldText, other.goldText, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      surfaceMuted: Color.lerp(surfaceMuted, other.surfaceMuted, t)!,
      border: Color.lerp(border, other.border, t)!,
      controlBorder: Color.lerp(controlBorder, other.controlBorder, t)!,
    );
  }
}

extension DmThemeX on BuildContext {
  DmSemanticColors get dm => Theme.of(this).extension<DmSemanticColors>()!;
}

abstract final class DaymarkTheme {
  static ThemeData get light => _build(
        const ColorScheme(
          brightness: Brightness.light,
          primary: DmColors.lightText, // charcoal buttons; gold stays an accent
          onPrimary: DmColors.lightBackground,
          secondary: DmColors.gold,
          onSecondary: DmColors.lightText,
          error: DmColors.errorLight,
          onError: Colors.white,
          surface: DmColors.lightSurface,
          onSurface: DmColors.lightText,
          onSurfaceVariant: DmColors.lightTextSecondary,
          outline: DmColors.lightControlBorder,
          outlineVariant: DmColors.lightBorder,
        ),
        DmColors.lightBackground,
        DmSemanticColors.light,
      );

  static ThemeData get dark => _build(
        const ColorScheme(
          brightness: Brightness.dark,
          primary: DmColors.gold, // on dark, gold is the primary action colour
          onPrimary: DmColors.darkBackground, // 6.9:1 on gold
          secondary: DmColors.goldSoft,
          onSecondary: DmColors.darkBackground,
          error: DmColors.errorDark,
          onError: DmColors.darkBackground,
          surface: DmColors.darkSurface,
          onSurface: DmColors.darkText,
          onSurfaceVariant: DmColors.darkTextSecondary,
          outline: DmColors.darkControlBorder,
          outlineVariant: DmColors.darkBorder,
        ),
        DmColors.darkBackground,
        DmSemanticColors.dark,
      );

  static ThemeData _build(ColorScheme cs, Color background, DmSemanticColors dm) {
    final text = TextTheme(
      headlineMedium: DmFont.pageTitle,
      titleLarge: DmFont.sectionHeading,
      titleMedium: DmFont.taskTitle,
      bodyLarge: DmFont.body,
      bodyMedium: DmFont.body,
      labelLarge: DmFont.button,
      labelMedium: DmFont.label,
      labelSmall: DmFont.metadata,
      displaySmall: DmFont.metric,
    ).apply(bodyColor: cs.onSurface, displayColor: cs.onSurface);

    final focusRing = BorderSide(color: dm.goldText, width: 2);
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(DmRadius.md));
    const minSize = Size(DmSize.minTouchTarget, DmSize.minTouchTarget);

    return ThemeData(
      useMaterial3: true,
      colorScheme: cs,
      scaffoldBackgroundColor: background,
      fontFamily: DmFont.family,
      textTheme: text,
      extensions: [dm],
      visualDensity: VisualDensity.standard,
      dividerTheme: DividerThemeData(color: dm.border, space: 1, thickness: 1),
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        foregroundColor: cs.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: DmFont.sectionHeading.copyWith(color: cs.onSurface),
      ),
      cardTheme: CardThemeData(
        color: cs.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DmRadius.lg),
          side: BorderSide(color: dm.border),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: minSize,
          shape: shape,
          textStyle: DmFont.button,
          padding: const EdgeInsets.symmetric(horizontal: DmSpace.x3),
        ).copyWith(side: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.focused) ? focusRing : null)),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: minSize,
          shape: shape,
          textStyle: DmFont.button,
          side: BorderSide(color: dm.controlBorder),
          foregroundColor: cs.onSurface,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: minSize,
          shape: shape,
          textStyle: DmFont.button,
          foregroundColor: dm.goldText,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: cs.surface,
        contentPadding: const EdgeInsets.symmetric(horizontal: DmSpace.x2, vertical: DmSpace.x1_5),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DmRadius.md),
          borderSide: BorderSide(color: dm.controlBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DmRadius.md),
          borderSide: BorderSide(color: dm.controlBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DmRadius.md),
          borderSide: BorderSide(color: dm.goldText, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DmRadius.md),
          borderSide: BorderSide(color: cs.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DmRadius.md),
          borderSide: BorderSide(color: cs.error, width: 2),
        ),
        labelStyle: DmFont.label.copyWith(color: cs.onSurfaceVariant),
        helperStyle: DmFont.metadata.copyWith(color: cs.onSurfaceVariant),
        errorStyle: DmFont.metadata.copyWith(color: cs.error),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: dm.surfaceMuted,
        side: BorderSide.none,
        labelStyle: DmFont.label.copyWith(color: cs.onSurface),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DmRadius.sm)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: cs.surface,
        indicatorColor: dm.gold.withValues(alpha: 0.24),
        height: 64,
        labelTextStyle: WidgetStatePropertyAll(DmFont.metadata),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: cs.surface,
        indicatorColor: dm.gold.withValues(alpha: 0.24),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: cs.surface,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(DmRadius.lg)),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: dm.gold,
        linearTrackColor: dm.surfaceMuted,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: shape,
      ),
    );
  }
}
