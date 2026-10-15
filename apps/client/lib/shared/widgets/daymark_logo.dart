import 'package:flutter/material.dart';

import '../../core/theme/daymark_tokens.dart';

/// The only place that knows the logo asset paths. Screens (onboarding, dashboard,
/// desktop sidebar, settings, About ...) must use [DaymarkLogo] / [DaymarkMark] instead of
/// referencing files, so light/dark handling lives in one spot.
///
/// The artwork is the supplied raster brand set, used as-is (never recoloured or redrawn).
abstract final class DmAssets {
  static const logoLight = 'assets/brand/logo/daymark-logo.png'; // opaque, off-white background
  static const logoDark = 'assets/brand/logo/daymark-logo-dark.png'; // opaque, charcoal background
  static const symbol = 'assets/brand/logo/daymark-symbol.png'; // transparent; check is see-through
}

/// Horizontal DAYMARK logo. Picks the light or dark variant from the current theme.
///
/// [height] is the height of the visible artwork, not of the PNG canvas: the two supplied
/// files pad their artwork differently (ink fills 82% of the light canvas height but only
/// 73% of the dark one), so the canvas is scaled per variant to make both look the same size.
/// The PNGs are 195 px / 170 px tall; keep [height] <= 56 logical px to stay sharp at 3x.
class DaymarkLogo extends StatelessWidget {
  const DaymarkLogo({super.key, this.height = 32});

  final double height;

  static const _lightInk = 0.82;
  static const _darkInk = 0.73;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final image = Image.asset(
      dark ? DmAssets.logoDark : DmAssets.logoLight,
      height: height / (dark ? _darkInk : _lightInk),
      filterQuality: FilterQuality.medium,
      semanticLabel: 'DAYMARK',
    );
    // Round the baked-in dark background so it reads as a deliberate plate on elevated surfaces.
    return dark ? ClipRRect(borderRadius: BorderRadius.circular(DmRadius.sm), child: image) : image;
  }
}

/// Standalone DAYMARK symbol for avatars, loading states and small spaces.
///
/// The supplied symbol is transparent with a see-through check, so on a dark surface its
/// charcoal tile would vanish. In dark mode it is therefore placed on the brand off-white,
/// the same way the supplied app icon presents it.
class DaymarkMark extends StatelessWidget {
  const DaymarkMark({super.key, this.size = 40});

  final double size;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final mark = Image.asset(
      DmAssets.symbol,
      width: size,
      height: size,
      filterQuality: FilterQuality.medium,
      semanticLabel: 'DAYMARK',
    );
    if (!dark) return mark;
    final pad = size * 0.14;
    return Container(
      width: size + pad * 2,
      height: size + pad * 2,
      padding: EdgeInsets.all(pad),
      decoration: BoxDecoration(
        color: DmColors.lightBackground,
        borderRadius: BorderRadius.circular(DmRadius.md),
      ),
      child: mark,
    );
  }
}
