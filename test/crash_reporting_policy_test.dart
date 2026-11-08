import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:privatelm/core/constants.dart';
import 'package:privatelm/services/crash_reporting_service.dart';
import 'package:privatelm/services/hive_service.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('crash_policy');
    Hive.init(dir.path);
    Get.put(await HiveService().init());
  });

  tearDown(() async {
    Get.reset();
    await Hive.deleteFromDisk();
    await dir.delete(recursive: true);
  });

  test('crash collection stays off unless the user opts in', () async {
    final policies = <bool>[];
    final reporting = CrashReportingService(collectionControl: (enabled) async {
      policies.add(enabled);
    });
    await reporting.init();
    expect(reporting.isEnabled, isFalse);
    expect(policies, [false]);
  });

  test('opting in is what allows collection to start', () async {
    final hive = Get.find<HiveService>();
    await hive.setSetting(AppConstants.keyCrashReportsOptIn, true);
    final policies = <bool>[];
    final reporting = CrashReportingService(collectionControl: (enabled) async {
      policies.add(enabled);
    });
    await reporting.init();
    expect(reporting.isEnabled, isTrue);
    await reporting.disable();
    expect(reporting.isEnabled, isFalse);
    expect(policies, [true, false]);
  });

  test('startup revokes an SDK opt-in left by an earlier launch', () async {
    var sdkEnabled = true;
    final reporting = CrashReportingService(collectionControl: (enabled) async {
      sdkEnabled = enabled;
    });

    await reporting.init();

    expect(sdkEnabled, isFalse);
    expect(reporting.isEnabled, isFalse);
  });
}
