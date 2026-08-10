import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Single dark theme. Tokens mirror the names used in the Pencil wireframe so
/// screen code can read them by intent (`palette.green`, `palette.sheet`)
/// rather than by raw hex. Light mode and any theme switching are gone - the
/// app commits to dark only.
class AppColors {
  static const primary = Color(0xFFFF8400);
  static const onPrimary = Color(0xFF111111);

  static const background = Color(0xFF111111);
  static const foreground = Color(0xFFFFFFFF);
  static const card = Color(0xFF1A1A1A);
  static const mutedFg = Color(0xFFB8B9B6);
  static const border = Color(0xFF2E2E2E);
  static const secondary = Color(0xFF2E2E2E);
  static const accent = Color(0xFFFFB266);
  static const sheet = Color(0xFF161616);
  static const overlay = Color(0x99000000);

  // Bank-logo tile background. Sophtron's institution logos vary in style
  // and the dark `secondary` tile made dark-on-transparent logos look
  // shadowed/illegible — this light tile reads cleanly for any of them.
  // Used everywhere a real bank logo image renders in a circular/rounded
  // avatar (institution picker, popular banks grid, BankStepHeader).
  static const bankLogoTile = Color(0xFFF0F0F0);

  static const green = Color(0xFF1F8A4C);
  static const greenBg = Color(0xFF143E27);
  static const amber = Color(0xFFF2A93B);
  static const amberBg = Color(0xFF3D2E12);
  static const red = Color(0xFFE5484D);
  static const redBg = Color(0xFF3A1417);
  static const destructive = Color(0xFFFF5C33);
}

const double kRadiusXs = 6;
const double kRadiusS = 10;
const double kRadiusM = 16;
const double kRadiusPill = 999;

/// Display / type ramp. Inter for prose and labels, JetBrains Mono for money
/// and timestamps. Helpers wrap `GoogleFonts` so callers don't sprinkle
/// `GoogleFonts.inter(...)` across the codebase - they reach in via
/// `AppText.titleMd` etc.
class AppText {
  AppText._();

  static TextStyle displayLg({Color? color}) => GoogleFonts.inter(
    fontSize: 32,
    fontWeight: FontWeight.w700,
    color: color ?? AppColors.foreground,
    height: 1.15,
  );

  static TextStyle titleLg({Color? color}) => GoogleFonts.inter(
    fontSize: 20,
    fontWeight: FontWeight.w600,
    color: color ?? AppColors.foreground,
    height: 1.2,
  );

  static TextStyle titleMd({Color? color}) => GoogleFonts.inter(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    color: color ?? AppColors.foreground,
    height: 1.25,
  );

  static TextStyle bodyMd({Color? color}) => GoogleFonts.inter(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    color: color ?? AppColors.foreground,
    height: 1.4,
  );

  static TextStyle bodySm({Color? color}) => GoogleFonts.inter(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    color: color ?? AppColors.mutedFg,
    height: 1.35,
  );

  static TextStyle labelSm({Color? color}) => GoogleFonts.inter(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    color: color ?? AppColors.mutedFg,
    height: 1.2,
    letterSpacing: 0.4,
  );

  static TextStyle monoLg({Color? color}) => GoogleFonts.jetBrainsMono(
    fontSize: 24,
    fontWeight: FontWeight.w500,
    color: color ?? AppColors.foreground,
    height: 1.15,
  );

  static TextStyle monoMd({Color? color}) => GoogleFonts.jetBrainsMono(
    fontSize: 14,
    fontWeight: FontWeight.w500,
    color: color ?? AppColors.foreground,
    height: 1.2,
  );

  static TextStyle monoXs({Color? color}) => GoogleFonts.jetBrainsMono(
    fontSize: 11,
    fontWeight: FontWeight.w500,
    color: color ?? AppColors.mutedFg,
    height: 1.2,
  );
}

ThemeData darkTheme() {
  final scheme = const ColorScheme(
    brightness: Brightness.dark,
    primary: AppColors.primary,
    onPrimary: AppColors.onPrimary,
    secondary: AppColors.secondary,
    onSecondary: AppColors.foreground,
    error: AppColors.red,
    onError: Colors.white,
    surface: AppColors.background,
    onSurface: AppColors.foreground,
    surfaceContainerHighest: AppColors.card,
    outline: AppColors.border,
  );

  final base = GoogleFonts.interTextTheme(
    ThemeData.dark().textTheme,
  ).apply(bodyColor: AppColors.foreground, displayColor: AppColors.foreground);

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.background,
    canvasColor: AppColors.background,
    cardColor: AppColors.card,
    dividerColor: AppColors.border,
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.background,
      foregroundColor: AppColors.foreground,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: AppText.titleLg(),
    ),
    cardTheme: CardThemeData(
      color: AppColors.card,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadiusM),
      ),
      margin: EdgeInsets.zero,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.onPrimary,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadiusM),
        ),
        textStyle: AppText.titleMd(color: AppColors.onPrimary),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.foreground,
        side: const BorderSide(color: AppColors.border),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadiusM),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: AppColors.primary),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.secondary,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kRadiusS),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kRadiusS),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kRadiusS),
        borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
      ),
      hintStyle: AppText.bodyMd(color: AppColors.mutedFg),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: AppColors.secondary,
      selectedColor: AppColors.primary,
      labelStyle: AppText.bodyMd(),
      secondaryLabelStyle: AppText.bodyMd(color: AppColors.onPrimary),
      side: BorderSide.none,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadiusPill),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: AppColors.mutedFg,
      textColor: AppColors.foreground,
    ),
    dividerTheme: const DividerThemeData(
      color: AppColors.border,
      thickness: 1,
      space: 1,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.sheet,
      contentTextStyle: AppText.bodyMd(),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadiusS),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.sheet,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: AppColors.sheet,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(kRadiusM)),
      ),
      showDragHandle: true,
    ),
    textTheme: base,
    extensions: const [
      AppPalette(
        muted: AppColors.mutedFg,
        border: AppColors.border,
        secondary: AppColors.secondary,
        accent: AppColors.accent,
        sheet: AppColors.sheet,
        overlay: AppColors.overlay,
        green: AppColors.green,
        greenBg: AppColors.greenBg,
        amber: AppColors.amber,
        amberBg: AppColors.amberBg,
        red: AppColors.red,
        redBg: AppColors.redBg,
      ),
    ],
  );
}

class AppPalette extends ThemeExtension<AppPalette> {
  final Color muted;
  final Color border;
  final Color secondary;
  final Color accent;
  final Color sheet;
  final Color overlay;
  final Color green;
  final Color greenBg;
  final Color amber;
  final Color amberBg;
  final Color red;
  final Color redBg;

  const AppPalette({
    required this.muted,
    required this.border,
    required this.secondary,
    required this.accent,
    required this.sheet,
    required this.overlay,
    required this.green,
    required this.greenBg,
    required this.amber,
    required this.amberBg,
    required this.red,
    required this.redBg,
  });

  static AppPalette of(BuildContext context) =>
      Theme.of(context).extension<AppPalette>()!;

  @override
  AppPalette copyWith({
    Color? muted,
    Color? border,
    Color? secondary,
    Color? accent,
    Color? sheet,
    Color? overlay,
    Color? green,
    Color? greenBg,
    Color? amber,
    Color? amberBg,
    Color? red,
    Color? redBg,
  }) => AppPalette(
    muted: muted ?? this.muted,
    border: border ?? this.border,
    secondary: secondary ?? this.secondary,
    accent: accent ?? this.accent,
    sheet: sheet ?? this.sheet,
    overlay: overlay ?? this.overlay,
    green: green ?? this.green,
    greenBg: greenBg ?? this.greenBg,
    amber: amber ?? this.amber,
    amberBg: amberBg ?? this.amberBg,
    red: red ?? this.red,
    redBg: redBg ?? this.redBg,
  );

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    return AppPalette(
      muted: Color.lerp(muted, other.muted, t)!,
      border: Color.lerp(border, other.border, t)!,
      secondary: Color.lerp(secondary, other.secondary, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      sheet: Color.lerp(sheet, other.sheet, t)!,
      overlay: Color.lerp(overlay, other.overlay, t)!,
      green: Color.lerp(green, other.green, t)!,
      greenBg: Color.lerp(greenBg, other.greenBg, t)!,
      amber: Color.lerp(amber, other.amber, t)!,
      amberBg: Color.lerp(amberBg, other.amberBg, t)!,
      red: Color.lerp(red, other.red, t)!,
      redBg: Color.lerp(redBg, other.redBg, t)!,
    );
  }
}
