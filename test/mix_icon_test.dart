import 'package:flutter_test/flutter_test.dart';
import 'package:shared_core/services/mix_icon_spec.dart';

void main() {
  test('MixIconSpec round-trips and rejects junk', () {
    const s = MixIconSpec('run', 0xFF112233);
    final back = MixIconSpec.decode(s.encode())!;
    expect(back.name, 'run');
    expect(back.color, 0xFF112233);
    expect(MixIconSpec.decode('nonsense'), isNull);
    expect(MixIconSpec.decode(null), isNull);
    expect(MixIconSpec.decode(''), isNull);
  });
}
