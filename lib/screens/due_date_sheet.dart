import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/card.dart';
import '../providers/auth_provider.dart';
import '../providers/data_providers.dart';
import '../providers/payment_reminder_provider.dart';
import '../theme/app_theme.dart';

/// Wireframe `M5ray` / `CuqEE` — set or clear a card's payment due day.
///
/// Reachable from **any** card, bank-linked or manual: FDX gives us no due
/// date, so a user-entered day is the only source. Before this, `due_day` was
/// collected only during manual-card creation, which left every synced card
/// with no way to get one.
Future<bool> showDueDateSheet(
  BuildContext context,
  WidgetRef ref,
  CardSummary card,
) async {
  final palette = AppPalette.of(context);
  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: palette.sheet,
    builder: (_) => _DueDateSheet(card: card),
  );
  if (saved == true) {
    ref.invalidate(cardsProvider);
    // Re-arm the schedule: the due day is the input the reminders derive from,
    // so a change here must not wait for the next app open to take effect.
    await ref.read(paymentReminderControllerProvider).reschedule();
  }
  return saved == true;
}

class _DueDateSheet extends ConsumerStatefulWidget {
  const _DueDateSheet({required this.card});
  final CardSummary card;

  @override
  ConsumerState<_DueDateSheet> createState() => _DueDateSheetState();
}

class _DueDateSheetState extends ConsumerState<_DueDateSheet> {
  late int? _selected = widget.card.dueDay;
  // Null means "inherit the Settings default"; the user only pins a per-card
  // value by touching these controls.
  late bool? _remind = widget.card.reminderEnabled;
  late int? _leadDays = widget.card.reminderLeadDays;
  bool _saving = false;

  /// Whether reminders are on for this card. Null means "inherit the global
  /// Settings toggle", which defaults on.
  ///
  /// Deliberately NOT gated on having a due date. Turning it on first is a
  /// perfectly normal order to work in, and the scheduler already skips any card
  /// with no due day — so an enabled reminder on a dateless card simply waits
  /// rather than misfiring. Disabling the control as well just made it look
  /// broken.
  bool get _remindOn => _remind ?? true;

  bool get _dirty =>
      _selected != widget.card.dueDay ||
      _remind != widget.card.reminderEnabled ||
      _leadDays != widget.card.reminderLeadDays;

  Future<void> _save() async {
    final userId = ref.read(authProvider).userId;
    if (userId == null) return;
    setState(() => _saving = true);
    try {
      final repo = ref.read(dataRepositoryProvider);
      await repo.setDueDay(userId, widget.card.cardId, _selected);
      // Saved regardless of whether a due day exists yet — the preference is
      // the user's, and it simply waits for a date to act on.
      await repo.setReminderPrefs(
        userId,
        widget.card.cardId,
        enabled: _remind,
        leadDays: _leadDays,
      );
      if (mounted) Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    // Reflect the Settings default so an un-pinned card shows the value it will
    // actually use, rather than nothing selected.
    final defaultLead = ref.watch(paymentReminderLeadDaysProvider).value ?? 3;
    final name = widget.card.customName ?? widget.card.name;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Payment due date', style: AppText.titleLg()),
          const SizedBox(height: 4),
          Text(
            '$name — used for reminders',
            style: AppText.bodySm(color: palette.muted),
          ),
          const SizedBox(height: 16),
          Text('Day of month', style: AppText.labelSm()),
          const SizedBox(height: 8),
          // A 7-column grid, as in the wireframe — reads as a month without a
          // date picker's false implication of a *specific* month (the
          // statement cycle repeats).
          for (var row = 0; row < 5; row++) ...[
            if (row > 0) const SizedBox(height: 6),
            Row(
              children: [
                for (var col = 0; col < 7; col++) ...[
                  if (col > 0) const SizedBox(width: 6),
                  Expanded(
                    child: (row * 7 + col + 1) <= 31
                        ? _DayChip(
                            day: row * 7 + col + 1,
                            selected: _selected == row * 7 + col + 1,
                            onTap: () => setState(() {
                              final d = row * 7 + col + 1;
                              _selected = _selected == d ? null : d;
                            }),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ],
            ),
          ],
          const SizedBox(height: 12),
          Text(
            _selected == null
                ? 'No day set — this card won’t get payment reminders.'
                : 'Statement cycles repeat monthly, so one day is enough. '
                      'Short months fall back to the last day.',
            style: AppText.bodySm(color: palette.muted),
          ),
          const SizedBox(height: 16),
          // Wireframe M5ray / CuqEE: the reminder toggle and "how far ahead"
          // live on the CARD, with Settings supplying the default. Both stay
          // null unless touched, so a card keeps inheriting until pinned.
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _remindOn,
            activeThumbColor: AppColors.primary,
            onChanged: (v) => setState(() => _remind = v),
            title: Text(
              'Remind me before it\u2019s due',
              style: AppText.bodyMd(),
            ),
            // Explain, don't block: the reminder is saved either way and starts
            // firing as soon as the card has a due date.
            subtitle: (_remindOn && _selected == null)
                ? Text(
                    'Add a due day above and reminders will start.',
                    style: AppText.bodySm(color: AppColors.primary),
                  )
                : null,
          ),
          if (_remindOn) ...[
            const SizedBox(height: 4),
            Text('How far ahead', style: AppText.labelSm(color: palette.muted)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final d in const [1, 3, 5, 7])
                  ChoiceChip(
                    label: Text(switch (d) {
                      1 => '1 day',
                      7 => '1 week',
                      _ => '$d days',
                    }),
                    selected: (_leadDays ?? defaultLead) == d,
                    labelStyle: AppText.bodySm(
                      color: (_leadDays ?? defaultLead) == d
                          ? AppColors.onPrimary
                          : null,
                    ),
                    onSelected: (_) => setState(() => _leadDays = d),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 20),
          FilledButton(
            // Colour comes from the FilledButton theme (AppColors.primary);
            // only the wireframe's full-width height is set here.
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            onPressed: (_saving || !_dirty) ? null : _save,
            child: Text(_saving ? 'Saving…' : 'Save due date'),
          ),
          if (widget.card.dueDay != null && _selected != null) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: _saving
                  ? null
                  : () => setState(() => _selected = null),
              child: const Text('Remove due date'),
            ),
          ],
        ],
      ),
    );
  }
}

class _DayChip extends StatelessWidget {
  const _DayChip({
    required this.day,
    required this.selected,
    required this.onTap,
  });
  final int day;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(kRadiusS),
      child: Container(
        height: 38,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : palette.secondary,
          borderRadius: BorderRadius.circular(kRadiusS),
        ),
        child: Text(
          '$day',
          style: AppText.bodyMd(color: selected ? AppColors.onPrimary : null),
        ),
      ),
    );
  }
}
