import 'dart:io';

import 'package:aiplayer/ui/artwork_scroll_scope.dart';
import 'package:aiplayer/ui/media_artwork.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as images;

class _RetainedCover extends StatefulWidget {
  final Widget child;

  const _RetainedCover({required this.child});

  @override
  State<_RetainedCover> createState() => _RetainedCoverState();
}

class _RetainedCoverState extends State<_RetainedCover>
    with AutomaticKeepAliveClientMixin<_RetainedCover> {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

bool _decoded() => find
    .byType(RawImage, skipOffstage: false)
    .evaluate()
    .any((element) => (element.widget as RawImage).image != null);

void main() {
  testWidgets(
    'retained cold artwork waits until visible before decode and preview',
    (tester) async {
      final scroll = ScrollController();
      final thumbnail = ValueNotifier<String?>(null);
      final previews = <String>[];
      late Directory directory;
      late File cover;
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('retained-artwork-');
        cover = File('${directory.path}/cover.png');
        await cover.writeAsBytes(
          images.encodePng(images.Image(width: 24, height: 12)),
        );
      });
      final imageCache = PaintingBinding.instance.imageCache;
      imageCache
        ..clear()
        ..clearLiveImages();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: ArtworkScrollScope(
              child: ListView.builder(
                controller: scroll,
                scrollCacheExtent: const ScrollCacheExtent.pixels(0),
                itemExtent: 160,
                itemCount: 30,
                itemBuilder: (_, index) => index != 0
                    ? const SizedBox()
                    : _RetainedCover(
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          children: [
                            SizedBox(
                              width: 260,
                              child: ValueListenableBuilder<String?>(
                                valueListenable: thumbnail,
                                builder: (_, path, _) => MediaArtwork(
                                  thumbnail: path,
                                  loadWhileScrolling: true,
                                  onRequestPreview: path == null
                                      ? null
                                      : () => previews.add(path),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final retained = tester.state(find.byType(_RetainedCover));
        scroll.jumpTo(1600);
        await tester.pumpAndSettle();
        expect(retained.mounted, isTrue);

        // The retained sliver has no paint transform. A newly supplied image
        // must not treat its nonfinite global bounds as visible artwork.
        thumbnail.value = cover.path;
        for (var frame = 0; frame < 15; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        expect(
          {'previewRequests': previews.length, 'decoded': _decoded()},
          {'previewRequests': 0, 'decoded': false},
          reason:
              'Kept-alive artwork must not start work outside the viewport.',
        );

        scroll.jumpTo(0);
        for (var frame = 0; frame < 50 && !_decoded(); frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        expect(_decoded(), isTrue);
        await tester.pumpAndSettle();
        expect(previews, [cover.path]);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        scroll.dispose();
        thumbnail.dispose();
        imageCache
          ..clear()
          ..clearLiveImages();
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    },
  );
}
