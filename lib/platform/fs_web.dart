import 'dart:async';
import 'dart:typed_data';

/// Web stand-ins so shared UI compiles. Local files are not available in the
/// browser build; callers that need them are mobile-only.
class File implements FileSystemEntity {
  File(this.path);

  @override
  final String path;

  @override
  Uri get uri => Uri.file(path);

  Future<bool> exists() async => false;

  bool existsSync() => false;

  Future<int> length() async => 0;

  Future<Uint8List> readAsBytes() async => Uint8List(0);

  Stream<List<int>> openRead([int? start, int? end]) => const Stream.empty();

  WebSink openWrite() => WebSink();

  Future<File> rename(String newPath) async => File(newPath);

  Future<void> writeAsBytes(List<int> bytes, {bool flush = false}) async {}

  Future<DateTime> lastModified() async =>
      DateTime.fromMillisecondsSinceEpoch(0);

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async => this;

  void deleteSync({bool recursive = false}) {}

  Future<RandomAccessFile> open() async => throw UnsupportedError(
      'Random file access is not available on web');
}

class Directory implements FileSystemEntity {
  Directory(this.path);

  @override
  final String path;

  @override
  Uri get uri => Uri.directory(path);

  Future<bool> exists() async => false;

  Stream<FileSystemEntity> list({bool recursive = false, bool followLinks = true}) =>
      const Stream.empty();

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async => this;
}

abstract class FileSystemEntity {
  String get path;
  Uri get uri;
  Future<FileSystemEntity> delete({bool recursive = false});
}

class RandomAccessFile {
  Future<int> length() async => 0;
  Future<void> close() async {}
  Future<void> setPosition(int position) async {}
  Future<Uint8List> read(int count) async => Uint8List(0);
}

class WebSink {
  void add(List<int> chunk) {}
  Future<void> flush() async {}
  Future<void> close() async {}
}

class HttpException implements Exception {
  HttpException(this.message);
  final String message;
  @override
  String toString() => 'HttpException: $message';
}

class Platform {
  static bool get isAndroid => false;
  static bool get isIOS => false;
  static bool get isMacOS => false;
  static String get operatingSystem => 'web';
  static String get operatingSystemVersion => '';
}
