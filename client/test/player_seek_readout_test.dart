import 'package:aiplayer/playback/seek_timeline.dart';
import 'package:aiplayer/ui/player_seek_readout.dart';
import 'package:aiplayer/ui/player_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _view({
  Duration delta = Duration.zero,
  Duration origin = const Duration(hours: 24),
  Duration? target,
  String time = '02:00',
  double width = 320,
  double textScale = 1,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: PlayerTheme.surface(
    Center(
      child: PlayerSeekReadout(
        time: time,
        target: target ?? origin + delta,
        origin: origin,
        maxWidth: width,
      ),
    ),
  ),
);

void main() {
  for (final (delta, direction, label) in [
    (const Duration(seconds: 30), '>>', '+0:30'),
    (const Duration(seconds: -30), '<<', '-0:30'),
    (Duration.zero, '>>', '+0:00'),
    (const Duration(hours: 1, minutes: 2, seconds: 3), '>>', '+1:02:03'),
  ]) {
    testWidgets(
      'readout shows the signed difference $label with ASCII symbols',
      (tester) async {
        await tester.pumpWidget(_view(delta: delta));
        expect(find.text('02:00'), findsOneWidget);
        expect(find.text(direction), findsOneWidget);
        expect(find.text(label), findsOneWidget);
        for (final key in [
          'seek-preview-time',
          'seek-preview-direction',
          'seek-preview-difference',
        ]) {
          final text = tester.widget<Text>(find.byKey(ValueKey(key))).data!;
          expect(text.codeUnits.every((character) => character < 128), isTrue);
        }
      },
    );
  }

  for (final (origin, target, label) in [
    (90700, 120000, '+0:30'),
    (90000, 120700, '+0:30'),
    (120700, 90000, '-0:30'),
    (120000, 90700, '-0:30'),
    (90700, 90100, '+0:00'),
  ]) {
    testWidgets('fractional times $origin -> $target match visible seconds', (
      tester,
    ) async {
      await tester.pumpWidget(
        _view(
          origin: Duration(milliseconds: origin),
          target: Duration(milliseconds: target),
        ),
      );
      expect(find.text(label), findsOneWidget);
      expect(find.text('-0:00'), findsNothing);
      expect(find.text(label.startsWith('-') ? '<<' : '>>'), findsOneWidget);
    });
  }

  testWidgets('target, arrows and difference share their vertical centers', (
    tester,
  ) async {
    await tester.pumpWidget(_view(delta: const Duration(seconds: 30)));
    final target = tester.getRect(
      find.byKey(const ValueKey('seek-preview-time')),
    );
    final direction = tester.getRect(
      find.byKey(const ValueKey('seek-preview-direction')),
    );
    final difference = tester.getRect(
      find.byKey(const ValueKey('seek-preview-difference')),
    );
    expect(direction.center.dy, closeTo(target.center.dy, .01));
    expect(difference.center.dy, closeTo(target.center.dy, .01));
    expect(target.right, lessThan(direction.left));
    expect(direction.right, lessThan(difference.left));
  });

  testWidgets(
    'long times remain on one line on a narrow screen with large text',
    (tester) async {
      await tester.pumpWidget(
        _view(
          delta: const Duration(hours: -12, minutes: -34, seconds: -56),
          time: '123:45:56',
          width: 208,
          textScale: 2.5,
        ),
      );
      expect(tester.takeException(), isNull);
      final readout = tester.getRect(find.byType(PlayerSeekReadout));
      final target = tester.getRect(
        find.byKey(const ValueKey('seek-preview-time')),
      );
      final difference = tester.getRect(
        find.byKey(const ValueKey('seek-preview-difference')),
      );
      expect(readout.width, lessThanOrEqualTo(208));
      expect(target.left, greaterThanOrEqualTo(readout.left - .01));
      expect(difference.right, lessThanOrEqualTo(readout.right + .01));
      expect(difference.center.dy, closeTo(target.center.dy, .01));
    },
  );

  testWidgets(
    'playback advancing during a drag does not move the delta origin',
    (tester) async {
      final position = ValueNotifier(const Duration(seconds: 90));
      final timeline = PlaybackSeekTimeline(
        position: position,
        seek: (_) async {},
      );
      addTearDown(timeline.dispose);
      addTearDown(position.dispose);
      timeline.begin(const Duration(minutes: 2));
      Widget view() => _view(target: timeline.target, origin: timeline.origin);
      await tester.pumpWidget(view());
      expect(find.text('+0:30'), findsOneWidget);
      position.value = const Duration(seconds: 95);
      await tester.pumpWidget(view());
      expect(find.text('+0:30'), findsOneWidget);
      timeline.update(const Duration(seconds: 80));
      await tester.pumpWidget(view());
      expect(find.text('-0:10'), findsOneWidget);
      expect(find.text('<<'), findsOneWidget);
    },
  );
}
