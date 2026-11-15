/// A resistance scale, e.g. the Keiser M3's gears 1–24.
class GearScale {
  const GearScale(this.name, this.min, this.max);
  final String name;
  final int min;
  final int max;

  static const keiser = GearScale('Gear', 1, 24);

  int clamp(int g) => g < min ? min : (g > max ? max : g);
}

/// The gear to call out: [absolute] on the scale, [delta] above the base.
class GearCall {
  const GearCall(this.absolute, this.delta, this.scale);
  final int absolute;
  final int delta;
  final GearScale scale;

  String get text => '${scale.name} $absolute';
  String get deltaText => delta == 0 ? 'base' : (delta > 0 ? '+$delta' : '−${-delta}');
}

/// The absolute gear for [delta] above [base], kept inside [scale].
int absoluteGear(int base, int delta, [GearScale scale = GearScale.keiser]) =>
    scale.clamp(base + delta);

/// The gear for a segment, or null when it has none.
GearCall? gearCall(int base, int? delta, [GearScale scale = GearScale.keiser]) =>
    delta == null ? null : GearCall(absoluteGear(base, delta, scale), delta, scale);
