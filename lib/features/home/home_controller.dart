import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/playlist_info.dart';
import '../../core/models/video_info.dart';
import '../../core/providers.dart';
import '../../services/ytdlp/ytdlp_service.dart';

/// What the Download tab is currently showing: either a single video ready for
/// the format sheet, or a playlist waiting for the user to pick entries.
sealed class HomeContent {
  const HomeContent();
}

class HomeVideo extends HomeContent {
  const HomeVideo(this.video);
  final VideoInfo video;
}

class HomePlaylist extends HomeContent {
  const HomePlaylist(this.playlist);
  final PlaylistInfo playlist;
}

class HomeState {
  const HomeState({this.isLoading = false, this.content, this.error});

  final bool isLoading;

  /// The fetched video or playlist, or null when nothing has been resolved.
  final HomeContent? content;
  final String? error;

  VideoInfo? get video => switch (content) {
    HomeVideo(:final video) => video,
    _ => null,
  };

  PlaylistInfo? get playlist => switch (content) {
    HomePlaylist(:final playlist) => playlist,
    _ => null,
  };

  HomeState copyWith({
    bool? isLoading,
    HomeContent? content,
    String? error,
    bool clearContent = false,
    bool clearError = false,
  }) {
    return HomeState(
      isLoading: isLoading ?? this.isLoading,
      content: clearContent ? null : content ?? this.content,
      error: clearError ? null : error ?? this.error,
    );
  }
}

class HomeController extends Notifier<HomeState> {
  int _requestSeq = 0;

  @override
  HomeState build() => const HomeState();

  /// Resolves [url] to either a single video or a playlist.
  Future<void> fetch({required String url}) async {
    final seq = ++_requestSeq;
    state = state.copyWith(
      isLoading: true,
      clearError: true,
      clearContent: true,
    );
    try {
      final result = await ref.read(ytdlpServiceProvider).fetch(url);
      if (seq != _requestSeq) return; // A newer request superseded this one.
      state = state.copyWith(
        isLoading: false,
        content: switch (result) {
          VideoResult(:final video) => HomeVideo(video),
          PlaylistResult(:final playlist) => HomePlaylist(playlist),
        },
      );
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
