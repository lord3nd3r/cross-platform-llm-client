import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'secret_store.dart';

SecretStore createPlatformSecretStore() => SecureSecretStore();

/// Android Keystore / iOS Keychain. On web the plugin falls back to
/// browser storage, which is not hardware-backed; the README says so.
class SecureSecretStore implements SecretStore {
  SecureSecretStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(
                encryptedSharedPreferences: true,
                resetOnError: false,
              ),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
              // Standalone macOS builds do not share credentials with other
              // apps and must work without a Keychain Sharing profile.
              mOptions: MacOsOptions(useDataProtectionKeyChain: false),
            );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String? value) async {
    if (value == null || value.isEmpty) {
      await _storage.delete(key: key);
    } else {
      await _storage.write(key: key, value: value);
    }
  }

  bool get usesBrowserStorage => kIsWeb;
}
