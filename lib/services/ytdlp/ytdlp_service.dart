import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/models/video_info.dart';
import 'binary_manager.dart';

class YtdlpException implements Exception {
  const YtdlpException(this.message);
  final String message;
  @override
  String toString() => message;
}

class YtdlpProcess {
  YtdlpProcess(this._process);
  final Process _process;

  Stream<String> get lines {
    final out =
        _process.stdout.transform(utf8.decoder).transform(const LineSplitter());
    final err =
        _process.stderr.transform(utf8.decoder).transform(const LineSplitter());
    // Merge without extra dependency
    final controller = StreamController<String>();
    var doneOut = false;
    var doneErr = false;
    void checkDone() {
      if (doneOut && doneErr && !controller.isClosed) controller.close();
    }

    out.listen(controller.add,
        onDone: () {
          doneOut = true;
          checkDone();
        },
        onError: controller.addError);
    err.listen(controller.add,
        onDone: () {
          doneErr = true;
          checkDone();
        },
        onError: controller.addError);
    return controller.stream;
  }

  Future<int> get exitCode => _process.exitCode;

  void cancel() {
    try {
      _process.kill();
    } catch (_) {}
  }
}

class YtdlpService {
  YtdlpService(this._binary);
  final BinaryManager _binary;

  Future<VideoInfo> fetchVideoInfo(String url) async {
    final bin = await _binary.ensureYtdlp();
    final hasFfmpeg = await _binary.hasFfmpeg();
    final result =
        await Process.run(bin, ['-J', '--no-warnings', '--no-playlist', url]);
    if (result.exitCode != 0) {
      throw YtdlpException(
          _extractError(result.stderr) ?? 'yt-dlp exited with code ${result.exitCode}');
    }
    final decoded = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    return VideoInfo.fromYtdlpJson(decoded, hasFfmpeg: hasFfmpeg);
  }

  Future<YtdlpProcess> startDownload({
    required String url,
    required Format format,
    required String outputDir,
    required String template,
  }) async {
    final bin = await _binary.ensureYtdlp();
    final args = [
      '--newline',
      '--no-playlist',
      '--no-mtime',
      '-o',
      '$outputDir/$template',
      '-f',
      format.selector,
      url,
    ];
    final process = await Process.start(bin, args);
    return YtdlpProcess(process);
  }

  static String? _extractError(dynamic stderr) {
    final text = stderr is String ? stderr : stderr.toString();
    final lines = const LineSplitter().convert(text);
    for (final line in lines.reversed) {
      final idx = line.indexOf('ERROR:');
      if (idx >= 0) return line.substring(idx + 6).trim();
    }
    final trimmed = text.trim();
    return trimmed.isEmpty ? null : trimmed.split('\n').last.trim();
  }
}
