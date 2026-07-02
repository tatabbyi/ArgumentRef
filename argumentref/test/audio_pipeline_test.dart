import 'package:argumentref/audio/live_ref_controller.dart';
import 'package:argumentref/audio/compromise_sound_player.dart';
import 'package:argumentref/audio/ref_events.dart';
import 'package:argumentref/audio/ref_voice.dart';
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

    test('parses directional interruption events', () {
      final event = RefEvent.parse(
        '{"type":"interruption.detected","provider":"argumentref",'
        '"interrupter":"speaker_1","interrupterLabel":"Ben",'
        '"interrupted":"speaker_0","interruptedLabel":"Ada",'
        '"interrupterText":"No that is not fair",'
        '"interruptedText":"I was trying to explain this because",'
        '"overlapMs":450,"gapMs":0,"confidence":0.84,'
        '"reason":"speaker_overlap"}',
      );

      expect(event, isA<InterruptionDetectedEvent>());
      final cutIn = event as InterruptionDetectedEvent;
      expect(cutIn.interrupter, 'speaker_1');
      expect(cutIn.interrupterLabel, 'Ben');
      expect(cutIn.interrupted, 'speaker_0');
      expect(cutIn.interruptedLabel, 'Ada');
      expect(cutIn.overlapMs, 450);
      expect(cutIn.confidence, closeTo(0.84, 1e-9));
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

    test('parses room tone analysis', () {
      final event = RefEvent.parse(
        '{"type":"room_tone.analyzed","provider":"gemini",'
        '"model":"gemini-3.1-flash-lite",'
        '"generatedAt":"2026-07-02T12:00:00Z",'
        '"lineNumber":2,"sentenceIndex":1,"speaker":"speaker_0",'
        '"speakerLabel":"Ada","text":"You never listen.",'
        '"dominantTone":"angry","trend":"escalating","intensity":86,'
        '"confidence":0.91,"summary":"Sharp accusation",'
        '"signals":["angry","accusatory"],'
        '"phrases":[{"text":"never listen","signal":"accusatory"}]}',
      );

      expect(event, isA<RoomToneAnalyzedEvent>());
      final tone = event as RoomToneAnalyzedEvent;
      expect(tone.model, 'gemini-3.1-flash-lite');
      expect(tone.speakerLabel, 'Ada');
      expect(tone.dominantTone, RoomToneSignal.angry);
      expect(tone.trend, RoomToneTrend.escalating);
      expect(tone.intensity, 86);
      expect(tone.signals, [RoomToneSignal.angry, RoomToneSignal.accusatory]);
      expect(tone.phrases.single.signal, RoomToneSignal.accusatory);
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

    test('tracks who cut off who from backend interruption events', () {
      final c = LiveRefController(
        leftName: 'Ada',
        rightName: 'Ben',
        sessionId: 'test-session',
        participantId: 'test-participant',
      );
      addTearDown(c.dispose);

      c.onEventForTest(
        const InterruptionDetectedEvent(
          interrupter: 'speaker_1',
          interrupterLabel: 'Ben',
          interrupted: 'speaker_0',
          interruptedLabel: 'Ada',
          interrupterText: 'No that is not fair',
          interruptedText: 'I was trying to explain this because',
          overlapMs: 450,
          gapMs: 0,
          confidence: 0.84,
          reason: 'speaker_overlap',
        ),
      );

      expect(c.cutIns, 1);
      expect(c.interruptions.leftCutRight, 0);
      expect(c.interruptions.rightCutLeft, 1);
      expect(c.interruptions.latest?.interrupter, Speaker.right);
      expect(c.interruptions.latest?.interrupted, Speaker.left);
      expect(c.beat.caption, 'Let {L} finish');
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

    test('new top compromises play the referee whistle once', () {
      final soundPlayer = _FakeCompromiseSoundPlayer();
      final c = LiveRefController(
        leftName: 'Ada',
        rightName: 'Ben',
        sessionId: 'test-session',
        participantId: 'test-participant',
        compromiseSoundPlayer: soundPlayer,
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
      c.onEventForTest(
        const CompromiseSuggestedEvent(
          model: 'gemini-3.5-flash',
          generatedAt: '2026-07-02T12:00:30Z',
          transcriptLineCount: 5,
          suggestions: [
            CompromiseSuggestion(
              id: 'compromise-1',
              rank: 1,
              title: 'Two-week trial',
              summary: 'Try the plan for two weeks and review it.',
              whyItCouldWork: 'It lowers the risk for both people.',
              score: 93,
              quality: CompromiseQuality.reallyGood,
              pushLevel: CompromisePushLevel.urgent,
            ),
          ],
        ),
      );
      c.onEventForTest(
        const CompromiseSuggestedEvent(
          model: 'gemini-3.5-flash',
          generatedAt: '2026-07-02T12:01:00Z',
          transcriptLineCount: 6,
          suggestions: [
            CompromiseSuggestion(
              id: 'compromise-2',
              rank: 1,
              title: 'Trade nights',
              summary: 'Alternate who gets first choice each night.',
              whyItCouldWork: 'It shares priority fairly.',
              score: 86,
              quality: CompromiseQuality.strong,
              pushLevel: CompromisePushLevel.firm,
            ),
          ],
        ),
      );

      expect(soundPlayer.playCount, 2);
    });

    test('room tone status reflects the latest Gemini tone reading', () {
      final c = LiveRefController(
        leftName: 'Ada',
        rightName: 'Ben',
        sessionId: 'test-session',
        participantId: 'test-participant',
      );
      addTearDown(c.dispose);

      c.onEventForTest(
        const RoomToneAnalyzedEvent(
          model: 'gemini-3.1-flash-lite',
          generatedAt: '2026-07-02T12:00:00Z',
          lineNumber: 1,
          sentenceIndex: 1,
          speaker: 'speaker_0',
          text: 'You never listen.',
          dominantTone: RoomToneSignal.angry,
          trend: RoomToneTrend.escalating,
          intensity: 84,
          confidence: 0.92,
          summary: 'Sharp accusation',
          signals: [RoomToneSignal.angry, RoomToneSignal.accusatory],
          phrases: [
            RoomTonePhrase(
              text: 'never listen',
              signal: RoomToneSignal.accusatory,
            ),
          ],
        ),
      );

      final tone = c.roomTone;
      expect(tone.label, 'Angry');
      expect(tone.detail, contains('Sharp accusation'));
      expect(tone.score, 84);
      expect(tone.isHeated, isTrue);
      expect(tone.hasAiSignal, isTrue);
      expect(tone.speaker, Speaker.left);
    });
  });

  group('LiveRefController voice', () {
    // A cut-in flag ("Let Ada finish") is a real referee call, so it's read
    // aloud — here with the pause/cooldown gates opened so the assertion is
    // deterministic.
    LiveRefController controllerWith(
      _FakeRefVoice voice, {
      Duration cooldown = Duration.zero,
      Duration settle = Duration.zero,
    }) {
      final c = LiveRefController(
        leftName: 'Ada',
        rightName: 'Ben',
        sessionId: 'test-session',
        participantId: 'test-participant',
        voice: voice,
        voiceCooldown: cooldown,
        voiceSettle: settle,
      );
      c.voiceEnabled = true;
      return c;
    }

    const cutIn = InterruptionDetectedEvent(
      interrupter: 'speaker_1',
      interrupterLabel: 'Ben',
      interrupted: 'speaker_0',
      interruptedLabel: 'Ada',
      interrupterText: 'No that is not fair',
      interruptedText: 'I was trying to explain this because',
      overlapMs: 450,
      gapMs: 0,
      confidence: 0.84,
      reason: 'speaker_overlap',
    );

    const compromise = CompromiseSuggestedEvent(
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
    );

    test('reads a real intervention aloud, naming the person', () {
      final voice = _FakeRefVoice();
      final c = controllerWith(voice);
      addTearDown(c.dispose);

      c.onEventForTest(cutIn);

      // Tokens are filled in before speaking — the ref names the person.
      expect(voice.spoken, ['Let Ada finish']);
    });

    test('does not read routine turn cues aloud', () {
      final voice = _FakeRefVoice();
      final c = controllerWith(voice);
      addTearDown(c.dispose);

      // A plain hand-off ("Go on, Ada") is shown but never spoken — this is what
      // used to make the ref talk over everyone as the floor changed hands.
      c.onEventForTest(
        const TranscriptEvent(
          isFinal: true,
          speaker: 'speaker_0',
          text: 'hello there, let me explain my side of this',
        ),
      );

      expect(voice.spoken, isEmpty);
    });

    test('waits for a natural break before speaking', () {
      final voice = _FakeRefVoice();
      // A long settle means the floor was just active, so the ref holds its call.
      final c = controllerWith(voice, settle: const Duration(seconds: 30));
      addTearDown(c.dispose);

      c.onEventForTest(cutIn);

      expect(voice.spoken, isEmpty);
    });

    test('does not fire two calls back-to-back within the cooldown', () {
      final voice = _FakeRefVoice();
      final c = controllerWith(voice, cooldown: const Duration(minutes: 5));
      addTearDown(c.dispose);

      c.onEventForTest(cutIn); // "Let Ada finish" — spoken
      c.onEventForTest(compromise); // "Try this deal now: …" — inside cooldown

      expect(voice.spoken, ['Let Ada finish']);
    });

    test('stays silent until voice is enabled (e.g. during calibration)', () {
      final voice = _FakeRefVoice();
      final c = LiveRefController(
        leftName: 'Ada',
        rightName: 'Ben',
        sessionId: 'test-session',
        participantId: 'test-participant',
        voice: voice,
        voiceCooldown: Duration.zero,
        voiceSettle: Duration.zero,
      );
      addTearDown(c.dispose);

      c.onEventForTest(cutIn);

      expect(voice.spoken, isEmpty);
    });
  });

  group('BackendConfig', () {
    test('derives an https origin for REST endpoints from the ws origin', () {
      // Default ws origin is wss://…; the speech endpoint must ride https://.
      expect(BackendConfig.httpOrigin, startsWith('https://'));
      expect(
        BackendConfig.speechUri().toString(),
        BackendConfig.httpOrigin + BackendConfig.speechPath,
      );
    });

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

class _FakeCompromiseSoundPlayer implements CompromiseSoundPlayer {
  int playCount = 0;

  @override
  Future<void> playCompromiseFound() {
    playCount++;
    return Future.value();
  }

  @override
  Future<void> dispose() => Future.value();
}

class _FakeRefVoice implements RefVoice {
  final List<String> spoken = [];

  @override
  Future<void> speak(String text) async => spoken.add(text);

  @override
  Future<void> dispose() => Future.value();
}
