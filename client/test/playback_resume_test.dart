import 'package:aiplayer/playback/resume.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'old completed and near-end records replay without losing short clip resume',
    () {
      expect(playbackResumeSeconds(position: 6, duration: 6), 0);
      expect(playbackResumeSeconds(position: 5.95, duration: 6), 0);
      expect(playbackResumeSeconds(position: 4, duration: 6), 4);
      expect(playbackResumeSeconds(position: .25, duration: .5), .25);
      expect(playbackResumeSeconds(position: .5, duration: .5), 0);
    },
  );
  test(
    'long videos keep unfinished endings and invalid timestamps are safe',
    () {
      expect(playbackResumeSeconds(position: 3570, duration: 3600), 3570);
      expect(playbackResumeSeconds(position: 3595, duration: 3600), 0);
      expect(playbackResumeSeconds(position: 3700, duration: 3600), 0);
      expect(playbackResumeSeconds(position: 120), 120);
      expect(playbackResumeSeconds(position: double.nan, duration: 6), 0);
      expect(playbackResumeSeconds(position: double.infinity, duration: 6), 0);
      expect(playbackResumeSeconds(position: -4, duration: 6), 0);
    },
  );
}
