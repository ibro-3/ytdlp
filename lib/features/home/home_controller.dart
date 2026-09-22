import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/video_info.dart';
import '../../core/providers.dart';

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
  @override
  HomeState build() => const HomeState();

  Future<void> fetch({required String url}) async {
    state = state.copyWith(isLoading: true, clearError: true, clearVideo: true);
    try {
      final video = await ref.read(ytdlpServiceProvider).fetchVideoInfo(url);
      state = state.copyWith(isLoading: false, video: video);
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  void reset() => state = const HomeState();
}

final homeControllerProvider = NotifierProvider<HomeController, HomeState>(
  HomeController.new,
);
