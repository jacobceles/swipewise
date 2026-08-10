import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../sync/bank_connection_flow.dart';
import '../theme/app_theme.dart';

/// Rich "connecting…" view shown while the Sophtron v2 flow is in any of
/// its non-interactive busy states (SubmittingCredentials, Polling,
/// SubmittingChallenge). Modeled on `FirstSyncBody` - synthesized step
/// checklist + rotating tip carousel - because Polling can hang for tens
/// of seconds and a single spinner makes users think the app is stuck.
///
/// Steps are derived from the connection state; Sophtron doesn't expose
/// any finer-grained sub-progress during Polling, so step 2 sits active
/// for the bulk of the wait. The tip carousel keeps the screen visibly
/// alive.
class BankConnectBody extends StatefulWidget {
  const BankConnectBody({
    super.key,
    required this.state,
    required this.bankName,
  });

  final SophtronV2ConnectionState state;
  final String bankName;

  @override
  State<BankConnectBody> createState() => _BankConnectBodyState();
}

class _BankConnectBodyState extends State<BankConnectBody> {
  static const _tips = <String>[
    'Your password is sent directly to the aggregator and is never '
        'stored on this device',
    "Some banks take 30+ seconds to respond - feel free to minimize, "
        "we'll notify you when it's ready",
    'We only read your transactions - Swipewise can never move money',
    'You can disconnect any bank anytime from the Cards screen',
    'After the first sync we recommend the best card for every purchase',
  ];

  late final Timer _tipTimer;
  late final PageController _pageController;
  int _tipIndex = 0;

  // Fake-infinite carousel: start at a large multiple of the tip count
  // and always animate forward by one page. Mapping the absolute page
  // back through `% _tips.length` keeps the visible tip + dot indicator
  // correct. Going forward forever avoids the old "backwards sweep
  // across 4 pages in 450ms" jolt that happened when `animateToPage(0)`
  // was called from page 4.
  static const _carouselOrigin = 10000;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _carouselOrigin);
    // 9s interval: long enough to actually read a tip, short enough that
    // the screen still feels alive during a slow Sophtron Polling stretch.
    _tipTimer = Timer.periodic(const Duration(seconds: 9), (_) {
      if (!mounted || !_pageController.hasClients) return;
      final current = _pageController.page?.round() ?? _carouselOrigin;
      _pageController.animateToPage(
        current + 1,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeInOut,
      );
    });
  }

  @override
  void dispose() {
    _tipTimer.cancel();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final steps = _stepsFor(widget.state);
    final done = steps.where((s) => s.state == _StepState.done).length;
    final progress = (done + 0.5) / steps.length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Connecting to ${widget.bankName}…',
                  style: AppText.titleMd().copyWith(
                    fontWeight: FontWeight.w700,
                    fontSize: 18,
                  ),
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 6,
                    backgroundColor: palette.secondary,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      AppColors.primary,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                for (final step in steps)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: _StepRow(step: step, palette: palette),
                  ),
                const SizedBox(height: 24),
                _TipCard(
                  tips: _tips,
                  controller: _pageController,
                  activeIndex: _tipIndex,
                  onPageChanged: (i) =>
                      setState(() => _tipIndex = i % _tips.length),
                  palette: palette,
                ),
              ],
            ),
          ),
          Text(
            "Some banks are slower than others - feel free to minimize, "
            "we'll notify you when it's ready.",
            style: AppText.bodySm(color: palette.muted),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  List<_Step> _stepsFor(SophtronV2ConnectionState s) {
    // Map the 3 non-interactive busy states to a 2-step checklist. Step 1
    // ticks done as soon as we move past SubmittingCredentials; step 2
    // stays active for Polling + SubmittingChallenge (the long bit).
    final submittingCreds = s is SubmittingCredentialsState;
    return [
      _Step(
        label: 'Submitting credentials securely',
        state: submittingCreds ? _StepState.active : _StepState.done,
      ),
      _Step(
        label: s is SubmittingChallengeState
            ? 'Verifying your response'
            : 'Talking to your bank',
        state: submittingCreds ? _StepState.pending : _StepState.active,
      ),
    ];
  }
}

enum _StepState { pending, active, done }

class _Step {
  const _Step({required this.label, required this.state});
  final String label;
  final _StepState state;
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.step, required this.palette});
  final _Step step;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final Widget leading;
    final Color textColor;
    switch (step.state) {
      case _StepState.done:
        leading = Icon(LucideIcons.circleCheck, size: 18, color: palette.green);
        textColor = AppColors.foreground;
      case _StepState.active:
        leading = const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
        textColor = AppColors.foreground;
      case _StepState.pending:
        leading = Icon(LucideIcons.circle, size: 18, color: palette.muted);
        textColor = palette.muted;
    }
    return Row(
      children: [
        leading,
        const SizedBox(width: 10),
        Expanded(
          child: Text(step.label, style: AppText.bodyMd(color: textColor)),
        ),
      ],
    );
  }
}

class _TipCard extends StatelessWidget {
  const _TipCard({
    required this.tips,
    required this.controller,
    required this.activeIndex,
    required this.onPageChanged,
    required this.palette,
  });
  final List<String> tips;
  final PageController controller;
  final int activeIndex;
  final ValueChanged<int> onPageChanged;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(kRadiusM),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'TIP',
            style: AppText.labelSm(
              color: AppColors.primary,
            ).copyWith(fontWeight: FontWeight.w700, letterSpacing: 0.5),
          ),
          const SizedBox(height: 8),
          // Fixed height so PageView has bounded vertical space. Sized to
          // fit ~3 lines of bodyMd - the longest tips wrap to 2 lines on
          // typical phone widths, with some padding.
          SizedBox(
            height: 64,
            child: PageView.builder(
              controller: controller,
              // No itemCount → the PageView can scroll indefinitely in
              // either direction. Combined with the controller's large
              // `initialPage` and the modulo in `itemBuilder`, this gives
              // a true loop where last→first is just one more forward
              // page, not an animated rewind.
              onPageChanged: onPageChanged,
              itemBuilder: (_, i) =>
                  Text(tips[i % tips.length], style: AppText.bodyMd()),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < tips.length; i++) ...[
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: i == activeIndex ? AppColors.primary : palette.muted,
                    shape: BoxShape.circle,
                  ),
                ),
                if (i < tips.length - 1) const SizedBox(width: 6),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
