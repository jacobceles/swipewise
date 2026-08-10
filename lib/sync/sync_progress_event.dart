import 'bank_sync_engine.dart' show BankSyncResult;

/// Per-step events emitted by `BankSyncEngine.run` so the UI can show
/// real progress instead of an opaque spinner. The provider adapts these
/// into Riverpod state for screens to watch.
sealed class SyncProgressEvent {
  const SyncProgressEvent();
}

class SyncStarted extends SyncProgressEvent {
  const SyncStarted();
}

class CustomerResolved extends SyncProgressEvent {
  const CustomerResolved();
}

class MembersListed extends SyncProgressEvent {
  const MembersListed(this.count);
  final int count;
}

class MemberStarted extends SyncProgressEvent {
  const MemberStarted({required this.memberId, required this.bankName});
  final String memberId;
  final String bankName;
}

class MemberAccountsLoaded extends SyncProgressEvent {
  const MemberAccountsLoaded({
    required this.memberId,
    required this.bankName,
    required this.accountCount,
  });
  final String memberId;
  final String bankName;
  final int accountCount;
}

class MemberTransactionsLoaded extends SyncProgressEvent {
  const MemberTransactionsLoaded({
    required this.memberId,
    required this.bankName,
    required this.txCount,
  });
  final String memberId;
  final String bankName;
  final int txCount;
}

class MemberCompleted extends SyncProgressEvent {
  const MemberCompleted({
    required this.memberId,
    required this.bankName,
    required this.success,
    this.error,
  });
  final String memberId;
  final String bankName;
  final bool success;
  final String? error;
}

class SyncCompleted extends SyncProgressEvent {
  const SyncCompleted(this.result);
  final BankSyncResult result;
}
