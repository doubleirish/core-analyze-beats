/// Decides when the screen should be kept on: only while a Now Playing view
/// is visible and audio is playing, with the setting on, on an app that
/// supports it. [apply] is called only when that decision changes.
class KeepScreenOnGate {
  KeepScreenOnGate(this._apply);

  final void Function(bool on) _apply;
  int _visible = 0;
  bool _on = false;
  bool _closed = false;

  /// Whether at least one Now Playing view is showing.
  bool get visible => _visible > 0;

  /// The state last passed to [apply].
  bool get on => _on;

  void shown() => _visible++;

  void hidden() {
    if (_visible > 0) _visible--;
  }

  void update({required bool supported, required bool enabled, required bool playing}) {
    if (_closed) return;
    _set(supported && enabled && visible && playing);
  }

  /// Turns the screen lock off if held and ignores later updates.
  void close() {
    if (_closed) return;
    _set(false);
    _closed = true;
  }

  void _set(bool want) {
    if (want == _on) return;
    _on = want;
    _apply(want);
  }
}
