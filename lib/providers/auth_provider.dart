import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sqflite/sqflite.dart';
import '../api/database_helper.dart';
import '../api/sophtron_auth_service.dart';
import 'entitlement_provider.dart';

class AuthState {
  final bool isLoggedIn;
  final String? userId;
  final String? identifier;

  /// The user's Google account email — drives Sophtron Customer uniqueId
  /// derivation so the same email always resolves to the same Customer.
  final String? email;

  /// Per-install Sophtron Customer uniqueId — `sha256(email + salt)` —
  /// passed to `client.resolveCustomerId(...)` so each install resolves
  /// to its own Customer rather than the legacy single-tenant Customer
  /// that every install used to share.
  final String? bankCustomerId;
  final int? authTime;
  final bool isLoading;
  final String? error;

  AuthState({
    this.isLoggedIn = false,
    this.userId,
    this.identifier,
    this.email,
    this.bankCustomerId,
    this.authTime,
    this.isLoading = false,
    this.error,
  });

  AuthState copyWith({
    bool? isLoggedIn,
    String? userId,
    String? identifier,
    String? email,
    String? bankCustomerId,
    int? authTime,
    bool? isLoading,
    String? error,
  }) {
    return AuthState(
      isLoggedIn: isLoggedIn ?? this.isLoggedIn,
      userId: userId ?? this.userId,
      identifier: identifier ?? this.identifier,
      email: email ?? this.email,
      bankCustomerId: bankCustomerId ?? this.bankCustomerId,
      authTime: authTime ?? this.authTime,
      isLoading: isLoading ?? this.isLoading,
      error: error ?? this.error,
    );
  }
}

/// Prefix on a device-local identity, so a glance at `users.id` (or a log
/// line, or the re-key path in [AuthNotifier.signInWithGoogle]) tells you
/// whether you are looking at a local UUID or a Firebase UID.
const String kLocalUserIdPrefix = 'local:';

/// Identity for the two tiers.
///
/// **Pro** signs in with Firebase + Google: `users.id` = Firebase UID (stable
/// across reinstalls for the same Google account), and `bankCustomerId` =
/// `sha256(email + salt)` via [SophtronConfig.deriveCustomerUniqueId].
///
/// **Free** has no accounts at all. There is no server to authenticate
/// against — the catalog it reads is public — so identity is a UUID minted on
/// the device at first launch and never sent anywhere. It exists only to key
/// the local tables: `card_links` and nine others declare
/// `FOREIGN KEY (user_id) REFERENCES users(id)`, so a wallet cannot exist
/// without a `users` row.
///
/// Deliberately *not* an anonymous Firebase account. Those are subject to
/// Google's auto-cleanup of anonymous users, and a swept account comes back
/// as a new UID — which would silently orphan the user's entire wallet, the
/// exact failure this design exists to avoid. Nobody can revoke a local UUID.
class AuthNotifier extends Notifier<AuthState> {
  final _dbHelper = DatabaseHelper();

  /// `google_sign_in` 7 requires exactly one `initialize()` before any other
  /// call on the singleton. Done lazily rather than from `main()` because
  /// signing in is optional — someone who skips it never pays for this.
  ///
  /// Passing no identifiers is correct on Android: `google-services.json`
  /// carries the web OAuth client (`client_type: 3`) the platform needs in
  /// order to hand back an ID token.
  Future<void>? _googleReady;

  Future<void> _ensureGoogleInitialized() async {
    final pending = _googleReady ??= GoogleSignIn.instance.initialize();
    try {
      await pending;
    } catch (_) {
      // Don't cache a failed init — Play Services can be transiently
      // unavailable, and a cached failure would disable the sign-in button
      // for the rest of the session.
      _googleReady = null;
      rethrow;
    }
  }

  @override
  AuthState build() {
    Future.microtask(() => checkStatus());
    return AuthState();
  }

  Future<void> checkStatus() async {
    state = state.copyWith(isLoading: true);
    final db = await _dbHelper.database;
    var rows = await db.query('users', limit: 1);
    if (rows.isEmpty && !ref.read(proEntitlementProvider)) {
      await _createLocalIdentity(db);
      rows = await db.query('users', limit: 1);
    }
    // `build` kicks this off in an unawaited microtask, so the provider can
    // be gone by the time the database answers. Riverpod throws on a write to
    // a disposed Ref; the identity itself is already committed either way.
    if (!ref.mounted) return;

    if (rows.isNotEmpty) {
      final user = rows.first;
      state = state.copyWith(
        isLoggedIn: true,
        userId: user['id'] as String,
        identifier: user['identifier'] as String,
        email: user['email'] as String?,
        bankCustomerId: user['bank_customer_id'] as String?,
        authTime: (user['auth_time'] as num?)?.toInt(),
        isLoading: false,
      );
    } else {
      state = state.copyWith(isLoggedIn: false, isLoading: false);
    }
  }

  /// Mints the free tier's device-local identity. Called once, on the first
  /// launch that finds an empty `users` table; after that [checkStatus] finds
  /// the row and this never runs again.
  Future<void> _createLocalIdentity(Database db) async {
    await db.transaction((txn) async {
      // Re-checked inside the write transaction. Both background isolates —
      // the WorkManager sync dispatcher and the geofence re-register
      // entrypoint — only ever *read* `users`, so nothing races us to create
      // one today. This keeps that a fact rather than an assumption if one of
      // them ever gains a write.
      final existing = await txn.query('users', limit: 1);
      if (existing.isNotEmpty) return;
      await txn.insert('users', {
        'id': '$kLocalUserIdPrefix${_uuidV4()}',
        'identifier': 'You',
        'auth_time': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      });
    });
  }

  Future<void> signInWithGoogle() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      await _ensureGoogleInitialized();
      final GoogleSignInAccount googleUser;
      try {
        googleUser = await GoogleSignIn.instance.authenticate();
      } on GoogleSignInException catch (e) {
        // v7 throws where v6 returned null for a dismissed account picker.
        if (e.code == GoogleSignInExceptionCode.canceled) {
          state = state.copyWith(isLoading: false);
          return;
        }
        rethrow;
      }
      // v7 separates authentication from authorization: `authentication`
      // carries the ID token and nothing else. Firebase only ever needed the
      // ID token for a Google credential — the access token this used to pass
      // was redundant, and no longer obtainable without a scope request.
      final credential = GoogleAuthProvider.credential(
        idToken: googleUser.authentication.idToken,
      );
      final userCredential = await FirebaseAuth.instance.signInWithCredential(
        credential,
      );
      final firebaseUser = userCredential.user!;
      final email = firebaseUser.email!;
      // The Sophtron Customer id is meaningless without bank sync, so it is
      // only derived when the user actually has Pro. Left null otherwise,
      // which is what makes `runSync` bail early for everyone else.
      final uniqueId = ref.read(proEntitlementProvider)
          ? SophtronConfig.deriveCustomerUniqueId(email)
          : null;
      final db = await _dbHelper.database;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      // A device-local identity may already own a wallet the user built
      // before signing in. Carry it onto the Firebase UID instead of leaving
      // a second `users` row behind — [checkStatus] reads `users` with
      // `limit: 1` and would then choose between the two arbitrarily, making
      // the losing side's wallet unreachable.
      //
      // Scoped to local ids on purpose: signing in over a *different* Firebase
      // account is a different situation (one account absorbing another's
      // data), and it can't arise anyway — the login route is only reachable
      // when `users` is empty.
      final existing = await db.query('users', columns: ['id'], limit: 1);
      final priorId = existing.isEmpty ? null : existing.first['id'] as String;
      if (priorId != null && priorId.startsWith(kLocalUserIdPrefix)) {
        await _dbHelper.reassignUserId(from: priorId, to: firebaseUser.uid);
      }

      final values = {
        'identifier': firebaseUser.displayName ?? email,
        'email': email,
        'bank_customer_id': uniqueId,
        'auth_time': now,
      };
      // Update-then-insert rather than `ConflictAlgorithm.replace`: with
      // `PRAGMA foreign_keys = ON`, a REPLACE on an existing row is a DELETE
      // followed by an INSERT, and every user-scoped table cascades on
      // delete. Re-signing in would wipe the wallet it was meant to preserve.
      final updated = await db.update(
        'users',
        values,
        where: 'id = ?',
        whereArgs: [firebaseUser.uid],
      );
      if (updated == 0) {
        await db.insert('users', {'id': firebaseUser.uid, ...values});
      }
      await checkStatus();
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  /// Signs out without deleting anything.
  ///
  /// Signing in is optional and reversible, so signing out has to be too. The
  /// Firebase UID is re-keyed back onto a fresh device-local id — the exact
  /// reverse of the re-key in [signInWithGoogle] — carrying the wallet, the
  /// settings and the onboarding flag across intact. Only the Google identity
  /// is dropped.
  ///
  /// This used to be `db.delete('users')`. With `PRAGMA foreign_keys = ON`
  /// every table in [kUserScopedTables] cascades on that delete, so a single
  /// tap erased the whole wallet. Nothing is destroyed here, on the device or
  /// off it: someone changing phones has not asked us to throw their data
  /// away, and deletion belongs behind an explicit request, not behind the
  /// sign-out button.
  Future<void> logout() async {
    state = state.copyWith(isLoading: true);
    await FirebaseAuth.instance.signOut();
    try {
      await _ensureGoogleInitialized();
      await GoogleSignIn.instance.signOut();
    } catch (_) {
      // Clearing the cached Google account is a convenience — it decides
      // whether the next sign-in shows the account picker. Firebase is
      // already signed out above, so failing here must not strand the user
      // in a half-signed-out state they can't leave.
    }

    final db = await _dbHelper.database;
    final rows = await db.query('users', columns: ['id'], limit: 1);
    if (rows.isNotEmpty) {
      var id = rows.first['id'] as String;
      if (!id.startsWith(kLocalUserIdPrefix)) {
        final localId = '$kLocalUserIdPrefix${_uuidV4()}';
        await _dbHelper.reassignUserId(from: id, to: localId);
        id = localId;
      }
      // `reassignUserId` copies the row wholesale, so the Google-derived
      // fields ride along on the new id and have to be cleared by hand.
      await db.update(
        'users',
        {'identifier': 'You', 'email': null, 'bank_customer_id': null},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    // Reset before re-reading. `copyWith` reads null as "unchanged", so
    // `checkStatus` on its own would carry the signed-out email straight back
    // into the state it just cleared.
    state = AuthState();
    await checkStatus();
  }
}

final authProvider = NotifierProvider<AuthNotifier, AuthState>(() {
  return AuthNotifier();
});

/// RFC 4122 version-4 UUID from [Random.secure].
///
/// Hand-rolled rather than pulling in the `uuid` package: this is the only
/// place the app needs one, and the value never leaves the device — it is a
/// primary key in a local SQLite file, not an identifier anyone else sees.
String _uuidV4() {
  final rnd = Random.secure();
  final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 1 (RFC 4122)
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

// ─────────────────────────── Session (F4) ───────────────────────────
//
// Audit §F4 flagged the invalidation cascade: every screen-level provider
// watched the full `authProvider`, so any AuthState mutation — including
// `isLoading` flips during `checkStatus` and `signIn` — invalidated all
// of them at once. ~20 SQL reads queued behind one transient state
// change.
//
// `sessionProvider` is the stable identity downstream code should
// depend on. It surfaces only the identity-bearing fields of
// `AuthState`; transient `isLoading` / `error` flips don't reach it.
// Selecting `userId` directly is also fine — but `Session` keeps the
// "logged in / logged out" shape typed so screens don't sprinkle
// `auth.userId != null` checks everywhere.

class Session {
  const Session.signedOut()
    : isLoggedIn = false,
      userId = null,
      identifier = null,
      bankCustomerId = null,
      authTime = null;

  Session.from(AuthState s)
    : isLoggedIn = s.isLoggedIn,
      userId = s.userId,
      identifier = s.identifier,
      bankCustomerId = s.bankCustomerId,
      authTime = s.authTime;

  final bool isLoggedIn;
  final String? userId;
  final String? identifier;

  /// Per-install Sophtron Customer uniqueId. Downstream sync /
  /// link code should read this rather than `SophtronConfig.userId`
  /// when calling `resolveCustomerId(...)`.
  final String? bankCustomerId;
  final int? authTime;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! Session) return false;
    return isLoggedIn == other.isLoggedIn &&
        userId == other.userId &&
        identifier == other.identifier &&
        bankCustomerId == other.bankCustomerId &&
        authTime == other.authTime;
  }

  @override
  int get hashCode =>
      Object.hash(isLoggedIn, userId, identifier, bankCustomerId, authTime);
}

/// Stable session identity. Downstream code should prefer this over
/// `authProvider` when it only cares about "who is signed in" — flips
/// of `isLoading` / `error` won't ripple through and trigger N parallel
/// DB reads.
final sessionProvider = Provider<Session>((ref) {
  return ref.watch(authProvider.select((s) => Session.from(s)));
});
