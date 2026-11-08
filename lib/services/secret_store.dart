/// Key/value store for credentials. Values must not be written to Hive.
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String? value);
}

class MemorySecretStore implements SecretStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String? value) async {
    if (value == null || value.isEmpty) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }
}
