import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'sophtron_auth_service.dart';

/// Dart port of `packages/sophtron-adapter/src/apiClient.v2.ts` in
/// github.com/Universal-Connect-Project/ucw-app.
///
/// Covers the v2 surface needed to onboard a bank without using
/// `widget.sophtron.com`: create/resolve a Customer, create Members with
/// credentials, poll Jobs, answer MFA challenges, and fetch enriched
/// `creditCardData` once the connection is live.
///
/// Hardening notes:
/// - Every request has a hard timeout ([_kRequestTimeout]).
/// - Idempotent reads (`GET`) and the long-poll endpoint are retried with
///   capped exponential backoff on transient errors (5xx / 408 / 429 /
///   `SocketException` / `TimeoutException`). `POST` / `PUT` / `DELETE`
///   are NOT retried — they're not safe to replay against a remote bank.
/// - Response payloads are validated against the shape each method
///   actually consumes; mismatches throw [SophtronProtocolException]
///   instead of opaque `TypeError`s.
class BankClient {
  BankClient({http.Client? httpClient, SophtronSleep? sleep})
    : _http = httpClient ?? http.Client(),
      _sleep = sleep ?? _defaultSleep;

  final http.Client _http;
  final SophtronSleep _sleep;

  static const Duration _kRequestTimeout = Duration(seconds: 20);
  static const int _kMaxAttempts = 3;
  static const Duration _kBaseBackoff = Duration(milliseconds: 400);
  static const Duration _kMaxBackoff = Duration(seconds: 4);

  // ---- HTTP plumbing (same HMAC scheme as v1) ----

  Future<dynamic> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final url = '${SophtronConfig.apiBaseUrl}$path';
    final encodedBody = body == null ? null : jsonEncode(body);
    final uri = Uri.parse(url);
    final upperMethod = method.toUpperCase();
    final isIdempotent = upperMethod == 'GET';

    Object? lastError;
    for (var attempt = 1; attempt <= _kMaxAttempts; attempt++) {
      try {
        // Auth header is rebuilt every attempt — the HMAC has no nonce, so
        // re-signing is just paranoia, but it's cheap and ensures we
        // re-derive after any future clock-bound auth scheme change.
        final headers = {
          'Authorization': buildSophtronAuthHeader(
            fullUrl: url,
            httpMethod: upperMethod,
          ),
          if (body != null) 'Content-Type': 'application/json',
        };
        final resp = await switch (upperMethod) {
          'GET' => _http.get(uri, headers: headers).timeout(_kRequestTimeout),
          'POST' =>
            _http
                .post(uri, headers: headers, body: encodedBody)
                .timeout(_kRequestTimeout),
          'PUT' =>
            _http
                .put(uri, headers: headers, body: encodedBody)
                .timeout(_kRequestTimeout),
          'DELETE' =>
            _http.delete(uri, headers: headers).timeout(_kRequestTimeout),
          _ => throw ArgumentError('unsupported method: $upperMethod'),
        };
        if (resp.statusCode >= 200 && resp.statusCode < 300) {
          if (resp.body.isEmpty) return null;
          try {
            return jsonDecode(resp.body);
          } on FormatException catch (e) {
            // A 2xx with a non-JSON body (a CDN/proxy error page, a truncated
            // response). Surface it as a protocol error instead of letting a
            // raw FormatException escape to callers, where it reads as an
            // unexpected crash / false "Reconnect" instead of a sync failure.
            throw SophtronProtocolException(
              path: path,
              reason:
                  'malformed JSON in ${resp.statusCode} response: ${e.message}',
            );
          }
        }
        final retryable =
            resp.statusCode >= 500 ||
            resp.statusCode == 408 ||
            resp.statusCode == 429;
        if (retryable && isIdempotent && attempt < _kMaxAttempts) {
          lastError = SophtronV2Exception._fromResponse(
            method: upperMethod,
            path: path,
            statusCode: resp.statusCode,
            rawBody: resp.body,
          );
          await _backoff(attempt, _retryAfterMs(resp));
          continue;
        }
        // A retryable status (5xx / 408 / 429) that survived every attempt —
        // or arrived on a non-idempotent request we don't replay — is a
        // server-side / rate-limit condition, not a permanent failure.
        // Classify it transient so the sync engine PRESERVES the connection's
        // prior status instead of flipping it to a false "Reconnect" (a red ✗
        // on the Cards screen for what is really an issuer hiccup). Timeouts
        // and socket errors below already do this; HTTP 5xx/429 must too.
        if (retryable) {
          throw SophtronTransientException(
            method: upperMethod,
            path: path,
            cause: 'HTTP ${resp.statusCode} after $attempt attempt(s)',
            inner: SophtronV2Exception._fromResponse(
              method: upperMethod,
              path: path,
              statusCode: resp.statusCode,
              rawBody: resp.body,
            ),
          );
        }
        throw SophtronV2Exception._fromResponse(
          method: upperMethod,
          path: path,
          statusCode: resp.statusCode,
          rawBody: resp.body,
        );
      } on TimeoutException catch (e) {
        lastError = e;
        if (!isIdempotent || attempt >= _kMaxAttempts) {
          throw SophtronTransientException(
            method: upperMethod,
            path: path,
            cause: 'timeout after ${_kRequestTimeout.inSeconds}s',
            inner: e,
          );
        }
        await _backoff(attempt, null);
      } on SocketException catch (e) {
        lastError = e;
        if (!isIdempotent || attempt >= _kMaxAttempts) {
          throw SophtronTransientException(
            method: upperMethod,
            path: path,
            cause: 'network: ${e.message}',
            inner: e,
          );
        }
        await _backoff(attempt, null);
      } on http.ClientException catch (e) {
        // The `http` package's IOClient wraps low-level transport failures
        // (connection reset, "Software caused connection abort", failed host
        // lookup) into a ClientException before they surface here — so these
        // never arrive as SocketException. Classify them identically: retry
        // idempotent GETs, otherwise raise a transient error so the sync
        // engine PRESERVES the connection's prior status instead of flipping
        // it to a false "Reconnect" (a red ✗ on the Cards screen for what is
        // really a passing network blip).
        lastError = e;
        if (!isIdempotent || attempt >= _kMaxAttempts) {
          throw SophtronTransientException(
            method: upperMethod,
            path: path,
            cause: 'network: ${e.message}',
            inner: e,
          );
        }
        await _backoff(attempt, null);
      }
    }
    // Unreachable: every loop exit either returns or throws. Defensive.
    if (lastError != null) {
      Error.throwWithStackTrace(lastError, StackTrace.current);
    }
    throw StateError('request retry loop exited without resolution');
  }

  int? _retryAfterMs(http.Response resp) {
    final header = resp.headers['retry-after'];
    if (header == null) return null;
    final secs = int.tryParse(header);
    if (secs != null) return secs * 1000;
    try {
      final when = HttpDate.parse(header);
      final diff = when.difference(DateTime.now()).inMilliseconds;
      return diff > 0 ? diff : 0;
    } on HttpException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<void> _backoff(int attempt, int? retryAfterMs) async {
    final base =
        retryAfterMs ?? _kBaseBackoff.inMilliseconds * (1 << (attempt - 1));
    final jitter = Random().nextInt(200);
    final clamped = min(base + jitter, _kMaxBackoff.inMilliseconds);
    await _sleep(Duration(milliseconds: clamped));
  }

  // ---- Customer ----

  /// Returns the existing Customer for our SOPHTRON_USER_ID, or null.
  Future<Map<String, dynamic>?> getCustomerByUniqueName(String uniqueId) async {
    final r = await _request(
      'GET',
      'v2/customers?uniqueID=${Uri.encodeQueryComponent(uniqueId)}',
    );
    if (r == null) return null;
    if (r is! List) {
      throw SophtronProtocolException(
        path: 'v2/customers',
        reason: 'expected List, got ${r.runtimeType}',
      );
    }
    if (r.isEmpty) return null;
    final first = r.first;
    if (first is! Map<String, dynamic>) {
      throw SophtronProtocolException(
        path: 'v2/customers',
        reason: 'first row not a Map: ${first.runtimeType}',
      );
    }
    return first;
  }

  /// One-time call when a user first signs in. Idempotent at the call site
  /// (use `getCustomerByUniqueName` first); Sophtron's behavior on a second
  /// `POST` is not documented.
  Future<Map<String, dynamic>> createCustomer(String uniqueId) async {
    final r = await _request(
      'POST',
      'v2/customers',
      body: {
        'UniqueID': uniqueId,
        'Source': 'swipewise',
        'Name': 'Swipewise_Customer',
      },
    );
    if (r is! Map<String, dynamic>) {
      throw SophtronProtocolException(
        path: 'v2/customers',
        reason: 'createCustomer returned ${r.runtimeType}',
      );
    }
    return r;
  }

  /// Convenience: look up or create. Mirrors UCW's `ResolveUserId`.
  Future<String> resolveCustomerId(String uniqueId) async {
    final existing = await getCustomerByUniqueName(uniqueId);
    if (existing != null) {
      final cid = (existing['CustomerID'] ?? existing['ID'])?.toString();
      if (cid != null && cid.isNotEmpty) return cid;
    }
    final created = await createCustomer(uniqueId);
    final cid = (created['CustomerID'] ?? created['ID'])?.toString();
    if (cid == null || cid.isEmpty) {
      throw SophtronProtocolException(
        path: 'v2/customers',
        reason: 'createCustomer did not return a CustomerID',
      );
    }
    return cid;
  }

  // ---- Member (the linked bank) ----

  /// All Members under a Customer. Each entry has `MemberID`,
  /// `InstitutionID`, `CustomerID`, `LastModified` — but **not** the
  /// institution display name/logo (use `getInstitutionByID` for that).
  Future<List<dynamic>> getMembersV2(String customerId) async {
    final r = await _request('GET', 'v2/customers/$customerId/members');
    if (r == null) return const [];
    if (r is! List) {
      throw SophtronProtocolException(
        path: 'v2/customers/$customerId/members',
        reason: 'expected List, got ${r.runtimeType}',
      );
    }
    return r;
  }

  Future<Map<String, dynamic>?> getMember({
    required String customerId,
    required String memberId,
  }) async {
    final r = await _request(
      'GET',
      'v2/customers/$customerId/members/$memberId',
    );
    if (r == null) return null;
    if (r is! Map<String, dynamic>) {
      throw SophtronProtocolException(
        path: 'v2/customers/$customerId/members/$memberId',
        reason: 'expected Map, got ${r.runtimeType}',
      );
    }
    return r;
  }

  /// Creates a Member with bank credentials. Returns the job descriptor
  /// (`{JobID, UserInstitutionID, MemberID}` per the v2 schema).
  ///
  /// SECURITY-SENSITIVE: `password` is passed straight through to Sophtron.
  /// Callers must clear the source string immediately after this returns.
  Future<Map<String, dynamic>> createMember({
    required String customerId,
    required List<String> jobTypes,
    required String institutionId,
    required String username,
    required String password,
  }) async {
    final jobs = jobTypes.map(Uri.encodeComponent).join('|');
    final r = await _request(
      'POST',
      'v2/customers/$customerId/members/$jobs',
      body: {
        'UserName': username,
        'Password': password,
        'InstitutionID': institutionId,
      },
    );
    if (r is! Map<String, dynamic>) {
      throw SophtronProtocolException(
        path: 'v2/customers/$customerId/members/...',
        reason: 'createMember returned ${r.runtimeType}',
      );
    }
    return r;
  }

  Future<void> deleteMember({
    required String customerId,
    required String memberId,
  }) async {
    await _request('DELETE', 'v2/customers/$customerId/members/$memberId');
  }

  /// Triggers a fresh scrape (refresh job) for an existing member and returns
  /// the job descriptor (`{JobID, ...}`). `jobType` is the v2 job — `aggregate`
  /// (standard/live) or `aggregate_extendedhistory` (deep). Poll [getJobInfo]
  /// to completion before reading; the v3 reads otherwise replay the last job.
  Future<Map<String, dynamic>> refreshMember({
    required String customerId,
    required String memberId,
    String jobType = 'aggregate',
  }) async {
    final r = await _request(
      'POST',
      'v2/customers/$customerId/members/$memberId/'
          '${Uri.encodeComponent(jobType)}',
    );
    if (r is! Map<String, dynamic>) {
      throw SophtronProtocolException(
        path: 'v2/customers/$customerId/members/$memberId/...',
        reason: 'refreshMember returned ${r.runtimeType}',
      );
    }
    return r;
  }

  // ---- Job ----

  Future<Map<String, dynamic>> getJobInfo(String jobId) async {
    final r = await _request('GET', 'v2/job/$jobId');
    if (r is Map<String, dynamic>) return r;
    if (r == null) return const {};
    throw SophtronProtocolException(
      path: 'v2/job/$jobId',
      reason: 'expected Map, got ${r.runtimeType}',
    );
  }

  /// `mfaType` is the challenge id from `getJobInfo` (e.g. `SecurityQuestion`,
  /// `TokenMethod`, `TokenInput`, `TokenRead`, `CaptchaImage`).
  Future<void> answerJobMfa({
    required String jobId,
    required String mfaType,
    required String answerText,
  }) async {
    await _request(
      'PUT',
      'v2/job/$jobId/challenge/${Uri.encodeComponent(mfaType)}',
      body: {'AnswerText': answerText},
    );
  }

  // ---- Institution (for the bank picker) ----

  Future<List<dynamic>> searchInstitutions({
    String? query,
    String type = 'Financial',
  }) async {
    final uri = Uri(
      queryParameters: {
        'type': type,
        if (query != null && query.isNotEmpty) 'query': query,
      },
    );
    final r = await _request(
      'GET',
      'v2/institutions${uri.query.isEmpty ? '' : '?${uri.query}'}',
    );
    if (r == null) return const [];
    if (r is! List) {
      throw SophtronProtocolException(
        path: 'v2/institutions',
        reason: 'expected List, got ${r.runtimeType}',
      );
    }
    return r;
  }

  // ---- Institution metadata (v1 endpoint — v2 has no per-id getter) ----

  /// Sophtron exposes institution name/logo/URL only via the v1
  /// `Institution/GetInstitutionByID` endpoint. v2 has `/v2/institutions`
  /// for search but no by-id lookup. We use this once per Member during
  /// sync to populate the display name / logo for the bank-grouping UI.
  ///
  /// Throws on actual API errors so the sync engine can distinguish
  /// transient failures (retry next sync) from permanent 404s (skip
  /// the member with a real error message). Returns null only when the
  /// API explicitly returned an empty body.
  Future<Map<String, dynamic>?> getInstitutionByID(String institutionId) async {
    final r = await _request(
      'POST',
      'Institution/GetInstitutionByID',
      body: {'InstitutionID': institutionId},
    );
    if (r == null) return null;
    if (r is Map<String, dynamic>) return r;
    if (r is List && r.isNotEmpty && r.first is Map<String, dynamic>) {
      return r.first as Map<String, dynamic>;
    }
    throw SophtronProtocolException(
      path: 'Institution/GetInstitutionByID',
      reason: 'unexpected shape: ${r.runtimeType}',
    );
  }

  // ---- FDX V3 reads (accounts + balances inline, transactions) ----

  /// FDX V3 member-scoped accounts. Each element wraps the account in a
  /// `depositAccount` node with balances inline (no detail call needed).
  /// Parse via [BankFdxMapper].
  Future<List<dynamic>> getMemberAccountsV3({
    required String customerId,
    required String memberId,
  }) async {
    final r = await _request(
      'GET',
      'v3/Customers/$customerId/Members/$memberId/accounts',
    );
    if (r == null) return const [];
    if (r is! List) {
      throw SophtronProtocolException(
        path: 'v3/Customers/.../accounts',
        reason: 'expected List, got ${r.runtimeType}',
      );
    }
    return r;
  }

  /// FDX V3 transactions for one account. Query params are `startDate` /
  /// `endDate` (same as V2). Each element wraps the tx in a
  /// `depositTransaction` node; parse via [BankFdxMapper].
  Future<List<dynamic>> getTransactionsV3({
    required String customerId,
    required String accountId,
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    final qs = Uri(
      queryParameters: {
        'startDate': startDate.toUtc().toIso8601String(),
        'endDate': endDate.toUtc().toIso8601String(),
      },
    ).query;
    final r = await _request(
      'GET',
      'v3/Customers/$customerId/accounts/$accountId/transactions?$qs',
    );
    if (r == null) return const [];
    if (r is! List) {
      throw SophtronProtocolException(
        path: 'v3/Customers/.../transactions',
        reason: 'expected List, got ${r.runtimeType}',
      );
    }
    return r;
  }

  void close() => _http.close();
}

/// Sleep injection seam — tests pass a no-op so the backoff loop runs
/// instantly. Production uses `Future.delayed`.
typedef SophtronSleep = Future<void> Function(Duration);
Future<void> _defaultSleep(Duration d) => Future.delayed(d);

// ────── Exception hierarchy ──────

/// Base for all Sophtron failures the client can produce. Specific
/// subclasses let the sync engine and connection flow react differently
/// (re-auth banner vs transient retry vs permanent skip).
sealed class SophtronException implements Exception {
  String get summary;

  @override
  String toString() => summary;
}

/// A non-2xx HTTP response from Sophtron, with details kept structured
/// (status, method, path, optional short error code parsed from the body).
/// **The raw body is NOT included in `toString()`** — Sophtron 4xx
/// bodies often echo back submitted fields. Use [bodyDebugSnapshot] in
/// dev only; never log it in release builds.
class SophtronV2Exception extends SophtronException {
  SophtronV2Exception._({
    required this.method,
    required this.path,
    required this.statusCode,
    required this.errorCode,
    required this.rawBody,
  });

  factory SophtronV2Exception._fromResponse({
    required String method,
    required String path,
    required int statusCode,
    required String rawBody,
  }) {
    String? errorCode;
    try {
      final parsed = jsonDecode(rawBody);
      if (parsed is Map) {
        errorCode =
            (parsed['ErrorCode'] ?? parsed['Code'] ?? parsed['errorCode'])
                ?.toString();
      }
    } catch (_) {
      // Body wasn't JSON — leave errorCode null.
    }
    if (statusCode == 401 || statusCode == 403) {
      return SophtronAuthException._(
        method: method,
        path: path,
        statusCode: statusCode,
        errorCode: errorCode,
        rawBody: rawBody,
      );
    }
    if (statusCode == 404) {
      return SophtronNotFoundException._(
        method: method,
        path: path,
        statusCode: statusCode,
        errorCode: errorCode,
        rawBody: rawBody,
      );
    }
    return SophtronV2Exception._(
      method: method,
      path: path,
      statusCode: statusCode,
      errorCode: errorCode,
      rawBody: rawBody,
    );
  }

  final String method;
  final String path;
  final int statusCode;
  final String? errorCode;
  final String rawBody;

  /// Always kept out of `toString()`. Dev-only callers can opt in.
  String get bodyDebugSnapshot => rawBody;

  @override
  String get summary =>
      'SophtronV2Exception($method $path → HTTP $statusCode'
      '${errorCode == null ? '' : ', code=$errorCode'})';
}

/// 401 / 403 — credentials rotated, link expired, or the user's Member
/// requires re-auth. The Cards-screen broken-connection banner ("Reconnect")
/// is the right response.
class SophtronAuthException extends SophtronV2Exception {
  SophtronAuthException._({
    required super.method,
    required super.path,
    required super.statusCode,
    required super.errorCode,
    required super.rawBody,
  }) : super._();

  @override
  String get summary =>
      'SophtronAuthException($method $path → HTTP $statusCode)';
}

/// 404 — record gone. Sophtron has deleted the Member or it never existed.
/// Caller should skip permanently (drop local state) rather than retry.
class SophtronNotFoundException extends SophtronV2Exception {
  SophtronNotFoundException._({
    required super.method,
    required super.path,
    required super.statusCode,
    required super.errorCode,
    required super.rawBody,
  }) : super._();

  @override
  String get summary =>
      'SophtronNotFoundException($method $path → HTTP $statusCode)';
}

/// Network blip, 5xx, 408, 429, or local TimeoutException after all
/// retries have been spent. Treated as "preserve last sync status,
/// try again next sync."
class SophtronTransientException extends SophtronException {
  SophtronTransientException({
    required this.method,
    required this.path,
    required this.cause,
    required this.inner,
  });

  final String method;
  final String path;
  final String cause;
  final Object inner;

  @override
  String get summary => 'SophtronTransientException($method $path: $cause)';
}

/// Response decoded successfully but didn't match the shape this method
/// expected. Indicates an upstream schema change — should bubble up to
/// crash reporting because it's a hard contract break, not a per-user
/// transient.
class SophtronProtocolException extends SophtronException {
  SophtronProtocolException({required this.path, required this.reason});

  final String path;
  final String reason;

  @override
  String get summary => 'SophtronProtocolException($path: $reason)';
}
