import 'package:argumentref/audio/live_ref_controller.dart';
import 'package:argumentref/audio/ref_events.dart';
import 'package:argumentref/center_ref/beats.dart';
import 'package:argumentref/config/backend_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RefEvent.parse', () {
    test('parses a final transcript', () {
      final event = RefEvent.parse(
        '{"type":"transcript.final","provider":"deepgram","speaker":"speaker_1",'
        '"text":"  hello there  ","confidence":0.91}',
      );
      expect(event, isA<TranscriptEvent>());
      final t = event as TranscriptEvent;
      expect(t.isFinal, isTrue);
      expect(t.speaker, 'speaker_1');
      expect(t.speakerLabel, isNull);
      expect(t.text, 'hello there'); // trimmed
      expect(t.confidence, closeTo(0.91, 1e-9));
    });

    test('parses backend speaker labels', () {
      final event = RefEvent.parse(
        '{"type":"transcript.final","provider":"deepgram","speaker":"speaker_1",'
        '"speakerLabel":"Ada","text":"hello"}',
      );
      expect(event, isA<TranscriptEvent>());
      final t = event as TranscriptEvent;
      expect(t.speaker, 'speaker_1');
      expect(t.speakerLabel, 'Ada');
    });

    test('parses speaker mappings', () {
      final event = RefEvent.parse(
        '{"type":"speaker.mapped","speaker":"speaker_1","speakerLabel":"Ben"}',
      );
      expect(event, isA<SpeakerMappedEvent>());
      final mapped = event as SpeakerMappedEvent;
      expect(mapped.speaker, 'speaker_1');
      expect(mapped.speakerLabel, 'Ben');
    });

    test('marks partials as non-final', () {
      final t =
          RefEvent.parse(
                '{"type":"transcript.partial","speaker":"speaker_0","text":"hi"}',
              )
              as TranscriptEvent;
      expect(t.isFinal, isFalse);
    });

    test('parses transcription.disabled', () {
      final event = RefEvent.parse(
        '{"type":"transcription.disabled","reason":"no key"}',
      );
      expect(event, isA<TranscriptionDisabledEvent>());
      expect((event as TranscriptionDisabledEvent).reason, 'no key');
    });

    test('parses session.started', () {
      final event = RefEvent.parse(
        '{"type":"session.started","sessionId":"s","streamId":"x",'
        '"participantId":"p","acceptedBinaryAudio":true}',
      );
      expect(event, isA<SessionStartedEvent>());
      expect((event as SessionStartedEvent).sessionId, 's');
    });

    test('parses ranked compromise suggestions', () {
      final event = RefEvent.parse(
        '{"type":"compromise.suggested","provider":"gemini",'
        '"model":"gemini-3.5-flash","generatedAt":"2026-07-02T12:00:00Z",'
        '"transcriptLineCount":4,"suggestions":[{'
        '"id":"compromise-1","rank":1,"title":"Two-week trial",'
        '"summary":"Try the plan for two weeks and review it.",'
        '"whyItCouldWork":"It lowers the risk for both people.",'
        '"score":94,"quality":"really_good","pushLevel":"urgent"}]}',
      );

      expect(event, isA<CompromiseSuggestedEvent>());
      final compromise = (event as CompromiseSuggestedEvent).suggestions.single;
      expect(compromise.rank, 1);
      expect(compromise.score, 94);
      expect(compromise.quality, CompromiseQuality.reallyGood);
      expect(compromise.pushLevel, CompromisePushLevel.urgent);
      expect(compromise.shouldPushHard, isTrue);
    });

    test('unknown and malformed frames never throw', () {
      expect(RefEvent.parse('{"type":"weird"}'), isA<UnknownEvent>());
      expect(RefEvent.parse('not json'), isA<UnknownEvent>());
      expect(RefEvent.parse('[1,2,3]'), isA<UnknownEvent>());
    });
  });

  group('LiveRefController speaker mapping', () {
    test('first-heard voice → left, second → right; flow tracks words', () {
      // No AudioSession.start() is called, so nothing touches platform plugins.
      final c = LiveRefController(
        leftName: 'Ada',
        rightName: 'Ben',
        sessionId: 'test-session',
        participantId: 'test-participant',
      );
      addTearDown(c.dispose);

      c.onEventForTest(
        const TranscriptEvent(
          isFinal: true,
          speaker: 'speaker_7',
          text: 'one two three',
        ),
      );
      c.onEventForTest(
        const TranscriptEvent(
          isFinal: true,
          speaker: 'speaker_9',
          text: 'four',
        ),
      );

      final lines = c.transcript;
      expect(lines.length, 2);
      expect(lines[0].speaker, Speaker.left); // speaker_7 came first
      expect(lines[1].speaker, Speaker.right); // speaker_9 second

      // Left said 3 words, right said 1 → left holds ~75% of the floor.
      expect(c.flow, 75);
    });

    test('backend speaker labels win over first-heard order', () {
      final c = LiveRefController(
        leftName: 'Ada',
        rightName: 'Ben',
        sessionId: 'test-session',
        participantId: 'test-participant',
      );
      addTearDown(c.dispose);

      c.onEventForTest(
        const SpeakerMappedEvent(speaker: 'speaker_9', speakerLabel: 'Ben'),
      );
      c.onEventForTest(
        const TranscriptEvent(
          isFinal: true,
          speaker: 'speaker_9',
          speakerLabel: 'Ben',
          text: 'right side spoke first',
        ),
      );

      expect(c.hasMappedLabel('Ben'), isTrue);
      expect(c.transcript.single.speaker, Speaker.right);
    });

    test('conversation reset keeps calibration mappings', () {
      final c = LiveRefController(
        leftName: 'Ada',
        rightName: 'Ben',
        sessionId: 'test-session',
        participantId: 'test-participant',
      );
      addTearDown(c.dispose);

      c.onEventForTest(
        const SpeakerMappedEvent(speaker: 'speaker_0', speakerLabel: 'Ada'),
      );
      c.onEventForTest(
        const TranscriptEvent(
          isFinal: true,
          speaker: 'speaker_0',
          speakerLabel: 'Ada',
          text: 'calibration words',
        ),
      );

      expect(c.transcript, isNotEmpty);
      c.resetConversationStats();

      expect(c.transcript, isEmpty);
      expect(c.flow, 50);
      expect(c.hasMappedLabel('Ada'), isTrue);

      c.onEventForTest(
        const TranscriptEvent(
          isFinal: true,
          speaker: 'speaker_0',
          text: 'first real line',
        ),
      );
      expect(c.transcript.single.speaker, Speaker.left);
    });

    test('really good compromises take over the live guidance', () {
      final c = LiveRefController(
        leftName: 'Ada',
        rightName: 'Ben',
        sessionId: 'test-session',
        participantId: 'test-participant',
      );
      addTearDown(c.dispose);

      c.onEventForTest(
        const CompromiseSuggestedEvent(
          model: 'gemini-3.5-flash',
          generatedAt: '2026-07-02T12:00:00Z',
          transcriptLineCount: 4,
          suggestions: [
            CompromiseSuggestion(
              id: 'compromise-1',
              rank: 1,
              title: 'Two-week trial',
              summary: 'Try the plan for two weeks and review it.',
              whyItCouldWork: 'It lowers the risk for both people.',
              score: 94,
              quality: CompromiseQuality.reallyGood,
              pushLevel: CompromisePushLevel.urgent,
            ),
          ],
        ),
      );

      expect(c.compromises.single.title, 'Two-week trial');
      expect(c.beat.caption, 'Try this deal now: Two-week trial');
      expect(c.beat.mood, Mood.alert);
    });
  });

  group('BackendConfig', () {
    test('adds speakerLabels to the audio WebSocket URL', () {
      final uri = BackendConfig.audioUri(
        sessionId: 'session',
        participantId: 'phone',
        sampleRateHz: 16000,
        channels: 1,
        speakerLabels: const [' Ada ', 'Ben'],
      );

      expect(uri.queryParameters['speakerLabels'], 'Ada,Ben');
    });
  });
}
