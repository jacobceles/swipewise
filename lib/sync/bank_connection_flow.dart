import 'dart:async';
import 'dart:convert';
import '../api/bank_client.dart';
import '../util/logger.dart';

/// In-app port of UCW's `GetConnectionStatus` / `AnswerChallenge` flow
/// (reference: ucw-app/packages/sophtron-adapter/src/adapter.ts:178-342).
///
/// Drives one bank link from `createMember` through any MFA challenges to
/// a terminal success/failure. The UI listens to `state` and shows the
/// appropriate widget; when the user answers a challenge it calls
/// `submitChallengeResponse`.
class BankConnectionFlow {
  BankConnectionFlow({required this.client});

  final BankClient client;

  final _controller = StreamController<SophtronV2ConnectionState>.broadcast();
  Stream<SophtronV2ConnectionState> get state => _controller.stream;
  SophtronV2ConnectionState _last = const SophtronV2ConnectionState.idle();
  SophtronV2ConnectionState get current => _last;

  /// The Member created for this attempt, as soon as Sophtron issues it —
  /// available while the flow is still mid-MFA, i.e. before `_Success`.
  ///
  /// Exposed so a cancel path can `deleteMember` it. Abandoning a half-linked
  /// Member leaks it under the Customer: it never reaches a usable state, but
  /// it still counts against the wallet and the dedupe pass in
  /// `bank_sync_engine` can mistake it for a real connection.
  String? get inFlightMemberId => _memberId;

  /// Customer the in-flight Member belongs to. Paired with [inFlightMemberId]
  /// because `deleteMember` needs both.
  String? get inFlightCustomerId => _customerId;

  String? _customerId;
  String? _memberId;
  String? _jobId;
  String? _userInstitutionId;
  Timer? _poller;
  bool _pollInFlight = false;
  bool _disposed = false;

  /// Polling interval. UCW polls roughly every 2s.
  static const Duration _pollInterval = Duration(seconds: 2);

  /// Hard ceiling so a broken flow doesn't poll forever.
  static const Duration _maxFlowDuration = Duration(minutes: 5);
  DateTime? _flowStartedAt;

  void dispose() {
    _disposed = true;
    _poller?.cancel();
    _poller = null;
    _controller.close();
  }

  void _emit(SophtronV2ConnectionState s) {
    if (_disposed) return;
    _last = s;
    if (!_controller.isClosed) _controller.add(s);
  }

  /// Step 1: create a Customer (idempotent - resolves existing).
  Future<String> ensureCustomer(String uniqueId) async {
    _emit(const SophtronV2ConnectionState.resolvingCustomer());
    final cid = await client.resolveCustomerId(uniqueId);
    _customerId = cid;
    Log.i('v2-flow', 'customer resolved: $cid');
    return cid;
  }

  /// Step 2: POST creds → kick off the link job → start polling.
  ///
  /// SECURITY: `password` is forwarded to Sophtron and discarded. We do
  /// NOT capture it into any field, log line, or persisted state.
  Future<void> startLink({
    required String customerId,
    required String institutionId,
    required String username,
    required String password,
    List<String> jobTypes = const ['aggregate_extendedhistory'],
  }) async {
    _customerId = customerId;
    _flowStartedAt = DateTime.now();
    _emit(const SophtronV2ConnectionState.submittingCredentials());
    // createMember is a POST that BankClient never retries; a network blip,
    // timeout, or non-2xx throws here. Without this guard the exception
    // escapes as an unhandled Future rejection, the flow is stuck on
    // SubmittingCredentials, and the UI spins forever with no error/retry.
    // Mirror submitChallengeResponse below: catch → emit failed.
    final Map<String, dynamic> res;
    try {
      res = await client.createMember(
        customerId: customerId,
        jobTypes: jobTypes,
        institutionId: institutionId,
        username: username,
        password: password,
      );
    } catch (e, st) {
      Log.e('v2-flow', 'createMember failed', e, st);
      _emit(SophtronV2ConnectionState.failed('Could not connect: $e'));
      return;
    }
    _memberId = (res['MemberID'] ?? res['memberID'])?.toString();
    _jobId = (res['JobID'] ?? res['jobID'])?.toString();
    _userInstitutionId = (res['UserInstitutionID'] ?? res['userInstitutionID'])
        ?.toString();
    Log.i('v2-flow', 'member created: $_memberId job: $_jobId');
    if (_jobId == null) {
      _emit(
        SophtronV2ConnectionState.failed(
          'createMember returned no JobID: ${jsonEncode(res)}',
        ),
      );
      return;
    }
    _startPolling();
  }

  void _startPolling() {
    _poller?.cancel();
    _poller = null;
    _emit(const SophtronV2ConnectionState.polling());
    _scheduleNextPoll(Duration.zero); // fire immediately
  }

  /// Schedules the *next* poll. Self-rescheduling loop with an in-flight
  /// guard so a stalled `getJobInfo` doesn't pile up concurrent requests
  /// the way the previous `Timer.periodic` did when the server held the
  /// connection open beyond the 2s tick.
  void _scheduleNextPoll(Duration delay) {
    if (_disposed) return;
    _poller = Timer(delay, () async {
      if (_disposed) return;
      if (_pollInFlight) {
        // Previous poll still mid-flight; let it finish and re-schedule.
        _scheduleNextPoll(_pollInterval);
        return;
      }
      _pollInFlight = true;
      try {
        await _pollOnce();
      } finally {
        _pollInFlight = false;
      }
      // Only reschedule if the flow is still polling — terminal states
      // cancel the poller from _interpretJob.
      if (!_disposed && _last is _Polling && _poller != null) {
        _scheduleNextPoll(_pollInterval);
      }
    });
  }

  Future<void> _pollOnce() async {
    if (_jobId == null) return;
    final started = _flowStartedAt;
    if (started != null &&
        DateTime.now().difference(started) > _maxFlowDuration) {
      _poller?.cancel();
      _poller = null;
      _emit(const SophtronV2ConnectionState.failed('flow timed out'));
      return;
    }
    try {
      final job = await client.getJobInfo(_jobId!);
      // Don't log the whole payload — it can include account numbers.
      // Just the status-relevant fields.
      Log.i(
        'v2-flow',
        'poll: LastStatus=${job['LastStatus']} '
            'SuccessFlag=${job['SuccessFlag']} '
            'SecurityQuestion=${job['SecurityQuestion'] != null} '
            'TokenMethod=${job['TokenMethod'] != null} '
            'TokenSentFlag=${job['TokenSentFlag']} '
            'TokenRead=${job['TokenRead'] != null} '
            'CaptchaImage=${job['CaptchaImage'] != null}',
      );
      _interpretJob(job);
    } catch (e, st) {
      Log.e('v2-flow', 'job poll failed', e, st);
      // Transient errors shouldn't kill the flow — the rescheduler will
      // try again on the next tick.
    }
  }

  void _interpretJob(Map<String, dynamic> job) {
    final success = job['SuccessFlag'];
    if (success == true) {
      _poller?.cancel();
      _emit(
        SophtronV2ConnectionState.success(
          memberId: _memberId!,
          userInstitutionId: _userInstitutionId,
          customerId: _customerId!,
        ),
      );
      return;
    }
    if (success == false && job['LastStatus'] == 'Completed') {
      _poller?.cancel();
      _emit(
        SophtronV2ConnectionState.failed(
          job['ErrorMessage']?.toString() ?? 'Connection failed',
        ),
      );
      return;
    }

    // Challenge dispatch - same order as UCW's adapter.ts:241-291.
    if (job['SecurityQuestion'] != null) {
      final raw = job['SecurityQuestion'].toString();
      List<dynamic> qs;
      try {
        qs = jsonDecode(raw) as List<dynamic>;
      } catch (_) {
        // Single-string format vs array - defend against both.
        qs = [raw];
      }
      _emit(
        SophtronV2ConnectionState.challenge(
          SophtronV2Challenge.securityQuestions(
            questions: qs.map((q) => q.toString()).toList(),
          ),
        ),
      );
      return;
    }
    if (job['TokenMethod'] != null) {
      final raw = job['TokenMethod'].toString();
      List<dynamic> opts;
      try {
        opts = jsonDecode(raw) as List<dynamic>;
      } catch (_) {
        opts = [raw];
      }
      _emit(
        SophtronV2ConnectionState.challenge(
          SophtronV2Challenge.tokenMethod(
            options: opts.map((o) => o.toString()).toList(),
          ),
        ),
      );
      return;
    }
    if (job['TokenSentFlag'] == true) {
      _emit(
        SophtronV2ConnectionState.challenge(
          SophtronV2Challenge.tokenInput(
            fieldName: job['TokenInputName']?.toString() ?? 'OTA code',
          ),
        ),
      );
      return;
    }
    if (job['TokenRead'] != null) {
      _emit(
        SophtronV2ConnectionState.challenge(
          SophtronV2Challenge.tokenRead(token: job['TokenRead'].toString()),
        ),
      );
      return;
    }
    if (job['CaptchaImage'] != null) {
      _emit(
        SophtronV2ConnectionState.challenge(
          SophtronV2Challenge.captcha(
            imageBase64: job['CaptchaImage'].toString(),
          ),
        ),
      );
      return;
    }
    // No challenge yet - keep polling.
  }

  /// User finished a challenge UI; submit the answer and resume polling.
  Future<void> submitChallengeResponse(
    SophtronV2Challenge challenge,
    Object answer,
  ) async {
    final jobId = _jobId;
    if (jobId == null) return;
    final (mfaType, answerText) = _serializeAnswer(challenge, answer);
    _emit(const SophtronV2ConnectionState.submittingChallenge());
    try {
      await client.answerJobMfa(
        jobId: jobId,
        mfaType: mfaType,
        answerText: answerText,
      );
    } catch (e, st) {
      Log.e('v2-flow', 'answerJobMfa failed', e, st);
      _emit(SophtronV2ConnectionState.failed('Challenge answer rejected: $e'));
      return;
    }
    _startPolling();
  }

  (String, String) _serializeAnswer(
    SophtronV2Challenge challenge,
    Object answer,
  ) {
    return switch (challenge) {
      SecurityQuestionsChallenge() => (
        'SecurityQuestion',
        // Sophtron expects JSON-encoded array of answers - see UCW adapter
        // line 327: `JSON.stringify(request.challenges.map((ch) => ch.response))`.
        jsonEncode(answer as List<String>),
      ),
      TokenMethodChallenge() => ('TokenMethod', answer as String),
      TokenInputChallenge() => ('TokenInput', answer as String),
      TokenReadChallenge() => ('TokenRead', 'true'),
      CaptchaChallenge() => ('CaptchaImage', answer as String),
    };
  }
}

// ---- States exposed to the UI ----

sealed class SophtronV2ConnectionState {
  const SophtronV2ConnectionState();

  const factory SophtronV2ConnectionState.idle() = _Idle;
  const factory SophtronV2ConnectionState.resolvingCustomer() =
      _ResolvingCustomer;
  const factory SophtronV2ConnectionState.submittingCredentials() =
      _SubmittingCredentials;
  const factory SophtronV2ConnectionState.polling() = _Polling;
  const factory SophtronV2ConnectionState.challenge(
    SophtronV2Challenge challenge,
  ) = _Challenge;
  const factory SophtronV2ConnectionState.submittingChallenge() =
      _SubmittingChallenge;
  const factory SophtronV2ConnectionState.success({
    required String memberId,
    required String customerId,
    String? userInstitutionId,
  }) = _Success;
  const factory SophtronV2ConnectionState.failed(String message) = _Failed;
}

class _Idle extends SophtronV2ConnectionState {
  const _Idle();
}

class _ResolvingCustomer extends SophtronV2ConnectionState {
  const _ResolvingCustomer();
}

class _SubmittingCredentials extends SophtronV2ConnectionState {
  const _SubmittingCredentials();
}

class _Polling extends SophtronV2ConnectionState {
  const _Polling();
}

class _Challenge extends SophtronV2ConnectionState {
  const _Challenge(this.challenge);
  final SophtronV2Challenge challenge;
}

class _SubmittingChallenge extends SophtronV2ConnectionState {
  const _SubmittingChallenge();
}

class _Success extends SophtronV2ConnectionState {
  const _Success({
    required this.memberId,
    required this.customerId,
    this.userInstitutionId,
  });
  final String memberId;
  final String customerId;
  final String? userInstitutionId;
}

class _Failed extends SophtronV2ConnectionState {
  const _Failed(this.message);
  final String message;
}

// Re-exports so the UI can pattern-match without importing private types.
typedef IdleState = _Idle;
typedef ResolvingCustomerState = _ResolvingCustomer;
typedef SubmittingCredentialsState = _SubmittingCredentials;
typedef PollingState = _Polling;
typedef ChallengeState = _Challenge;
typedef SubmittingChallengeState = _SubmittingChallenge;
typedef SuccessState = _Success;
typedef FailedState = _Failed;

// ---- Challenges ----

sealed class SophtronV2Challenge {
  const SophtronV2Challenge();

  const factory SophtronV2Challenge.securityQuestions({
    required List<String> questions,
  }) = SecurityQuestionsChallenge;

  const factory SophtronV2Challenge.tokenMethod({
    required List<String> options,
  }) = TokenMethodChallenge;

  const factory SophtronV2Challenge.tokenInput({required String fieldName}) =
      TokenInputChallenge;

  const factory SophtronV2Challenge.tokenRead({required String token}) =
      TokenReadChallenge;

  const factory SophtronV2Challenge.captcha({required String imageBase64}) =
      CaptchaChallenge;
}

class SecurityQuestionsChallenge extends SophtronV2Challenge {
  const SecurityQuestionsChallenge({required this.questions});
  final List<String> questions;
}

class TokenMethodChallenge extends SophtronV2Challenge {
  const TokenMethodChallenge({required this.options});
  final List<String> options;
}

class TokenInputChallenge extends SophtronV2Challenge {
  const TokenInputChallenge({required this.fieldName});
  final String fieldName;
}

class TokenReadChallenge extends SophtronV2Challenge {
  const TokenReadChallenge({required this.token});
  final String token;
}

class CaptchaChallenge extends SophtronV2Challenge {
  const CaptchaChallenge({required this.imageBase64});
  final String imageBase64;
}
