/// A mixtape's chosen icon: a named symbol on a coloured tile. A mix with no
/// spec (or one this app doesn't know) shows a collage of its album art.
///
/// Stored as `name:aarrggbb` (see [encode]) in the PC database, the manifest
/// and the phone's playlist (`#EXT-X-MIX-ICON:`), so it needs no extra files.
class MixIconSpec {
  const MixIconSpec(this.name, this.color);

  /// Key into the curated icon set (`mixIconChoices` in `screens/mix_icon.dart`).
  final String name;

  /// ARGB colour of the tile.
  final int color;

  static final _pattern = RegExp(r'^([a-z0-9_]{1,40}):([0-9a-f]{8})$');

  String encode() => '$name:${color.toRadixString(16).padLeft(8, '0')}';

  /// Parses [encode]'s output; null for anything else (so bad input from
  /// another device just falls back to the collage).
  static MixIconSpec? decode(String? s) {
    final m = s == null ? null : _pattern.firstMatch(s.trim().toLowerCase());
    if (m == null) return null;
    return MixIconSpec(m[1]!, int.parse(m[2]!, radix: 16));
  }

  @override
  bool operator ==(Object other) =>
      other is MixIconSpec && other.name == name && other.color == color;

  @override
  int get hashCode => Object.hash(name, color);

  @override
  String toString() => encode();
}
