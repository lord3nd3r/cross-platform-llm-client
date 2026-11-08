import 'dart:typed_data';

/// Web has no phone-cluster worker. These stubs keep the shared service
/// compiling and fail closed if something calls them.
class ClusterAuth {
  static const tokenLength = 32;

  static Uint8List? decodeToken(String? text) => null;

  static String encodeToken(Uint8List token) => '';

  static Future<bool> probeTcp({
    required String host,
    required int port,
    Duration timeout = const Duration(seconds: 5),
  }) async =>
      false;

  static Future<bool> probe({
    required String host,
    required int port,
    required Uint8List token,
    Duration timeout = const Duration(seconds: 5),
  }) async =>
      false;
}

class ClusterRelay {
  int get port => 0;

  static Future<ClusterRelay> start({
    required String host,
    required int port,
    required Uint8List token,
  }) async =>
      throw UnsupportedError('Phone cluster is not available on web');

  Future<void> close() async {}
}
