import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/core/startup.dart';
import 'package:privatelm/main.dart';

void main() {
  test('a timed-out init throws instead of returning a stand-in', () async {
    final hung = Completer<Object>();
    expect(
      requireInit(hung.future, timeout: const Duration(milliseconds: 20), label: 'Storage'),
      throwsA(isA<TimeoutException>().having(
        (e) => e.message,
        'message',
        contains('Storage'),
      )),
    );
  });

  test('credential startup errors propagate to the recovery handler', () async {
    final failure = StateError('Credential store is locked');
    await expectLater(
      requireInit(
        Future<void>.error(failure),
        timeout: const Duration(seconds: 1),
        label: 'Credential storage',
      ),
      throwsA(same(failure)),
    );
  });

  test('a stalled credential store has a bounded startup wait', () async {
    await expectLater(
      requireInit(
        Completer<void>().future,
        timeout: const Duration(milliseconds: 20),
        label: 'Credential storage',
      ),
      throwsA(isA<TimeoutException>().having(
        (e) => e.message,
        'message',
        contains('Credential storage'),
      )),
    );
  });

  testWidgets('startup recovery can display a credential storage failure',
      (tester) async {
    await tester.pumpWidget(const StartupFailureApp(
      detail: 'Credential storage did not finish starting',
    ));

    expect(find.textContaining('local storage or credentials'), findsOneWidget);
    expect(find.text('Credential storage did not finish starting'), findsOneWidget);
  });
}
