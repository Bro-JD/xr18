import 'package:flutter_test/flutter_test.dart';

import 'package:xr18_control/main.dart';

void main() {
  group('faderToDb (X-Air fader law)', () {
    test('key positions', () {
      expect(faderToDb(1.0), closeTo(10, 1e-9));
      expect(faderToDb(0.75), closeTo(0, 1e-9));
      expect(faderToDb(0.5), closeTo(-10, 1e-9));
      expect(faderToDb(0.25), closeTo(-30, 1e-9));
      expect(faderToDb(0.0625), closeTo(-60, 1e-9));
      expect(faderToDb(0.0), double.negativeInfinity);
    });
  });

  group('formatDb', () {
    test('formats sign and infinity', () {
      expect(formatDb(0.75), '0.0');
      expect(formatDb(1.0), '+10.0');
      expect(formatDb(0.5), '-10.0');
      expect(formatDb(0.0), '-∞');
    });
  });
}
