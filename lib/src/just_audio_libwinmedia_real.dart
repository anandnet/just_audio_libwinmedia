import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:flutter/services.dart';
import "package:media_kit/media_kit.dart";

/// The libwinmedia implementation of [JustAudioPlatform].
class LibWinMediaJustAudioPlugin extends JustAudioPlatform {
  final Map<String, LibWinMediaAudioPlayer> players = {};

  /// The entrypoint called by the generated plugin registrant.
  static void registerWith() {
    MediaKit.ensureInitialized();
    JustAudioPlatform.instance = LibWinMediaJustAudioPlugin();
  }

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    if (players.containsKey(request.id)) {
      throw PlatformException(
        code: "error",
        message: "Platform player ${request.id} already exists",
      );
    }
    final player = LibWinMediaAudioPlayer(request.id);
    players[request.id] = player;
    return player;
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(
      DisposePlayerRequest request) async {
    await players[request.id]?.dispose(DisposeRequest());
    players.remove(request.id);
    return DisposePlayerResponse();
  }
}

int _id = 0;

class LibWinMediaAudioPlayer extends AudioPlayerPlatform {
  List<StreamSubscription> streamSubscriptions = [];
  final _eventController = StreamController<PlaybackEventMessage>.broadcast();
  final _dataEventController = StreamController<PlayerDataMessage>.broadcast();
  ProcessingStateMessage _processingState = ProcessingStateMessage.idle;
  Player player;

  LibWinMediaAudioPlayer(String id)
      : player = Player(),
        super(id) {
    _id++;

    void _handlePlaybackEvent(e) {
      broadcastPlaybackEvent();
    }
    player.setVolume(100);
    final durationStream = player.streams.duration.listen(_handlePlaybackEvent);
    streamSubscriptions.add(durationStream);
    final indexStream = player.streams.playlist.listen(_handlePlaybackEvent);
    streamSubscriptions.add(indexStream);
    final bufferingStream = player.streams.buffering.listen((buffering) {
      if (buffering) {
        _processingState = ProcessingStateMessage.buffering;
      }
      _handlePlaybackEvent(buffering);
    });
    streamSubscriptions.add(bufferingStream);
    final completedStream = player.streams.completed.listen((completed) {
      if (completed) {
        _processingState = ProcessingStateMessage.completed;
      }
      _handlePlaybackEvent(completed);
    });
    streamSubscriptions.add(completedStream);
    final playingStream = player.streams.playing.listen((playing) {
      _processingState = ProcessingStateMessage.ready;
      _handlePlaybackEvent(playing);
    });
    streamSubscriptions.add(playingStream);
    final mediasStream = player.streams.playlist.listen(_handlePlaybackEvent);
    streamSubscriptions.add(mediasStream);
    final positionStream = player.streams.position.listen(_handlePlaybackEvent);
    streamSubscriptions.add(positionStream);
    final errorStream = player.streams.error.listen((error) {
      if (error == null) return;
      if (kDebugMode) {
        print("Error: ${error.code}  : ${error.message}");
      }
      switch (error.code) {
        case 0:
          throw PlatformException(code: 'abort', message: error.message);
        default:
          throw PlatformException(
            code: '${error.code}',
            message: error.message,
          );
      }
    });
    streamSubscriptions.add(errorStream);
  }

  /// Broadcasts a playback event from the platform side to the plugin side.
  void broadcastPlaybackEvent() {
    final updateTime = DateTime.now();
    _eventController.add(PlaybackEventMessage(
      processingState: _processingState,
      updatePosition: player.state.position,
      updateTime: updateTime,
      bufferedPosition: player.state.buffer,
      // TODO(libwinmedia): Icy Metadata
      icyMetadata: null,
      duration: player.state.duration,
      currentIndex: 0,
      androidAudioSessionId: null,
    ));
  }

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream =>
      _eventController.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream =>
      _dataEventController.stream;

  List<Media> _loadAudioMessage(AudioSourceMessage sourceMessage) {
    final media = <Media>[];
    switch (sourceMessage.toMap()['type']) {
      case 'progressive':
      case 'dash':
      case 'hsl':
        final message = sourceMessage as UriAudioSourceMessage;
        media.add(Media(message.uri));
        break;
      case 'silence':
        // final message = sourceMessage as SilenceAudioSourceMessage;
        throw UnsupportedError(
            'SilenceAudioSourceMessage is not a supported audio source.');
      case 'concatenating':
        final message = sourceMessage as ConcatenatingAudioSourceMessage;

        for (final source in message.children) {
          media.addAll(_loadAudioMessage(source));
          if (kDebugMode) {
            print("Source added to interface ${source.id}");
          }
        }
        
        break;
      case 'clipping':
        // final message = sourceMessage as ClippingAudioSourceMessage;
        throw UnsupportedError(
            'ClippingAudioSourceMessage is not a supported audio source.');
      case 'looping':
        // final message = sourceMessage as LoopingAudioSourceMessage;
        throw UnsupportedError(
            'LoopingAudioSourceMessage is not a supported audio source.');
    }
    return media;
  }

  /// Loads an audio source.
  @override
  Future<LoadResponse> load(LoadRequest request) {
    _processingState = ProcessingStateMessage.loading;
    final medias = _loadAudioMessage(request.audioSourceMessage);
    player.open(Playlist(medias));
    return Future.microtask(() {
      // Set state to buffering
      _processingState = ProcessingStateMessage.buffering;
      broadcastPlaybackEvent();
      if (kDebugMode) {
        print("Audio Loaded");
      }
      player.play();
      return LoadResponse(duration: null);
    });
  }

  /// Plays the current audio source at the current index and position.
  @override
  Future<PlayResponse> play(PlayRequest request) {
    player.play();
    return Future.value(PlayResponse());
  }

  /// Pauses playback.
  @override
  Future<PauseResponse> pause(PauseRequest request) {
    player.pause();
    return Future.value(PauseResponse());
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async {
    player.setVolume(request.volume*100);
    return SetVolumeResponse();
  }

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async {
    player.setRate(request.speed);
    return SetSpeedResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    if (request.position != null) {
      if (request.index != null) {
        player.jump(request.index!);
      }
      player.seek(request.position!);
    }
    return SeekResponse();
  }

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async {
    switch (request.loopMode) {
      case LoopModeMessage.one:
        break;
      case LoopModeMessage.all:
        break;
      case LoopModeMessage.off:
        break;
    }
    return SetLoopModeResponse();
  }

  @override
  Future<SetShuffleModeResponse> setShuffleMode(
      SetShuffleModeRequest request) async {
    switch (request.shuffleMode) {
      case ShuffleModeMessage.all:
        break;
      case ShuffleModeMessage.none:
        break;
    }
    return SetShuffleModeResponse();
  }

  @override
  Future<ConcatenatingInsertAllResponse> concatenatingInsertAll(
      ConcatenatingInsertAllRequest request) async {
    for (final child in request.children) {
      for (final messasgeChild in _loadAudioMessage(child)) {
        player.add(messasgeChild);
      }
    }
    return ConcatenatingInsertAllResponse();
  }

  @override
  Future<ConcatenatingRemoveRangeResponse> concatenatingRemoveRange(
      ConcatenatingRemoveRangeRequest request) async {
    for (var i = request.startIndex; i < request.endIndex; i++) {
      player.remove(i);
    }
    return ConcatenatingRemoveRangeResponse();
  }

  @override
  Future<ConcatenatingMoveResponse> concatenatingMove(
      ConcatenatingMoveRequest request) async {
    player.jump(request.newIndex);
    return ConcatenatingMoveResponse();
  }

  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async {
    player.dispose();
    await _eventController.close();
    await _dataEventController.close();

    for (final sub in streamSubscriptions) {
      await sub.cancel();
    }

    return DisposeResponse();
  }
}
