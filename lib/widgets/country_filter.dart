import 'package:material_ui/material_ui.dart';

import '../api/settings_repository.dart';
import '../theme/app_theme.dart';

/// Display name for a catalog country, or [catalogCountryAll].
String catalogCountryLabel(String value) => switch (value) {
  'US' => 'United States',
  'CA' => 'Canada',
  catalogCountryAll => 'All',
  _ => value,
};

/// The All / United States / Canada switch on the Add-a-Card screens. Lives on
/// the screen rather than in Profile: it only ever narrowed this one list, and
/// starts on All each time so nothing is silently hidden. Wireframe `MjX5z`.
class CountryFilter extends StatelessWidget {
  const CountryFilter({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => Container(
    height: 40,
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      color: AppColors.secondary,
      borderRadius: BorderRadius.circular(kRadiusS),
    ),
    child: Row(
      children: [
        for (final (i, option) in [
          catalogCountryAll,
          ...catalogCountries,
        ].indexed) ...[
          if (i > 0) const SizedBox(width: 3),
          Expanded(child: _segment(option)),
        ],
      ],
    ),
  );

  Widget _segment(String option) {
    final selected = option == value;
    return GestureDetector(
      onTap: () => onChanged(option),
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary.withValues(alpha: 0.15)
              : Colors.transparent,
          border: Border.all(
            color: selected ? AppColors.primary : Colors.transparent,
          ),
          borderRadius: BorderRadius.circular(kRadiusXs),
        ),
        child: Text(
          catalogCountryLabel(option),
          style:
              AppText.bodyMd(
                color: selected ? AppColors.primary : AppColors.mutedFg,
              ).copyWith(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
        ),
      ),
    );
  }
}
