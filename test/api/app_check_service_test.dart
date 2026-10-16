import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:swipewise/api/app_check_service.dart';

void main() {
  tearDown(AppCheckService.resetForTest);

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
