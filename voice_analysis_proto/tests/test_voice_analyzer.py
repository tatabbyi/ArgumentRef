import os
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from voice_analyzer import analyze_voice_chunk


class VoiceAnalyzerTests(unittest.TestCase):
    def test_detects_much_higher_status(self):
        baseline = {"average_pitch_hz": 180.0}
        audio_chunk = [0.0, 0.1, 0.2, 0.3, 0.4]
        result = analyze_voice_chunk(audio_chunk, baseline)

        self.assertEqual(result["pitch_status"], "much_higher")
        self.assertGreater(result["current_pitch"], 0)
        self.assertEqual(result["baseline_pitch"], 180.0)

    def test_detects_no_voice_when_silent(self):
        baseline = {"average_pitch_hz": 180.0}
        audio_chunk = [0.0, 0.0, 0.0, 0.0]
        result = analyze_voice_chunk(audio_chunk, baseline)

        self.assertEqual(result["pitch_status"], "no_voice_detected")

    def test_reports_signal_strength_for_live_audio(self):
        baseline = {"average_pitch_hz": 180.0}
        audio_chunk = [0.0, 0.1, 0.2, 0.3, 0.4]
        result = analyze_voice_chunk(audio_chunk, baseline)

        self.assertIn("signal_strength", result)
        self.assertGreater(result["signal_strength"], 0)

    def test_flags_a_modest_pitch_increase(self):
        baseline = {"average_pitch_hz": 180.0}
        audio_chunk = [0.0, 0.1, 0.2, 0.3, 0.4]

        with patch("voice_analyzer.detect_pitch", return_value=198.0):
            result = analyze_voice_chunk(audio_chunk, baseline)

        self.assertEqual(result["pitch_status"], "slightly_higher")
        self.assertEqual(result["delta_hz"], 18.0)


if __name__ == "__main__":
    unittest.main()
