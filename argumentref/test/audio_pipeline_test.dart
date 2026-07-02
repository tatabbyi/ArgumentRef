import 'package:argumentref/audio/live_ref_controller.dart';
import 'package:argumentref/audio/ref_events.dart';
import 'package:argumentref/center_ref/beats.dart';
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
      expect(t.text, 'hello there'); // trimmed
      expect(t.confidence, closeTo(0.91, 1e-9));
    });

    test('marks partials as non-final', () {
      final t = RefEvent.parse(
        '{"type":"transcript.partial","speaker":"speaker_0","text":"hi"}',
      ) as TranscriptEvent;
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
  });
}
