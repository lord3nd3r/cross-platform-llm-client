import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:privatelm/core/constants.dart';
import 'package:privatelm/services/credential_vault.dart';
import 'package:privatelm/services/hive_service.dart';
import 'package:privatelm/services/secret_store.dart';

void main() {
  late Directory dir;
  late HiveService hive;
  late MemorySecretStore secrets;
  late CredentialVault vault;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('vault_test');
    Hive.init(dir.path);
    hive = await HiveService().init();
    secrets = MemorySecretStore();
    vault = CredentialVault(hive, secrets);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    await dir.delete(recursive: true);
  });

  test('plaintext Hive keys move into the secret store and are deleted', () async {
    await hive.setSetting(AppConstants.keyOpenRouterKey, 'sk-test-key');
    await hive.setSetting(AppConstants.keyServerApiKey, 'local-server-key');

    await vault.migrateAndLoad();

    expect(hive.settingsBox.containsKey(AppConstants.keyOpenRouterKey), isFalse);
    expect(hive.settingsBox.containsKey(AppConstants.keyServerApiKey), isFalse);
    expect(vault.read(AppConstants.keyOpenRouterKey), 'sk-test-key');
    expect(vault.read(AppConstants.keyServerApiKey), 'local-server-key');
    expect(secrets.values[AppConstants.keyOpenRouterKey], 'sk-test-key');
  });

  test('custom profile API keys are not left in the Hive profile list', () async {
    await hive.setSetting(AppConstants.keyCustomCloudProfiles, [
      {
        'name': 'Home',
        'baseUrl': 'http://127.0.0.1:8080',
        'apiKey': 'profile-secret',
        'model': 'local',
      }
    ]);

    await vault.migrateAndLoad();

    final stored = hive.getSetting<List>(AppConstants.keyCustomCloudProfiles)!;
    final profile = Map<String, String>.from(
        (stored.single as Map).map((k, v) => MapEntry('$k', '${v ?? ''}')));
    expect(profile.containsKey('apiKey'), isFalse);
    expect(profile['id'], isNotEmpty);
    expect(vault.read(CredentialVault.profileSecretKey(profile['id']!)),
        'profile-secret');
  });

  test('writing a secret does not recreate the Hive entry', () async {
    await vault.migrateAndLoad();
    await vault.write(AppConstants.keyGoogleKey, 'ya29-test');
    expect(hive.settingsBox.containsKey(AppConstants.keyGoogleKey), isFalse);
    expect(vault.read(AppConstants.keyGoogleKey), 'ya29-test');
  });
}
