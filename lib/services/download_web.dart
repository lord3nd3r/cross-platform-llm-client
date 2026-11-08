/// Web stub — model downloads are not supported on web.
library;

Future<String> getModelsDir() async => '/web/models';

Future<bool> isModelDownloaded(String path) async => false;

Future<List<String>> getDownloadedModels(String modelsDir) async => [];

Future<int> getModelSize(String path) async => 0;

Future<int> getRemoteFileSize(String url, {String? authToken}) async => 0;

Future<String> downloadModel({
  required String url,
  required String savePath,
  String? authToken,
  void Function(int received, int total)? onProgress,
}) async {
  return 'ERROR: Downloads not supported on web.';
}

void pauseDownload(String filename) {}

Future<void> deleteModel(String path) async {}

Future<Map<String, dynamic>?> startNativeDownload({
  required String url,
  required String filename,
  required String modelsDir,
}) async =>
    null;

Future<bool> cancelNativeDownload({
  required int downloadId,
  required String filename,
}) async =>
    false;

Future<List<Map<String, dynamic>>> getActiveNativeDownloads() async => [];
