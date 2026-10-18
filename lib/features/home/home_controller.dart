import 'dart:async';

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
  const HomeState({
    this.isLoading = false,
    this.content,
    this.error,
    this.errorCode,
  });

  final bool isLoading;

  /// The fetched video or playlist, or null when nothing has been resolved.
  final HomeContent? content;
  final String? error;

  /// Machine-readable classification of [error] ([YtdlpException.code]) when
  /// the failure came from the engine itself. Carried beside the message so
  /// the UI branches on the kind of failure, not on English wording.
  final String? errorCode;

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
    String? errorCode,
    bool clearContent = false,
    bool clearError = false,
  }) {
    if (clearError) {
      return HomeState(
        isLoading: isLoading ?? this.isLoading,
        content: clearContent ? null : content ?? this.content,
      );
    }
    return HomeState(
      isLoading: isLoading ?? this.isLoading,
      content: clearContent ? null : content ?? this.content,
      error: error ?? this.error,
      errorCode: errorCode ?? this.errorCode,
    );
  }
}

class HomeController extends Notifier<HomeState> {
  int _requestSeq = 0;

  /// Completes to abandon the fetch that is currently in flight.
  ///
  /// A superseded request has no way to be withdrawn from the outside: the
  /// provider is a singleton and `fetch` may be called again before the first
  /// answer arrives (a paste while one is running). Without this, the old
  /// yt-dlp child keeps running for the rest of its 90-second budget, spending
  /// the user's battery and data on a result that is thrown away.
  Completer<void>? _inFlight;

  @override
  HomeState build() {
    // Leaving the screen discards the controller, so the child it started goes
    // with it.
    ref.onDispose(() => _inFlight?.complete());
    return const HomeState();
  }

  /// Resolves [url] to either a single video or a playlist.
  Future<void> fetch({required String url}) async {
    final seq = ++_requestSeq;
    // The previous fetch's process is stopped rather than left to finish: its
    // result could only be discarded anyway (see [_inFlight]).
    _inFlight?.complete();
    final cancel = Completer<void>();
    _inFlight = cancel;
    state = state.copyWith(
      isLoading: true,
      clearError: true,
      clearContent: true,
    );
    try {
      final result = await ref
          .read(ytdlpServiceProvider)
          .fetch(url, cancelled: cancel.future);
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
      final code = e is YtdlpException ? e.code : null;
      final message = e is YtdlpException ? e.message : e.toString();
      state = state.copyWith(isLoading: false, error: message, errorCode: code);
    } finally {
      // Only the newest fetch owns the handle; an older request completing late
      // must not clear it out from under its successor.
      if (seq == _requestSeq) _inFlight = null;
    }
  }

  /// Clears the fetched video and any error, and cancels an in-flight fetch.
  ///
  /// Bumping the request sequence invalidates a late result, and completing
  /// [_inFlight] is what stops its process rather than leaving a yt-dlp child
  /// running for a result nobody will read.
  void reset() {
    _requestSeq++;
    _inFlight?.complete();
    _inFlight = null;
    state = const HomeState();
  }
}

final homeControllerProvider = NotifierProvider<HomeController, HomeState>(
  HomeController.new,
);
