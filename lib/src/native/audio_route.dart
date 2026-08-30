/// Broad category for an active audio output route.
enum AudioRouteKind {
  speaker,
  receiver,
  wired,
  bluetooth,
  airPlay,
  systemDefault,
  device,
  unknown,
}

/// The output route currently used for WebRTC playout.
///
/// Native routes are process-wide. Browser output selection is renderer-local,
/// so this model is not used to represent a global web route.
class AudioRoute {
  const AudioRoute({
    required this.id,
    required this.label,
    required this.kind,
  });

  factory AudioRoute.fromMap(Map<dynamic, dynamic> map) {
    final kindName = map['kind'];
    final kind = AudioRouteKind.values.firstWhere(
      (value) => value.name == kindName,
      orElse: () => AudioRouteKind.unknown,
    );
    return AudioRoute(
      id: map['id'] is String ? map['id'] as String : '',
      label: map['label'] is String ? map['label'] as String : '',
      kind: kind,
    );
  }

  final String id;
  final String label;
  final AudioRouteKind kind;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioRoute &&
          id == other.id &&
          label == other.label &&
          kind == other.kind;

  @override
  int get hashCode => Object.hash(id, label, kind);

  @override
  String toString() => 'AudioRoute(id: $id, label: $label, kind: ${kind.name})';
}

/// Decodes an `onAudioRouteChanged` plugin event.
///
/// Returns `null` for unrelated or malformed events.
AudioRoute? decodeAudioRouteEvent(Map<dynamic, dynamic> event) {
  if (event['event'] != 'onAudioRouteChanged') return null;
  final route = event['route'];
  return route is Map ? AudioRoute.fromMap(route) : null;
}
