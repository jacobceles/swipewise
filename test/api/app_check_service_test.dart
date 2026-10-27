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
}
