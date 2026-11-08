import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:privatelm/controllers/chat_controller.dart';
import 'package:privatelm/services/app_log_service.dart';
import 'package:privatelm/services/hive_service.dart';

void main() {
  late Directory dir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    dir = await Directory.systemTemp.createTemp('chat_race');
    Hive.init(dir.path);
    Get.put(await HiveService().init());
    Get.put(AppLogService());
  });

  tearDown(() async {
    Get.reset();
    await Hive.deleteFromDisk();
    await dir.delete(recursive: true);
  });

  test('switching chats during image read does not file it in the new chat',
      () async {
    final chat = Get.put(ChatController());
    chat.createNewChat();
    final original = chat.currentSessionId.value;
    chat.createNewChat();
    final other = chat.currentSessionId.value;
    chat.openChat(original);

    chat.textController.text = 'describe this';
    chat.selectedImagePath.value = '/tmp/does-not-need-to-exist.jpg';
    chat.readFileBytesForTest = (_) async {
      chat.openChat(other);
      return Uint8List.fromList([1, 2, 3, 4]);
    };

    await chat.sendMessage();

    final hive = Get.find<HiveService>();
    expect(chat.currentSessionId.value, other);
    expect(hive.getMessagesForChat(other), isEmpty);
    expect(hive.getMessagesForChat(original), isEmpty);
    expect(chat.messages, isEmpty);
  });
}
