import 'dart:async';
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:swipewise/api/app_check_service.dart';

void main() {
  tearDown(AppCheckService.resetForTest);

  test('a hung attestation times out at five seconds and permits a retry', () {
    fakeAsync((clock) {
      final pending = Completer<String?>();
      var calls = 0;
      AppCheckService.getTokenForTest = () =>
          ++calls == 1 ? pending.future : Future.value('retry');
      var completed = false;
      String? result = 'not completed';
      AppCheckService.token().then((value) {
        completed = true;
        result = value;
      });
      clock.flushMicrotasks();
      clock.elapse(const Duration(milliseconds: 4999));
      expect(completed, isFalse);
      clock.elapse(const Duration(milliseconds: 1));
      clock.flushMicrotasks();
      expect(completed, isTrue);
      expect(result, isNull);
      AppCheckService.token().then((value) => result = value);
      clock.flushMicrotasks();
      expect(result, 'retry');
      expect(calls, 2);
      pending.complete('too late');
      clock.flushMicrotasks();
    });
  });

  test('concurrent callers share one attestation', () async {
    var calls = 0;
    final pending = Completer<String?>();
    AppCheckService.getTokenForTest = () {
      calls++;
      return pending.future;
    };

    final waiting = [for (var i = 0; i < 5; i++) AppCheckService.token()];
    pending.complete('tok');

    expect(await Future.wait(waiting), everyElement('tok'));
    expect(calls, 1);
  });

  test(
    'a finished attestation is not kept — the next call asks again',
    () async {
      var calls = 0;
      AppCheckService.getTokenForTest = () async => 'tok${++calls}';

      expect(await AppCheckService.token(), 'tok1');
      expect(await AppCheckService.token(), 'tok2');
    },
  );

  test('a failure is shared once, then cleared', () async {
    var calls = 0;
    AppCheckService.getTokenForTest = () async {
      calls++;
      throw Exception('attestation failed');
    };

    expect(
      await Future.wait([AppCheckService.token(), AppCheckService.token()]),
      [null, null],
    );
    expect(calls, 1);
    expect(await AppCheckService.token(), isNull);
    expect(calls, 2);
  });

  test('overlapping forced callers and normal callers share one refresh', () {
    fakeAsync((clock) {
      final pending = Completer<String?>();
      var refreshCalls = 0;
      AppCheckService.getTokenForTest = () => throw StateError('normal fetch');
      AppCheckService.getTokenForceRefreshForTest = () {
        refreshCalls++;
        return pending.future;
      };
      List<String?>? results;
      Future.wait([
        AppCheckService.token(forceRefresh: true),
        AppCheckService.token(forceRefresh: true),
        AppCheckService.token(),
      ]).then((value) => results = value);

      pending.complete('refreshed');
      clock.flushMicrotasks();

      expect(results, ['refreshed', 'refreshed', 'refreshed']);
      expect(refreshCalls, 1);
      expect(clock.pendingTimers, isEmpty);
    });
  });

  test('normal A completing cannot detach normal C from forced B', () {
    fakeAsync((clock) {
      final normal = Completer<String?>();
      final forced = Completer<String?>();
      var normalCalls = 0;
      var refreshCalls = 0;
      AppCheckService.getTokenForTest = () {
        normalCalls++;
        return normal.future;
      };
      AppCheckService.getTokenForceRefreshForTest = () {
        refreshCalls++;
        return forced.future;
      };
      String? a, b, c;
      AppCheckService.token().then((value) => a = value);
      AppCheckService.token(forceRefresh: true).then((value) => b = value);
      normal.complete('old');
      clock.flushMicrotasks();
      AppCheckService.token().then((value) => c = value);
      clock.flushMicrotasks();
      final cBeforeRefresh = c;
      forced.complete('new');
      clock.flushMicrotasks();

      expect(a, 'old');
      expect(b, 'new');
      expect(cBeforeRefresh, isNull);
      expect(c, 'new');
      expect(normalCalls, 1);
      expect(refreshCalls, 1);
      expect(clock.pendingTimers, isEmpty);
    });
  });

  test(
    'forced B finishing before normal A preserves newer forced ownership',
    () {
      fakeAsync((clock) {
        final normal = Completer<String?>();
        final forcedB = Completer<String?>();
        final forcedC = Completer<String?>();
        var normalCalls = 0;
        var refreshCalls = 0;
        AppCheckService.getTokenForTest = () {
          normalCalls++;
          return normal.future;
        };
        AppCheckService.getTokenForceRefreshForTest = () =>
            ++refreshCalls == 1 ? forcedB.future : forcedC.future;
        String? a, b, c, d;
        AppCheckService.token().then((value) => a = value);
        AppCheckService.token(forceRefresh: true).then((value) => b = value);
        forcedB.complete('B');
        clock.flushMicrotasks();
        AppCheckService.token(forceRefresh: true).then((value) => c = value);
        normal.complete('A');
        clock.flushMicrotasks();
        AppCheckService.token().then((value) => d = value);
        forcedC.complete('C');
        clock.flushMicrotasks();

        expect([a, b, c, d], ['A', 'B', 'C', 'C']);
        expect(normalCalls, 1);
        expect(refreshCalls, 2);
        expect(clock.pendingTimers, isEmpty);
      });
    },
  );

  test('two forced callers supersede, never join, a pending normal fetch', () {
    fakeAsync((clock) {
      final normal = Completer<String?>();
      final forced = Completer<String?>();
      var refreshCalls = 0;
      AppCheckService.getTokenForTest = () => normal.future;
      AppCheckService.getTokenForceRefreshForTest = () {
        refreshCalls++;
        return forced.future;
      };
      List<String?>? results;
      String? a;
      AppCheckService.token().then((value) => a = value);
      Future.wait([
        AppCheckService.token(forceRefresh: true),
        AppCheckService.token(forceRefresh: true),
      ]).then((value) => results = value);
      normal.complete('not refreshed');
      clock.flushMicrotasks();
      final resultsBeforeRefresh = results;
      forced.complete('refreshed');
      clock.flushMicrotasks();

      expect(a, 'not refreshed');
      expect(resultsBeforeRefresh, isNull);
      expect(results, ['refreshed', 'refreshed']);
      expect(refreshCalls, 1);
      expect(clock.pendingTimers, isEmpty);
    });
  });

  test('a failed forced refresh is shared, then permits recovery', () {
    fakeAsync((clock) {
      final pending = Completer<String?>();
      var refreshCalls = 0;
      AppCheckService.getTokenForTest = () async => 'recovered';
      AppCheckService.getTokenForceRefreshForTest = () {
        refreshCalls++;
        return pending.future;
      };
      List<String?>? results;
      Future.wait([
        AppCheckService.token(forceRefresh: true),
        AppCheckService.token(forceRefresh: true),
        AppCheckService.token(),
      ]).then((value) => results = value);
      pending.completeError(StateError('synthetic SDK backoff'));
      clock.flushMicrotasks();
      String? recovered;
      AppCheckService.token().then((value) => recovered = value);
      clock.flushMicrotasks();

      expect(results, [null, null, null]);
      expect(refreshCalls, 1);
      expect(recovered, 'recovered');
      expect(clock.pendingTimers, isEmpty);
    });
  });

  test('older normal timeout cannot clear a pending forced refresh', () {
    fakeAsync((clock) {
      final normal = Completer<String?>();
      final forced = Completer<String?>();
      var normalCalls = 0;
      AppCheckService.getTokenForTest = () {
        normalCalls++;
        return normal.future;
      };
      AppCheckService.getTokenForceRefreshForTest = () => forced.future;
      var aFinished = false;
      String? a = 'pending', b, c;
      AppCheckService.token().then((value) {
        a = value;
        aFinished = true;
      });
      clock.elapse(const Duration(seconds: 1));
      AppCheckService.token(forceRefresh: true).then((value) => b = value);
      clock.elapse(const Duration(seconds: 4));
      clock.flushMicrotasks();
      AppCheckService.token().then((value) => c = value);
      forced.complete('refreshed');
      normal.complete('too late');
      clock.flushMicrotasks();

      expect(aFinished, isTrue);
      expect(a, isNull);
      expect([b, c], ['refreshed', 'refreshed']);
      expect(normalCalls, 1);
      expect(clock.pendingTimers, isEmpty);
    });
  });

  for (final lateFailure in [false, true]) {
    test(
      'forced timeout releases ownership despite late failure=$lateFailure',
      () {
        fakeAsync((clock) {
          final expired = Completer<String?>();
          final recovery = Completer<String?>();
          var refreshCalls = 0;
          var normalCalls = 0;
          AppCheckService.getTokenForTest = () {
            normalCalls++;
            return Future.value('unexpected normal fetch');
          };
          AppCheckService.getTokenForceRefreshForTest = () =>
              ++refreshCalls == 1 ? expired.future : recovery.future;
          List<String?>? timedOut;
          Future.wait([
            AppCheckService.token(forceRefresh: true),
            AppCheckService.token(forceRefresh: true),
            AppCheckService.token(),
          ]).then((value) => timedOut = value);
          clock.elapse(const Duration(milliseconds: 4999));
          final beforeTimeout = timedOut;
          clock.elapse(const Duration(milliseconds: 1));
          clock.flushMicrotasks();
          final callsAfterTimeout = refreshCalls;
          List<String?>? recovered;
          final next = AppCheckService.token(forceRefresh: true);
          if (lateFailure) {
            expired.completeError(StateError('late SDK failure'));
          } else {
            expired.complete('late SDK token');
          }
          clock.flushMicrotasks();
          Future.wait([
            next,
            AppCheckService.token(),
          ]).then((value) => recovered = value);
          recovery.complete('recovered');
          clock.flushMicrotasks();

          expect(beforeTimeout, isNull);
          expect(timedOut, [null, null, null]);
          expect(callsAfterTimeout, 1);
          expect(refreshCalls, 2);
          expect(normalCalls, 0);
          expect(recovered, ['recovered', 'recovered']);
          expect(clock.pendingTimers, isEmpty);
        });
      },
    );
  }

  for (final oldWasForced in [false, true]) {
    test('reset isolates a late forced=$oldWasForced completion', () {
      fakeAsync((clock) {
        final old = Completer<String?>();
        AppCheckService.getTokenForTest = () => old.future;
        AppCheckService.getTokenForceRefreshForTest = () => old.future;
        String? oldResult;
        AppCheckService.token(
          forceRefresh: oldWasForced,
        ).then((value) => oldResult = value);
        AppCheckService.resetForTest();
        final current = Completer<String?>();
        var normalCalls = 0;
        var refreshCalls = 0;
        AppCheckService.getTokenForTest = () {
          normalCalls++;
          return Future.value('unexpected normal fetch');
        };
        AppCheckService.getTokenForceRefreshForTest = () {
          refreshCalls++;
          return current.future;
        };
        final next = AppCheckService.token(forceRefresh: true);
        old.complete('old');
        clock.flushMicrotasks();
        List<String?>? results;
        Future.wait([
          next,
          AppCheckService.token(),
          AppCheckService.token(forceRefresh: true),
        ]).then((value) => results = value);
        current.complete('current');
        clock.flushMicrotasks();

        expect(oldResult, 'old');
        expect(results, ['current', 'current', 'current']);
        expect(normalCalls, 0);
        expect(refreshCalls, 1);
        expect(clock.pendingTimers, isEmpty);
      });
    });
  }

  test('forceRefresh: true calls getTokenForceRefreshForTest when provided', () async {
    var normalCalls = 0;
    var refreshCalls = 0;
    AppCheckService.getTokenForTest = () async {
      normalCalls++;
      return 'normal';
    };
    AppCheckService.getTokenForceRefreshForTest = () async {
      refreshCalls++;
      return 'refreshed';
    };

    expect(await AppCheckService.token(), 'normal');
    expect(normalCalls, 1);
    expect(refreshCalls, 0);

    expect(await AppCheckService.token(forceRefresh: true), 'refreshed');
    expect(normalCalls, 1);
    expect(refreshCalls, 1);
  });

  test('forceRefresh: true falls back to getTokenForTest when refresh setter not provided', () async {
    var calls = 0;
    AppCheckService.getTokenForTest = () async {
      calls++;
      return 'token-$calls';
    };

    expect(await AppCheckService.token(forceRefresh: true), 'token-1');
    expect(calls, 1);
  });
}
