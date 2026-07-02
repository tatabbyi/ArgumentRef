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

  /// Builds the full audio-ingestion URL with the query params the backend reads
  /// in `audioFormatFromUrl` (encoding / sampleRateHz / channels) plus the
  /// session + participant identifiers.
  static Uri audioUri({
    required String sessionId,
    required String participantId,
    required int sampleRateHz,
    required int channels,
  }) {
    return Uri.parse('$wsOrigin$audioPath').replace(
      queryParameters: {
        'sessionId': sessionId,
        'participantId': participantId,
        'encoding': 'pcm16',
        'sampleRateHz': '$sampleRateHz',
        'channels': '$channels',
      },
    );
  }
}
