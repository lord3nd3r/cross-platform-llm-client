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
    var started = false;
    final reporting = CrashReportingService();
    await reporting.init(enableCollection: () async {
      started = true;
      return true;
    });
    expect(started, isFalse);
    expect(reporting.isEnabled, isFalse);
  });

  test('opting in is what allows collection to start', () async {
    final hive = Get.find<HiveService>();
    await hive.setSetting(AppConstants.keyCrashReportsOptIn, true);
    var started = false;
    final reporting = CrashReportingService();
    await reporting.init(enableCollection: () async {
      started = true;
      return true;
    });
    expect(started, isTrue);
    expect(reporting.isEnabled, isTrue);
    reporting.disable();
    expect(reporting.isEnabled, isFalse);
  });
}
