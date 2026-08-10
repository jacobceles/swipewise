// SECURITY-SENSITIVE - this file collects bank login credentials. Review
// carefully on any change. Never add Log.* calls that include `username`
// or `password` strings. Never persist credentials anywhere.

import 'dart:async';
import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api/data_repository.dart';
import '../api/sophtron_auth_service.dart';
import '../api/bank_client.dart';
import '../providers/auth_provider.dart';
import '../providers/data_providers.dart';
import '../providers/popular_banks_cache_provider.dart';
import '../providers/bank_sync_provider.dart';
import '../sync/bank_connection_flow.dart';
import '../theme/app_theme.dart';
import '../util/link_progress_notifier.dart';
import '../util/logger.dart';
import '../util/popular_banks.dart';
import '../widgets/bank_connect_body.dart';
import '../widgets/connect_bank_app_bar.dart';
import 'manual_card_flow_screen.dart';

/// Wireframe `fLfdQ` / `i6slX5` - 10 mutually exclusive sub-views driven
/// by the Sophtron v2 state machine. Restyled only; the flow itself is
/// untouched.
class AddBankV2Screen extends ConsumerStatefulWidget {
  const AddBankV2Screen({
    super.key,
    this.mode,
    this.institutionId,
    this.institutionName,
    this.institutionLogo,
    this.wasBroken = false,
  });

  /// When `'reconnect'`, the screen skips the Institution Picker and
  /// renders the Credentials Form directly for the pre-selected bank.
  /// On success it also deletes the old (broken) MemberID at Sophtron.
  /// `null` = normal "add a new bank" flow.
  final String? mode;

  /// Pre-selected institution for reconnect mode. Required when
  /// `mode == 'reconnect'`; the screen skips the picker.
  final String? institutionId;
  final String? institutionName;
  final String? institutionLogo;

  /// True only when the user entered the reconnect flow from a
  /// connection that's actually flagged `last_sync_status='failed'`.
  /// Gates the amber "your connection has expired" copy in the
  /// credentials form - we shouldn't show that copy when the user is
  /// re-linking a healthy bank from the bank info sheet.
  final bool wasBroken;

  bool get isReconnect => mode == 'reconnect' && institutionId != null;

  @override
  ConsumerState<AddBankV2Screen> createState() => _AddBankV2ScreenState();
}

class _AddBankV2ScreenState extends ConsumerState<AddBankV2Screen> {
  BankClient? _client;
  BankConnectionFlow? _flow;
  StreamSubscription<SophtronV2ConnectionState>? _stateSub;
  String? _customerId;
  String? _error;
  SophtronV2ConnectionState _state = const SophtronV2ConnectionState.idle();
  Map<String, dynamic>? _picked;
  bool _showConnectionMethod = false;

  /// Sophtron returns the institution with inconsistent key casing depending
  /// on the endpoint, so read both spellings.
  String get _pickedName =>
      (_picked?['InstitutionName'] ?? _picked?['institutionName'])
          ?.toString() ??
      'your bank';

  String? get _pickedLogo =>
      (_picked?['Logo'] ?? _picked?['logo'])?.toString().trim();

  /// MemberID of the old (broken) link, captured at screen-init time
  /// when in reconnect mode. Deleted at Sophtron on successful relink so
  /// we don't accumulate dead Members under the Customer.
  String? _oldMemberId;

  /// True between posting an MFA challenge answer and the flow emitting the
  /// next state. Blocks a double-tap from posting the same answer twice —
  /// Sophtron counts each post as an attempt, and repeats trip issuer lockouts.
  /// Re-armed whenever a fresh [ChallengeState] arrives.
  bool _challengeSubmitInFlight = false;

  /// Flips true once the user confirms the cancel dialog. Bypasses the
  /// `PopScope` guard for the resulting `context.pop()` so the dialog's
  /// "Cancel link" button actually closes the screen instead of looping
  /// back to itself.
  bool _confirmedCancel = false;

  /// Set in `_onSuccess` right before we fire `runSync`. Tells `dispose`
  /// to leave the link-progress notification (and its backing
  /// foreground service) running — the sync provider has taken
  /// ownership and will dismiss after the post-link sync completes.
  /// On the failure / cancel / back paths this stays false and
  /// `dispose` dismisses normally.
  bool _handedOffToSync = false;

  /// True while the user is mid-MFA — credentials submitted, polling, a
  /// challenge sheet on screen, or answering one. Backing out in any of
  /// these states would leave an orphan MemberID at Sophtron (cleaned
  /// up best-effort on next sync via the orphan-Member pass) and lose
  /// the user's MFA progress, so we gate the pop on an explicit confirm.
  bool get _isMfaInFlight {
    final s = _state;
    return s is SubmittingCredentialsState ||
        s is PollingState ||
        s is ChallengeState ||
        s is SubmittingChallengeState;
  }

  @override
  void initState() {
    super.initState();
    if (widget.isReconnect) {
      // Pre-populate the picker selection from the route params so we
      // skip straight to the credentials form. Shape matches what the
      // picker would have produced (InstitutionID + InstitutionName + Logo).
      _picked = {
        'InstitutionID': widget.institutionId,
        if (widget.institutionName != null)
          'InstitutionName': widget.institutionName,
        if (widget.institutionLogo != null) 'Logo': widget.institutionLogo,
      };
    }
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      if (!SophtronConfig.isConfigured) {
        throw MissingSophtronCreds();
      }
      final client = BankClient();
      final flow = BankConnectionFlow(client: client);
      _stateSub = flow.state.listen((s) {
        if (!mounted) return;
        // A fresh challenge means the previous submission was consumed — re-arm
        // the submit guard so the user can answer the next step.
        if (s is ChallengeState) _challengeSubmitInFlight = false;
        setState(() => _state = s);
        // Mirror the flow state into the link-progress notification so
        // the user can minimize the app and still know what's needed
        // next (or that the link finished). See `_fireLinkNotification`
        // for the alert vs silent-update split.
        _fireLinkNotification(s);
        if (s is SuccessState) _onSuccess(s);
        if (s is FailedState) setState(() => _error = s.message);
      });
      _client = client;
      _flow = flow;

      // Reconnect mode: capture the old MemberID for this institution
      // BEFORE the new link mints a fresh MemberID. We delete the old
      // dead Member at Sophtron on success so it doesn't sit there
      // forever consuming a connection slot.
      if (widget.isReconnect) {
        final userId = ref.read(authProvider).userId;
        if (userId != null) {
          final existing = await DataRepository().queryBankConnections(userId);
          for (final row in existing) {
            if (row.institutionId == widget.institutionId) {
              _oldMemberId = row.userInstitutionId;
              break;
            }
          }
        }
      }

      // Per-user Sophtron Customer uniqueId — derived from the user's
      // onboarding email so a reinstall (same email) retrieves the
      // existing Customer with all its Members. `SophtronConfig.userId`
      // here would be the legacy single-tenant path where every install
      // collapsed to one Customer.
      final uniqueId = ref.read(authProvider).bankCustomerId;
      if (uniqueId == null) {
        throw StateError(
          'Customer uniqueId missing on AuthState — onboarding should '
          'have set this. Sign out and sign back in.',
        );
      }
      final cid = await flow.ensureCustomer(uniqueId);
      if (!mounted) return;
      setState(() {
        _customerId = cid;
        _state = const SophtronV2ConnectionState.idle();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  Future<void> _onSuccess(SuccessState s) async {
    Log.i('add-bank-v2', 'success: member=${s.memberId} cust=${s.customerId}');
    // Capture the messenger up front - everything below this point is
    // async, and once we pop this screen the widget's context is
    // unmounted and `ScaffoldMessenger.of` becomes a no-op. Without the
    // snackbar, reconnect looks like the credentials screen vanishes for
    // no reason: the user already has cards so `FirstSyncBody` doesn't
    // render, and the sync runs invisibly.
    final messenger = ScaffoldMessenger.of(context);
    // Capture the container too - `ref` belongs to this widget and the
    // `context.pop()` below unmounts it, so the unawaited `runSync()`
    // call at the bottom would throw "Bad state: Using ref when a
    // widget is about to or has been unmounted is unsafe". Container
    // lives on the ProviderScope and survives the pop.
    final container = ProviderScope.containerOf(context, listen: false);
    final bankName = widget.institutionName ?? 'your bank';
    // Persist link-time institution metadata (name + logo from the v2
    // search result the user picked) into bank_connections BEFORE
    // triggering sync. The sync engine snapshots existing connections
    // and falls back to these values if the per-sync v1 institution
    // lookup fails - avoiding phantom "Manual" cards on transient blips.
    final userId = ref.read(authProvider).userId;
    final picked = _picked;
    if (userId != null && picked != null) {
      final iid = picked['InstitutionID']?.toString();
      final iname = (picked['InstitutionName'] ?? picked['institutionName'])
          ?.toString();
      final ilogo = (picked['Logo'] ?? picked['logo'])?.toString().trim();
      if (iid != null && iid.isNotEmpty) {
        try {
          await DataRepository().upsertConnection(
            userId: userId,
            userInstitutionId: s.memberId,
            memberId: s.memberId,
            institutionId: iid,
            institutionName: iname,
            institutionLogo: ilogo,
          );
        } catch (e, st) {
          Log.e('add-bank-v2', 'link-time connection upsert failed', e, st);
        }
      }
    }
    // Reconnect mode: clean up the dead Member both at Sophtron and locally.
    // The new link minted a fresh MemberID — i.e. a NEW bank_connections row
    // — so the upsert above did NOT replace the old row. Left behind, the old
    // MemberID keeps getting fanned out on every sync (the sync's drop pass is
    // suppressed inside the post-mutation window) and shows up as a duplicate
    // stuck on its last error. Delete it on both sides. Both best-effort.
    final oldMemberId = _oldMemberId;
    if (widget.isReconnect &&
        oldMemberId != null &&
        oldMemberId != s.memberId) {
      // Serialize this wipe against sync: a concurrent background tick
      // rebuilding the same institution could otherwise interleave with the
      // delete below and lose rows it just wrote. Take the same per-user sync
      // mutex the engine uses. Best-effort like the deletes: if a live sync
      // already owns the lock we skip the wipe (its own drop pass reconciles
      // the dead member next cycle) rather than race it. The lock is keyed by
      // user, so acquire only when we have a userId — with none there is no
      // local row to protect, only the remote Member delete.
      final lockToken = userId == null
          ? null
          : await DataRepository().acquireSyncLock(userId, holder: 'reconnect');
      if (userId != null && lockToken == null) {
        Log.i(
          'add-bank-v2',
          'reconnect: live sync holds lock, skipping wipe for $oldMemberId',
        );
      } else {
        try {
          try {
            await BankClient().deleteMember(
              customerId: s.customerId,
              memberId: oldMemberId,
            );
            Log.i('add-bank-v2', 'reconnect: deleted old member $oldMemberId');
          } catch (e, st) {
            Log.e(
              'add-bank-v2',
              'reconnect: deleteMember(old=$oldMemberId) failed (non-fatal)',
              e,
              st,
            );
          }
          if (userId != null) {
            try {
              await DataRepository().deleteMemberData(
                userId: userId,
                userInstitutionId: oldMemberId,
              );
              Log.i(
                'add-bank-v2',
                'reconnect: dropped local rows for $oldMemberId',
              );
            } catch (e, st) {
              Log.e(
                'add-bank-v2',
                'reconnect: local cleanup for $oldMemberId failed (non-fatal)',
                e,
                st,
              );
            }
          }
        } finally {
          // Release before the unawaited runSync() below (which takes the
          // lock itself); token-scoped so a steal mid-wipe is a no-op.
          if (userId != null && lockToken != null) {
            await DataRepository().releaseSyncLock(
              userId,
              acquiredAtToken: lockToken,
            );
          }
        }
      }
    }

    if (mounted) context.pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          widget.isReconnect
              ? 'Reconnected to $bankName - syncing now…'
              : 'Connected to $bankName - syncing now…',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
    // Mark this institution for post-sync reconciliation: the HomeScreen
    // sync-completion listener will scan for orphan transactions on a
    // matching `last_four` and show the attach-history sheet if found.
    final pickedInstitutionId = picked?['InstitutionID']?.toString();
    if (pickedInstitutionId != null && pickedInstitutionId.isNotEmpty) {
      container
          .read(pendingReconciliationProvider.notifier)
          .enqueue(pickedInstitutionId);
    }
    // Use the captured container, not `ref` - the widget is unmounted
    // by the pop above and `ref.read` would throw.
    //
    // `waitForMemberId` is the just-created MemberID: the engine uses
    // it to settle through Sophtron's Customer→Members eventual-
    // consistency window so this first sync sees the full Members list
    // (the just-added bank *and* any older siblings the v2 index would
    // otherwise leave out for a few seconds after createMember).
    //
    // Mark the handoff *before* `dispose` runs (the pop above schedules
    // it for the next frame) so the dispose path doesn't tear down the
    // notification + foreground service mid-sync — the sync provider
    // refreshes the notification on entry and dismisses on completion.
    _handedOffToSync = true;
    // ignore: unawaited_futures
    container
        .read(bankSyncProvider.notifier)
        .runSync(waitForMemberId: s.memberId);
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _flow?.dispose();
    // Clear the ongoing link-progress notification on screen teardown
    // for the cancel / back / failure paths — there's no follow-on
    // sync to take ownership in those cases, so dismissing here is the
    // right cleanup. On the success path the sync provider has taken
    // ownership (see `_onSuccess`); skip dismiss so we don't tear
    // down the foreground service mid-sync.
    if (!_handedOffToSync) {
      LinkProgressNotifier.dismiss();
    }
    super.dispose();
  }

  /// Pushes the current connection-flow state into the native
  /// link-progress notification so the user can minimize the app and
  /// still get pinged when an actionable transition lands.
  ///
  /// Alert split:
  /// - **silent** (no sound/vibration): `SubmittingCredentials`,
  ///   `Polling`, `SubmittingChallenge` — status churn the user
  ///   doesn't need to act on. The notification text updates so it's
  ///   visible if they glance at it; the device just doesn't ring.
  /// - **alerts**: `ChallengeState` (any sub-type) and the terminals
  ///   (`Success`, `Failed`) — these are the moments the user actually
  ///   needs to come back to the app.
  ///
  /// Pre-MFA states (`Idle`, `ResolvingCustomer`) don't post a
  /// notification at all — there's nothing for the user to know yet,
  /// and posting one would make the link feel started before
  /// credentials were submitted.
  void _fireLinkNotification(SophtronV2ConnectionState s) {
    final bankName = widget.institutionName ?? 'your bank';
    switch (s) {
      case IdleState():
      case ResolvingCustomerState():
        // Pre-MFA, before credentials submitted. No notification needed.
        return;
      case SubmittingCredentialsState():
        LinkProgressNotifier.show(
          title: 'Linking $bankName',
          body: 'Submitting your credentials…',
          alert: false,
        );
      case PollingState():
        LinkProgressNotifier.show(
          title: 'Linking $bankName',
          body: "Waiting for $bankName to respond…",
          alert: false,
        );
      case SubmittingChallengeState():
        LinkProgressNotifier.show(
          title: 'Linking $bankName',
          body: 'Submitting your answer…',
          alert: false,
        );
      case ChallengeState(:final challenge):
        final body = switch (challenge) {
          SecurityQuestionsChallenge() =>
            "$bankName is asking a security question.",
          TokenMethodChallenge() =>
            'Choose where to send your verification code.',
          TokenInputChallenge() => "Enter the code $bankName sent you.",
          TokenReadChallenge() => "Confirm the code on $bankName's app.",
          CaptchaChallenge() => 'Solve the captcha.',
        };
        LinkProgressNotifier.show(
          title: '$bankName needs your input',
          body: body,
          alert: true,
        );
      case SuccessState():
        LinkProgressNotifier.show(
          title: 'Linked $bankName',
          body: 'Syncing your accounts now.',
          alert: true,
          ongoing: false,
          indeterminate: false,
        );
      case FailedState(:final message):
        LinkProgressNotifier.show(
          title: "Couldn't link $bankName",
          body: message,
          alert: true,
          ongoing: false,
          indeterminate: false,
        );
    }
  }

  /// Single close path for both the system back gesture and the AppBar X
  /// button. Shows the cancel-confirm AlertDialog when the user is mid-MFA;
  /// passes straight through to `context.pop()` otherwise.
  Future<void> _attemptClose() async {
    if (!_isMfaInFlight) {
      context.pop();
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Cancel this link?'),
        content: const Text(
          "You're in the middle of connecting your bank. If you cancel "
          "now, you'll need to start over from scratch.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: const Text('Stay'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: const Text('Cancel link'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      _confirmedCancel = true;
      // Reap the half-created Member before leaving. Abandoning it leaks an
      // unusable Member under the Customer, and the sync engine's per-institution
      // dedupe can later mistake it for a real connection. Fire-and-forget with a
      // caught failure: the user asked to leave, so a cleanup error must not
      // block the pop or surface as a scary dialog.
      unawaited(_deleteAbandonedMember());
      context.pop();
    }
  }

  /// Best-effort `deleteMember` for a link the user cancelled mid-MFA.
  /// Mirrors the abandoned-member cleanup in `bank_sync_engine`.
  Future<void> _deleteAbandonedMember() async {
    final memberId = _flow?.inFlightMemberId;
    final customerId = _flow?.inFlightCustomerId ?? _customerId;
    if (memberId == null || customerId == null) return; // nothing created yet
    try {
      await BankClient().deleteMember(
        customerId: customerId,
        memberId: memberId,
      );
      Log.i('add-bank-v2', 'cancel: deleted abandoned member $memberId');
    } catch (e) {
      Log.w('add-bank-v2', 'cancel: deleteMember($memberId) failed', e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.isReconnect
        ? 'Reconnect to ${widget.institutionName ?? 'bank'}'
        : 'Connect Bank Account';
    return PopScope(
      // System back is blocked while MFA is in flight unless the user has
      // explicitly confirmed via the dialog below. The same predicate
      // gates the AppBar X (via `_attemptClose`), so both surfaces share
      // one warning path.
      canPop: _confirmedCancel || !_isMfaInFlight,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // ignore: discarded_futures
        _attemptClose();
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: ConnectBankAppBar(
          title: title,
          onClose: () {
            // ignore: discarded_futures
            _attemptClose();
          },
        ),
        body: SafeArea(top: false, child: _buildBody()),
      ),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return _ErrorView(
        message: _error!,
        onRetry: () {
          setState(() => _error = null);
          _bootstrap();
        },
      );
    }

    final s = _state;
    if (s is ChallengeState) {
      return _ChallengeView(
        challenge: s.challenge,
        onSubmit: (answer) {
          // Re-entry guard. All four challenge widgets (option, free-text,
          // approve, captcha) call `onSubmit` straight from `onPressed`, so a
          // double-tap lands twice before the flow emits SubmittingChallenge and
          // swaps this view out. Sophtron counts each post as a separate MFA
          // attempt, which is exactly what trips an issuer "too many attempts"
          // lockout. Guarding here covers all four at the single choke point
          // they share, rather than making each widget stateful.
          if (_challengeSubmitInFlight) return;
          _challengeSubmitInFlight = true;
          _flow?.submitChallengeResponse(s.challenge, answer);
        },
      );
    }
    if (s is SubmittingChallengeState ||
        s is PollingState ||
        s is SubmittingCredentialsState) {
      return BankConnectBody(state: s, bankName: _pickedName);
    }
    if (s is ResolvingCustomerState) {
      return const _BusyView(message: 'Setting up your account…');
    }
    if (_picked == null) {
      if (_client == null) return const _BusyView(message: 'Loading…');
      return _InstitutionPicker(
        client: _client!,
        onPick: (inst) => setState(() {
          _picked = inst;
          _showConnectionMethod = true;
        }),
      );
    }
    if (_showConnectionMethod) {
      return _ConnectionMethodView(
        institution: _picked!,
        onAutomatic: () => setState(() => _showConnectionMethod = false),
        onManual: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ManualCardFlowScreen(
              // The bank's name doubles as the catalog query: the flow
              // strips punctuation and case before matching, so "Bank of
              // America" finds the catalog's "Bankofamerica" products.
              issuerQuery: _pickedName,
              displayName: _pickedName,
              logoUrl: _pickedLogo,
              addAnotherLabel: 'Add another bank',
            ),
          ),
        ),
      );
    }
    return _CredentialsForm(
      institution: _picked!,
      // "Connection expired" copy is only honest when we actually
      // flagged the connection broken. A manual reconnect from the bank
      // info sheet still uses reconnect mode (skip the picker, replace
      // the existing MemberID) but the existing link is healthy, so we
      // suppress the amber banner there.
      reconnectBanner: widget.isReconnect && widget.wasBroken
          ? 'Your connection to ${widget.institutionName ?? 'this bank'} '
                'has expired. Re-enter your credentials to resume syncing.'
          : null,
      onSubmit: (username, password) => _flow?.startLink(
        customerId: _customerId!,
        institutionId: _picked!['InstitutionID'].toString(),
        username: username,
        password: password,
      ),
      // In reconnect mode the institution is fixed - no back navigation. A
      // normal automatic link returns to its connection-method choice.
      onBack: widget.isReconnect
          ? null
          : () => setState(() => _showConnectionMethod = true),
    );
  }
}

class _ConnectionMethodView extends StatelessWidget {
  const _ConnectionMethodView({
    required this.institution,
    required this.onAutomatic,
    required this.onManual,
  });

  final Map<String, dynamic> institution;
  final VoidCallback onAutomatic;
  final VoidCallback onManual;

  @override
  Widget build(BuildContext context) {
    final name =
        (institution['InstitutionName'] ?? institution['institutionName'])
            ?.toString() ??
        'your bank';
    final logo = (institution['Logo'] ?? institution['logo'])
        ?.toString()
        .trim();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          BankStepHeader(label: 'CONNECTING TO', bankName: name, logoUrl: logo),
          const SizedBox(height: 32),
          Text(
            'How do you want to connect?',
            textAlign: TextAlign.center,
            style: AppText.titleLg().copyWith(fontSize: 22),
          ),
          const SizedBox(height: 6),
          Text(
            'Choose how you\'d like to add your $name cards.',
            textAlign: TextAlign.center,
            style: AppText.bodyMd(color: AppColors.mutedFg),
          ),
          const SizedBox(height: 24),
          _MethodOption(
            icon: LucideIcons.link,
            title: 'Automatic',
            description:
                "Securely link your bank login. We'll import your cards and balances for you.",
            onTap: onAutomatic,
          ),
          const SizedBox(height: 12),
          _MethodOption(
            icon: LucideIcons.creditCard,
            title: 'Manual',
            description:
                'Add cards yourself. No bank login needed — enter details now or later.',
            onTap: onManual,
          ),
        ],
      ),
    );
  }
}

class _MethodOption extends StatelessWidget {
  const _MethodOption({
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(kRadiusM),
    child: Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(kRadiusM),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.secondary,
              borderRadius: BorderRadius.circular(kRadiusS),
            ),
            child: Icon(icon, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppText.titleMd()),
                const SizedBox(height: 4),
                Text(description, style: AppText.bodySm()),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _InstitutionPicker extends ConsumerStatefulWidget {
  const _InstitutionPicker({required this.client, required this.onPick});

  final BankClient client;
  final void Function(Map<String, dynamic>) onPick;

  @override
  ConsumerState<_InstitutionPicker> createState() => _InstitutionPickerState();
}

class _InstitutionPickerState extends ConsumerState<_InstitutionPicker> {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  List<dynamic> _results = const [];
  bool _loading = false;

  /// Name of the popular bank currently being picked, or null if idle.
  /// Per-bank instead of a single bool so only the tapped tile spins -
  /// the others stay visible (just disabled) while the pick is in flight.
  String? _pickingPopularName;
  String? _error;

  /// Tap handler for a Popular Banks tile. Uses the cached top hit
  /// (refreshed on app start + every successful sync) if available,
  /// otherwise falls back to a fresh search so a cold-cache install still
  /// works. We don't hardcode InstitutionIDs - Sophtron's 53K-entry
  /// catalog has multiple subtenants per issuer.
  Future<void> _pickPopular(PopularBank bank) async {
    if (_pickingPopularName != null) return;
    final cached = ref.read(popularBanksCacheProvider)[bank.displayName];
    if (cached != null) {
      widget.onPick(cached);
      return;
    }
    setState(() {
      _pickingPopularName = bank.displayName;
      _error = null;
    });
    try {
      final list = await widget.client.searchInstitutions(
        query: bank.searchQuery,
      );
      if (!mounted) return;
      final sorted = list.toList()
        ..sort((a, b) {
          final an = _nameOf(a);
          final bn = _nameOf(b);
          final byLen = an.length.compareTo(bn.length);
          return byLen != 0 ? byLen : an.compareTo(bn);
        });
      if (sorted.isEmpty) {
        setState(() {
          _pickingPopularName = null;
          _error = "Couldn't find ${bank.displayName}. Try the search.";
        });
        return;
      }
      widget.onPick(sorted.first as Map<String, dynamic>);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _pickingPopularName = null;
        _error = e.toString();
      });
    }
  }

  static String? _logoFor(Map<String, dynamic>? inst) {
    if (inst == null) return null;
    final raw = (inst['Logo'] ?? inst['logo'])?.toString().trim();
    return (raw == null || raw.isEmpty) ? null : raw;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(v));
  }

  Future<void> _search(String v) async {
    if (v.trim().isEmpty) {
      setState(() {
        _results = const [];
        _loading = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await widget.client.searchInstitutions(query: v.trim());
      if (!mounted) return;
      final sorted = list.toList()
        ..sort((a, b) {
          final an = _nameOf(a);
          final bn = _nameOf(b);
          final byLen = an.length.compareTo(bn.length);
          return byLen != 0 ? byLen : an.compareTo(bn);
        });
      setState(() {
        _results = sorted.take(10).toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  static String _nameOf(dynamic inst) {
    if (inst is! Map) return '';
    return (inst['InstitutionName'] ?? inst['institutionName'])?.toString() ??
        '';
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _ctrl,
            onChanged: _onChanged,
            autofocus: true,
            style: AppText.bodyMd(),
            decoration: InputDecoration(
              hintText: 'Search institutions…',
              prefixIcon: Icon(
                LucideIcons.search,
                size: 18,
                color: palette.muted,
              ),
            ),
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error!, style: AppText.bodySm(color: palette.red)),
            ),
          if (_results.isEmpty && _ctrl.text.trim().isNotEmpty && !_loading)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'No banks match',
                style: AppText.bodySm(color: palette.muted),
              ),
            ),
          if (_ctrl.text.trim().isEmpty && !_loading && _error == null)
            Expanded(
              child: Consumer(
                builder: (context, ref, _) {
                  final cache = ref.watch(popularBanksCacheProvider);
                  return _PopularBanksGrid(
                    onPick: _pickPopular,
                    pickingName: _pickingPopularName,
                    logoFor: (bank) => _logoFor(cache[bank.displayName]),
                  );
                },
              ),
            )
          else
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.only(top: 12),
                itemCount: _results.length,
                separatorBuilder: (_, _) =>
                    Divider(height: 1, color: palette.border),
                itemBuilder: (context, i) {
                  final inst = _results[i] as Map<String, dynamic>;
                  final name =
                      (inst['InstitutionName'] ?? inst['institutionName'])
                          ?.toString() ??
                      '';
                  final logo = (inst['Logo'] ?? inst['logo'])
                      ?.toString()
                      .trim();
                  return InkWell(
                    onTap: () => widget.onPick(inst),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Row(
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            alignment: Alignment.center,
                            decoration: const BoxDecoration(
                              color: AppColors.bankLogoTile,
                              shape: BoxShape.circle,
                            ),
                            child: logo != null && logo.isNotEmpty
                                ? ClipOval(
                                    child: Padding(
                                      padding: const EdgeInsets.all(5),
                                      child: CachedNetworkImage(
                                        imageUrl: logo,
                                        width: 40,
                                        height: 40,
                                        // contain (not cover) - Sophtron's
                                        // logos have built-in whitespace;
                                        // cover crops the brand off.
                                        fit: BoxFit.contain,
                                        errorWidget: (_, _, _) => const Icon(
                                          LucideIcons.landmark,
                                          size: 18,
                                        ),
                                      ),
                                    ),
                                  )
                                : const Icon(LucideIcons.landmark, size: 18),
                          ),
                          const SizedBox(width: 12),
                          Expanded(child: Text(name, style: AppText.bodyMd())),
                          Icon(
                            LucideIcons.chevronRight,
                            size: 18,
                            color: palette.muted,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _CredentialsForm extends StatefulWidget {
  const _CredentialsForm({
    required this.institution,
    required this.onSubmit,
    required this.onBack,
    this.reconnectBanner,
  });

  final Map<String, dynamic> institution;
  final void Function(String username, String password) onSubmit;

  /// `null` in reconnect mode: there's no picker to go back to.
  final VoidCallback? onBack;

  /// Non-null in reconnect mode: amber explainer above the form so the
  /// user understands why they're re-entering credentials.
  final String? reconnectBanner;

  @override
  State<_CredentialsForm> createState() => _CredentialsFormState();
}

class _CredentialsFormState extends State<_CredentialsForm> {
  // SECURITY: controllers are disposed (which clears their internal text)
  // as soon as this widget is unmounted.
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _showPassword = false;

  @override
  void dispose() {
    _userCtrl.clear();
    _passCtrl.clear();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final u = _userCtrl.text;
    final p = _passCtrl.text;
    if (u.isEmpty || p.isEmpty) return;
    widget.onSubmit(u, p);
    _userCtrl.clear();
    _passCtrl.clear();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final name =
        (widget.institution['InstitutionName'] ??
                widget.institution['institutionName'])
            ?.toString() ??
        '';
    // SingleChildScrollView so the reconnect variant (which adds the
    // amber banner above the fields) doesn't overflow on shorter screens
    // and the form can move out of the way of the keyboard when it
    // appears.
    return AutofillGroup(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (widget.onBack != null) ...[
                  GestureDetector(
                    onTap: widget.onBack,
                    child: const Icon(LucideIcons.chevronLeft, size: 22),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Text(
                    name,
                    style: AppText.titleMd(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (widget.reconnectBanner != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: palette.amberBg,
                  borderRadius: BorderRadius.circular(kRadiusS),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      LucideIcons.triangleAlert,
                      size: 18,
                      color: palette.amber,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        widget.reconnectBanner!,
                        style: AppText.bodySm(color: palette.amber),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 20),
            Text('Username', style: AppText.bodyMd()),
            const SizedBox(height: 8),
            TextField(
              controller: _userCtrl,
              autocorrect: false,
              autofillHints: const [AutofillHints.username],
              textInputAction: TextInputAction.next,
              style: AppText.bodyMd(),
            ),
            const SizedBox(height: 16),
            Text('Password', style: AppText.bodyMd()),
            const SizedBox(height: 8),
            TextField(
              controller: _passCtrl,
              decoration: InputDecoration(
                suffixIcon: IconButton(
                  icon: Icon(
                    _showPassword ? LucideIcons.eyeOff : LucideIcons.eye,
                    size: 18,
                    color: palette.muted,
                  ),
                  onPressed: () =>
                      setState(() => _showPassword = !_showPassword),
                ),
              ),
              obscureText: !_showPassword,
              autocorrect: false,
              autofillHints: const [AutofillHints.password],
              keyboardType: TextInputType.visiblePassword,
              onEditingComplete: () => TextInput.finishAutofillContext(),
              style: AppText.bodyMd(),
            ),
            const SizedBox(height: 20),
            SizedBox(
              height: 52,
              child: ElevatedButton(
                onPressed: _submit,
                child: const Text('Connect'),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Your credentials are sent directly to the aggregator and are '
              'never stored on this device.',
              textAlign: TextAlign.center,
              style: AppText.bodySm().copyWith(fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChallengeView extends StatelessWidget {
  const _ChallengeView({required this.challenge, required this.onSubmit});

  final SophtronV2Challenge challenge;
  final void Function(Object answer) onSubmit;

  @override
  Widget build(BuildContext context) {
    return switch (challenge) {
      SecurityQuestionsChallenge() => _SecurityQuestions(
        challenge: challenge as SecurityQuestionsChallenge,
        onSubmit: onSubmit,
      ),
      TokenMethodChallenge() => _TokenMethod(
        challenge: challenge as TokenMethodChallenge,
        onSubmit: onSubmit,
      ),
      TokenInputChallenge() => _TokenInput(
        challenge: challenge as TokenInputChallenge,
        onSubmit: onSubmit,
      ),
      TokenReadChallenge() => _TokenRead(
        challenge: challenge as TokenReadChallenge,
        onSubmit: onSubmit,
      ),
      CaptchaChallenge() => _CaptchaView(
        challenge: challenge as CaptchaChallenge,
        onSubmit: onSubmit,
      ),
    };
  }
}

class _SecurityQuestions extends StatefulWidget {
  const _SecurityQuestions({required this.challenge, required this.onSubmit});

  final SecurityQuestionsChallenge challenge;
  final void Function(Object) onSubmit;

  @override
  State<_SecurityQuestions> createState() => _SecurityQuestionsState();
}

class _SecurityQuestionsState extends State<_SecurityQuestions> {
  late final List<TextEditingController> _ctrls;

  @override
  void initState() {
    super.initState();
    _ctrls = widget.challenge.questions
        .map((_) => TextEditingController())
        .toList();
  }

  @override
  void dispose() {
    for (final c in _ctrls) {
      c.clear();
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: ListView(
        children: [
          Text('Security questions', style: AppText.titleLg()),
          const SizedBox(height: 16),
          for (var i = 0; i < widget.challenge.questions.length; i++) ...[
            Text(widget.challenge.questions[i], style: AppText.bodyMd()),
            const SizedBox(height: 8),
            TextField(
              controller: _ctrls[i],
              autocorrect: false,
              enableSuggestions: false,
              autofillHints: const [],
              style: AppText.bodyMd(),
            ),
            const SizedBox(height: 16),
          ],
          SizedBox(
            height: 52,
            child: ElevatedButton(
              onPressed: () =>
                  widget.onSubmit(_ctrls.map((c) => c.text).toList()),
              child: const Text('Submit'),
            ),
          ),
        ],
      ),
    );
  }
}

class _TokenMethod extends StatelessWidget {
  const _TokenMethod({required this.challenge, required this.onSubmit});

  final TokenMethodChallenge challenge;
  final void Function(Object) onSubmit;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('How should we send your code?', style: AppText.titleLg()),
          const SizedBox(height: 16),
          for (final opt in challenge.options)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: OutlinedButton(
                onPressed: () => onSubmit(opt),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    vertical: 16,
                    horizontal: 16,
                  ),
                  alignment: Alignment.centerLeft,
                ),
                // SizedBox(width: infinity) lets the Text claim the full
                // button width so long Sophtron option strings wrap to
                // multiple lines instead of clipping at the edge.
                child: SizedBox(
                  width: double.infinity,
                  child: Text(opt, style: AppText.bodyMd()),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TokenInput extends StatefulWidget {
  const _TokenInput({required this.challenge, required this.onSubmit});

  final TokenInputChallenge challenge;
  final void Function(Object) onSubmit;

  @override
  State<_TokenInput> createState() => _TokenInputState();
}

class _TokenInputState extends State<_TokenInput> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.clear();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Enter the ${widget.challenge.fieldName}',
            style: AppText.titleLg(),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _ctrl,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            autofillHints: const [],
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: AppText.monoMd().copyWith(fontSize: 24, letterSpacing: 4),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          SizedBox(
            height: 52,
            child: ElevatedButton(
              onPressed: () => widget.onSubmit(_ctrl.text),
              child: const Text('Submit'),
            ),
          ),
        ],
      ),
    );
  }
}

class _TokenRead extends StatelessWidget {
  const _TokenRead({required this.challenge, required this.onSubmit});

  final TokenReadChallenge challenge;
  final void Function(Object) onSubmit;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    // Sophtron overloads the `token` field: sometimes it's a short code
    // for the user to read off ("482931"), other times it's a sentence-
    // long instruction ("Open the bank app on your phone & tap to
    // approve"). Pick the visual treatment based on length - the giant
    // mono spacing only makes sense for short codes.
    final isShortCode = challenge.token.length <= 12;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Approve on your device', style: AppText.titleLg()),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: palette.secondary,
              borderRadius: BorderRadius.circular(kRadiusM),
            ),
            child: Center(
              child: Text(
                challenge.token,
                textAlign: TextAlign.center,
                style: isShortCode
                    ? AppText.monoLg().copyWith(fontSize: 32, letterSpacing: 6)
                    : AppText.bodyMd(),
              ),
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            height: 52,
            child: ElevatedButton(
              onPressed: () => onSubmit(true),
              child: const Text('I approved - continue'),
            ),
          ),
        ],
      ),
    );
  }
}

class _CaptchaView extends StatefulWidget {
  const _CaptchaView({required this.challenge, required this.onSubmit});

  final CaptchaChallenge challenge;
  final void Function(Object) onSubmit;

  @override
  State<_CaptchaView> createState() => _CaptchaViewState();
}

class _CaptchaViewState extends State<_CaptchaView> {
  final _ctrl = TextEditingController();
  late final Uint8List _bytes;
  String? _decodeError;

  @override
  void initState() {
    super.initState();
    try {
      final raw = widget.challenge.imageBase64;
      final clean = raw.contains(',') ? raw.split(',').last : raw;
      _bytes = base64Decode(clean);
    } catch (e) {
      _decodeError = e.toString();
      _bytes = Uint8List(0);
    }
  }

  @override
  void dispose() {
    _ctrl.clear();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Enter the code shown', style: AppText.titleLg()),
          const SizedBox(height: 16),
          if (_decodeError != null)
            Text(
              'Failed to load captcha: $_decodeError',
              style: AppText.bodySm(color: palette.red),
            )
          else
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(kRadiusS),
              ),
              child: Image.memory(_bytes),
            ),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            autofillHints: const [],
            style: AppText.monoMd().copyWith(fontSize: 20, letterSpacing: 2),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          SizedBox(
            height: 52,
            child: ElevatedButton(
              onPressed: () => widget.onSubmit(_ctrl.text),
              child: const Text('Submit'),
            ),
          ),
        ],
      ),
    );
  }
}

class _BusyView extends StatelessWidget {
  const _BusyView({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(message, style: AppText.bodyMd(color: palette.muted)),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.triangleAlert, size: 48, color: palette.red),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center, style: AppText.bodyMd()),
            const SizedBox(height: 20),
            SizedBox(
              height: 52,
              child: ElevatedButton(
                onPressed: onRetry,
                child: const Text('Try again'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Default state of the Add Bank picker: a 2-column grid of popular US
/// issuers. Tapping a tile fires `_pickPopular` which does a live search
/// for the canonical InstitutionID and proceeds to the credentials form.
class _PopularBanksGrid extends StatelessWidget {
  const _PopularBanksGrid({
    required this.onPick,
    required this.pickingName,
    required this.logoFor,
  });

  final void Function(PopularBank) onPick;

  /// Display name of the tile currently being picked, or null when idle.
  /// Per-bank instead of a global bool so only the tapped tile spins.
  final String? pickingName;

  /// Resolver from a bank to its prefetched Sophtron logo URL (or null
  /// while the prefetch is in flight / failed for that bank).
  final String? Function(PopularBank) logoFor;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    // 4 rows × 2 columns. Mapped to kPopularBanks order so adding /
    // reordering the static list reshapes the grid automatically.
    final rows = <List<PopularBank>>[];
    for (var i = 0; i < kPopularBanks.length; i += 2) {
      rows.add(
        kPopularBanks.sublist(i, (i + 2).clamp(0, kPopularBanks.length)),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: 20, bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'POPULAR BANKS',
            style: AppText.labelSm(
              color: palette.muted,
            ).copyWith(fontWeight: FontWeight.w600, letterSpacing: 1.5),
          ),
          const SizedBox(height: 12),
          for (final row in rows) ...[
            Row(
              children: [
                for (var i = 0; i < row.length; i++) ...[
                  Expanded(
                    child: _PopularTile(
                      bank: row[i],
                      logoUrl: logoFor(row[i]),
                      // Block every tile while any pick is in flight (no
                      // double-tap races), but only the tapped one shows
                      // a spinner.
                      onTap: pickingName != null ? null : () => onPick(row[i]),
                      busy: pickingName == row[i].displayName,
                    ),
                  ),
                  if (i < row.length - 1) const SizedBox(width: 12),
                ],
                // Pad the last row if it's a single tile so layout stays
                // even - keeps the 2-column rhythm when the list has an
                // odd length.
                if (row.length == 1) const Expanded(child: SizedBox()),
              ],
            ),
            const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }
}

class _PopularTile extends StatelessWidget {
  const _PopularTile({
    required this.bank,
    required this.logoUrl,
    required this.onTap,
    required this.busy,
  });
  final PopularBank bank;

  /// Real Sophtron logo URL once the prefetch resolves; null while we
  /// haven't fetched yet or if the lookup failed for this bank.
  final String? logoUrl;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(kRadiusM),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(kRadiusM),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 48,
              height: 48,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                color: AppColors.bankLogoTile,
                shape: BoxShape.circle,
              ),
              clipBehavior: Clip.antiAlias,
              child: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : (logoUrl != null
                        ? Padding(
                            padding: const EdgeInsets.all(6),
                            child: CachedNetworkImage(
                              imageUrl: logoUrl!,
                              // contain (not cover) - Sophtron logos have
                              // built-in whitespace; cover crops the brand.
                              fit: BoxFit.contain,
                              errorWidget: (_, _, _) =>
                                  const Icon(LucideIcons.landmark, size: 22),
                            ),
                          )
                        : const Icon(LucideIcons.landmark, size: 22)),
            ),
            const SizedBox(height: 10),
            Text(
              bank.displayName,
              style: AppText.bodyMd(),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
