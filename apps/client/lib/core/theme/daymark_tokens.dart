import 'package:flutter/material.dart';

/// Single source of truth for DAYMARK design tokens.
/// Never hardcode colours, spacing, radii or text styles elsewhere.
/// Contrast ratios noted below were computed against WCAG 2.x.
abstract final class DmColors {
  // Brand
  static const gold = Color(0xFFC9A85A); // brand accent (supplied palette). Fills only: NOT text on light (2.1:1)
  static const goldInk = Color(0xFF7A5C1A); // gold-family text on light: 5.8:1 on #F7F7F4
  static const goldSoft = Color(0xFFD4B572); // gold text on dark: 7.9:1 on #202428

  // Light
  static const lightBackground = Color(0xFFF7F7F4);
  static const lightSurface = Color(0xFFFFFFFF);
  static const lightSurfaceMuted = Color(0xFFEFEFEA);
  static const lightText = Color(0xFF202428); // brand charcoal (supplied palette): 14.6:1
  static const lightTextSecondary = Color(0xFF5F6368); // 5.6:1
  static const lightBorder = Color(0xFFE3E3DD); // decorative dividers only
  static const lightControlBorder = Color(0xFF868A8F); // inputs: 3.2:1 (WCAG 1.4.11)

  // Dark
  // Brand charcoal. The supplied dark logo has this colour baked in as its background,
  // so it must sit on this exact surface to blend in seamlessly.
  static const darkBackground = Color(0xFF202428);
  static const darkSurface = Color(0xFF272B31); // elevated above the background
  static const darkSurfaceMuted = Color(0xFF30343B);
  static const darkText = Color(0xFFECECE8); // 13.2:1 on background, 12.0:1 on surface
  static const darkTextSecondary = Color(0xFFA0A4AB); // 6.2:1 on background, 5.7:1 on surface
  static const darkBorder = Color(0xFF3A3F47);
  static const darkControlBorder = Color(0xFF7C8088); // 3.9:1 on background, 3.6:1 on surface

  // Status (light / dark pairs; each >= 4.5:1 against its theme surface)
  static const successLight = Color(0xFF1E7D4F);
  static const warningLight = Color(0xFF8F5B00);
  static const errorLight = Color(0xFFB3261E);
  static const successDark = Color(0xFF5CC594);
  static const warningDark = Color(0xFFE0A93B);
  static const errorDark = Color(0xFFF2877F);
}

/// 8-point spacing scale.
abstract final class DmSpace {
  static const double x0_5 = 4;
  static const double x1 = 8;
  static const double x1_5 = 12;
  static const double x2 = 16;
  static const double x3 = 24;
  static const double x4 = 32;
  static const double x5 = 40;
  static const double x6 = 48;
  static const double x8 = 64;
}

abstract final class DmRadius {
  static const double sm = 8; // chips, small controls
  static const double md = 12; // inputs, buttons, list items
  static const double lg = 16; // cards, sheets
  static const double full = 999;
}

abstract final class DmSize {
  static const double minTouchTarget = 48; // Android/Material guidance
  static const double sidebarExpanded = 248;
  static const double sidebarCollapsed = 72;
  static const double contentMaxWidth = 880; // keeps desktop line lengths readable
  static const double detailPanelWidth = 360;
  static const double compactBreakpoint = 600; // < : phone layout
  static const double expandedBreakpoint = 1024; // >= : desktop layout
}

abstract final class DmFont {
  static const family = 'Manrope';

  /// Tabular figures keep times, durations and metrics from jittering.
  static const tabular = [FontFeature.tabularFigures()];

  static TextStyle _s(double size, double weight, double height, {double ls = 0}) => TextStyle(
        fontFamily: family,
        fontSize: size,
        height: height / size,
        letterSpacing: ls,
        fontWeight: FontWeight.values[((weight / 100).round() - 1).clamp(0, 8)],
        fontVariations: [FontVariation('wght', weight)],
      );

  // Type scale (size / line height in logical px)
  static final pageTitle = _s(28, 700, 36, ls: -0.4);
  static final sectionHeading = _s(18, 700, 26, ls: -0.1);
  static final taskTitle = _s(16, 600, 24);
  static final body = _s(15, 500, 22);
  static final label = _s(13, 600, 18, ls: 0.1);
  static final metadata = _s(12, 500, 16, ls: 0.1);
  static final button = _s(14, 700, 20, ls: 0.1);

  /// Large number for metrics (use with [tabular]).
  static final metric = _s(32, 700, 40, ls: -0.5);
}
