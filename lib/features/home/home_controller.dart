import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/video_info.dart';
import '../../core/providers.dart';
import '../../services/ytdlp/ytdlp_service.dart';

class HomeState {
  const HomeState({this.isLoading = false, this.video, this.error});
  final bool isLoading;
  final VideoInfo? video;
  final String? error;

  HomeState copyWith({
    bool? isLoading,
    VideoInfo? video,
    String? error,
    bool clearVideo = false,
    bool clearError = false,
  }) {
    return HomeState(
      isLoading: isLoading ?? this.isLoading,
      video: clearVideo ? null : video ?? this.video,
      error: clearError ? null : error ?? this.error,
    );
  }
}

class HomeController extends Notifier<HomeState> {
  int _requestSeq = 0;

  @override
  HomeState build() => const HomeState();

  Future<void> fetch({required String url}) async {
    final seq = ++_requestSeq;
    state = state.copyWith(isLoading: true, clearError: true, clearVideo: true);
    try {
      final video = await ref.read(ytdlpServiceProvider).fetchVideoInfo(url);
      if (seq != _requestSeq) return; // A newer request superseded this one.
      state = state.copyWith(isLoading: false, video: video);
    } catch (e) {
      if (seq != _requestSeq) return;
      final message = e is YtdlpException ? e.message : e.toString();
      state = state.copyWith(isLoading: false, error: message);
    }
  }

  void reset() {
    _requestSeq++;
    state = const HomeState();
  }
}

final homeControllerProvider = NotifierProvider<HomeController, HomeState>(
  HomeController.new,
);
