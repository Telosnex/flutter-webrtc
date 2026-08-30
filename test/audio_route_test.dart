import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/src/native/audio_route.dart';

void main() {
  test('decodes every audio route kind', () {
    for (final kind in AudioRouteKind.values) {
      final route = AudioRoute.fromMap({
        'id': 'route-${kind.name}',
        'label': kind.name,
        'kind': kind.name,
      });

      expect(route.id, 'route-${kind.name}');
      expect(route.label, kind.name);
      expect(route.kind, kind);
    }
  });

  test('decodes only well-formed route-change events', () {
    expect(
      decodeAudioRouteEvent({
        'event': 'onAudioRouteChanged',
        'route': {
          'id': 'speaker',
          'label': 'Speaker',
          'kind': 'speaker',
        },
      }),
      const AudioRoute(
        id: 'speaker',
        label: 'Speaker',
        kind: AudioRouteKind.speaker,
      ),
    );
    expect(decodeAudioRouteEvent(const {'event': 'onDeviceChange'}), isNull);
    expect(
      decodeAudioRouteEvent(const {'event': 'onAudioRouteChanged'}),
      isNull,
    );
  });

  test('unknown and malformed route fields degrade safely', () {
    expect(
      AudioRoute.fromMap(const {'kind': 'futureRoute'}),
      const AudioRoute(
        id: '',
        label: '',
        kind: AudioRouteKind.unknown,
      ),
    );
    expect(
      AudioRoute.fromMap(const {'id': 4, 'label': false}),
      const AudioRoute(
        id: '',
        label: '',
        kind: AudioRouteKind.unknown,
      ),
    );
  });
}
