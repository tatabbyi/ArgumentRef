/// Where the live referee streams microphone audio.
///
/// Defaults to the deployed Render backend. Point it somewhere else for local
/// testing without touching code, e.g.:
///
/// ```
/// flutter run --dart-define=ARGUMENTREF_WS_URL=ws://192.168.1.20:8081
/// ```
class BackendConfig {
  const BackendConfig._();

  /// WebSocket origin (scheme + host, no path). `wss://` in production so the
  /// audio stream rides the same TLS as the rest of the app.
  static const String wsOrigin = String.fromEnvironment(
    'ARGUMENTREF_WS_URL',
    defaultValue: 'wss://argumentref-backend.onrender.com',
  );

  /// The audio-ingestion WebSocket path served by the backend.
  static const String audioPath = '/v1/audio';

  /// The same backend over plain HTTP(S), derived from [wsOrigin] so a single
  /// `--dart-define=ARGUMENTREF_WS_URL=…` points both the audio socket and the
  /// REST endpoints (health, history, speech) at the same host.
  static String get httpOrigin {
    if (wsOrigin.startsWith('wss://')) return 'https://${wsOrigin.substring(6)}';
    if (wsOrigin.startsWith('ws://')) return 'http://${wsOrigin.substring(5)}';
    return wsOrigin;
  }

  /// The ElevenLabs text-to-speech endpoint (`POST /v1/speech`) the referee uses
  /// to read its live guidance aloud.
  static const String speechPath = '/v1/speech';

  /// Full URL for the referee voice endpoint.
  static Uri speechUri() => Uri.parse('$httpOrigin$speechPath');

  /// Builds the full audio-ingestion URL with the query params the backend reads
  /// in `audioFormatFromUrl` (encoding / sampleRateHz / channels) plus the
  /// session + participant identifiers.
  static Uri audioUri({
    required String sessionId,
    required String participantId,
    required int sampleRateHz,
    required int channels,
    List<String> speakerLabels = const [],
  }) {
    final labels = speakerLabels
        .map((label) => label.trim())
        .where((label) => label.isNotEmpty)
        .toList(growable: false);
    return Uri.parse('$wsOrigin$audioPath').replace(
      queryParameters: {
        'sessionId': sessionId,
        'participantId': participantId,
        'encoding': 'pcm16',
        'sampleRateHz': '$sampleRateHz',
        'channels': '$channels',
        if (labels.isNotEmpty) 'speakerLabels': labels.join(','),
      },
    );
  }
}
