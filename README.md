# shared_core

Code shared by `analyze-this` and `beats-me`: models, tag/lyrics/art services,
BPM/waveform/spectrum analysis, the player engine and queue, and the common
playback UI (mini player, now playing, settings).

Each app subclasses `PlaybackController` (`lib/services/playback_controller.dart`)
and supplies its own library/mix paths and play-finished hook. Register the app
state as both its own type and `PlaybackController` with `provider`.

Run `flutter test` here to cover the shared logic.
