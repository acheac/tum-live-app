import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tumlive_player/src/common/orientation.dart';

MediaQueryData screen(Size size) => MediaQueryData(size: size);

void main() {
  group('allowedOrientations', () {
    test('a phone is portrait only', () {
      // The device this was asked for: 1080x2352 at 3x.
      expect(
        allowedOrientations(screen(const Size(360, 784))),
        <DeviceOrientation>[DeviceOrientation.portraitUp],
      );
    });

    test('a phone held sideways is still a phone', () {
      // shortestSide, not width: the answer must not depend on which way the
      // device happens to be held when it is asked, or rotating once would
      // unlock rotation for good.
      expect(
        allowedOrientations(screen(const Size(784, 360))),
        allowedOrientations(screen(const Size(360, 784))),
      );
    });

    test('a tablet rotates freely', () {
      // A 10" tablet is 800x1280 logical.
      expect(
        allowedOrientations(screen(const Size(800, 1280))),
        DeviceOrientation.values,
      );
    });

    test('the break is Material\'s 600dp, inclusive', () {
      // A 7" tablet sits right on it, and counts as a tablet.
      expect(
        allowedOrientations(screen(const Size(kTabletShortestSide, 960))),
        DeviceOrientation.values,
      );
      expect(
        allowedOrientations(screen(const Size(kTabletShortestSide - 1, 960))),
        <DeviceOrientation>[DeviceOrientation.portraitUp],
      );
    });
  });
}
