import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';

import '../services/downloads/download_manager.dart';
import '../services/downloads/history_service.dart';
import '../services/ytdlp/binary_manager.dart';
import '../services/ytdlp/ytdlp_service.dart';

final historyBoxProvider = Provider<Box<dynamic>>((ref) {
  throw UnimplementedError('historyBoxProvider must be overridden in main()');
});

final historyServiceProvider = Provider<HistoryService>((ref) {
  final box = ref.watch(historyBoxProvider);
  final service = HistoryService(box);
  service.init();
  return service;
});

final binaryManagerProvider = Provider<BinaryManager>((ref) => BinaryManager());

final ytdlpServiceProvider = Provider<YtdlpService>(
  (ref) => YtdlpService(ref.watch(binaryManagerProvider)),
);

Future<Directory> defaultDownloadsDir() async {
  final downloads = await getDownloadsDirectory();
  if (downloads != null) return downloads;
  final external = await getExternalStorageDirectory();
  if (external != null) return Directory('${external.path}/Download');
  return getApplicationDocumentsDirectory();
}

final downloadsDirProvider =
    Provider<Future<Directory> Function()>((ref) => defaultDownloadsDir);

final downloadManagerProvider = Provider<DownloadManager>((ref) {
  return DownloadManager(
    ytdlp: ref.watch(ytdlpServiceProvider),
    history: ref.watch(historyServiceProvider),
    downloadsDir: ref.watch(downloadsDirProvider),
  );
});
