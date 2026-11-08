import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/core/startup.dart';

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
}
