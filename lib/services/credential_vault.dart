import 'package:uuid/uuid.dart';

import '../core/constants.dart';
import 'hive_service.dart';
import 'secret_store.dart';

/// Cloud and local-server credentials. Hive keeps non-secret settings.
/// Existing plaintext values are copied into [SecretStore] once and deleted.
class CredentialVault {
  CredentialVault(this._hive, this._secrets);

  final HiveService _hive;
  final SecretStore _secrets;
  final Map<String, String> _cache = {};
  static const _uuid = Uuid();

  static const secretKeys = <String>[
    AppConstants.keyOpenaiKey,
    AppConstants.keyAnthropicKey,
    AppConstants.keyGoogleKey,
    AppConstants.keyKimiKey,
    AppConstants.keyStabilityKey,
    AppConstants.keyNvidiaKey,
    AppConstants.keyOpenRouterKey,
    AppConstants.keyDeepSeekKey,
    AppConstants.keyCustomCloudKey,
    AppConstants.keyServerApiKey,
  ];

  static String profileSecretKey(String id) => 'custom_profile_key_$id';

  static String clusterTokenKey(String id) => 'cluster_token_$id';

  String read(String key) => _cache[key] ?? '';

  Future<void> write(String key, String value) async {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      _cache.remove(key);
      await _secrets.write(key, null);
    } else {
      _cache[key] = trimmed;
      await _secrets.write(key, trimmed);
    }
    if (_hive.settingsBox.containsKey(key)) {
      await _hive.settingsBox.delete(key);
    }
  }

  /// Copies leftover Hive secrets into the store and drops them from Hive.
  Future<void> migrateAndLoad() async {
    for (final key in secretKeys) {
      final stored = await _secrets.read(key);
      final hiveValue = _hive.getSetting<String>(key);
      if ((stored == null || stored.isEmpty) &&
          hiveValue != null &&
          hiveValue.isNotEmpty) {
        await _secrets.write(key, hiveValue);
      }
      if (_hive.settingsBox.containsKey(key)) {
        await _hive.settingsBox.delete(key);
      }
      final loaded = await _secrets.read(key);
      if (loaded != null && loaded.isNotEmpty) {
        _cache[key] = loaded;
      } else {
        _cache.remove(key);
      }
    }
    await _migrateCustomProfiles();
  }

  Future<void> _migrateCustomProfiles() async {
    final raw = _hive.getSetting<List>(AppConstants.keyCustomCloudProfiles);
    if (raw == null) return;
    final cleaned = <Map<String, String>>[];
    var changed = false;
    for (final entry in raw.whereType<Map>()) {
      final map = entry.map((key, value) =>
          MapEntry(key.toString(), value?.toString() ?? ''));
      final id = (map['id'] ?? '').isEmpty ? _uuid.v4() : map['id']!;
      if (map['id'] != id) changed = true;
      map['id'] = id;
      final inline = map.remove('apiKey') ?? '';
      if (inline.isNotEmpty) changed = true;
      final secretKey = profileSecretKey(id);
      final stored = await _secrets.read(secretKey);
      if ((stored == null || stored.isEmpty) && inline.isNotEmpty) {
        await _secrets.write(secretKey, inline);
      }
      final loaded = await _secrets.read(secretKey);
      if (loaded != null && loaded.isNotEmpty) {
        _cache[secretKey] = loaded;
      }
      cleaned.add(map);
    }
    if (changed) {
      await _hive.setSetting(AppConstants.keyCustomCloudProfiles, cleaned);
    }
  }

  /// Profiles as stored in Hive, with api keys filled from the secret store
  /// for in-memory use. Call [persistProfiles] to write them back stripped.
  List<Map<String, String>> profilesWithSecrets(List<Map<String, String>> stored) {
    return [
      for (final profile in stored)
        {
          ...profile,
          'apiKey': read(profileSecretKey(profile['id'] ?? '')),
        }
    ];
  }

  Future<List<Map<String, String>>> persistProfiles(
      List<Map<String, String>> profiles) async {
    final stored = <Map<String, String>>[];
    for (final profile in profiles) {
      final id = (profile['id'] ?? '').isEmpty ? _uuid.v4() : profile['id']!;
      final key = (profile['apiKey'] ?? '').trim();
      await write(profileSecretKey(id), key);
      stored.add({
        'id': id,
        'name': profile['name'] ?? '',
        'baseUrl': profile['baseUrl'] ?? '',
        'model': profile['model'] ?? '',
      });
    }
    await _hive.setSetting(AppConstants.keyCustomCloudProfiles, stored);
    return profilesWithSecrets(stored);
  }
}
