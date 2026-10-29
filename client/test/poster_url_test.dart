import 'package:aiplayer/data/poster_url.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('TMDB viewer uses the original asset at all thumbnail sizes', () {
    for (final size in ['w92', 'w342', 'w500', 'w780', 'h632']) {
      expect(
        originalPosterUrl('https://image.tmdb.org/t/p/$size/poster.jpg'),
        'https://image.tmdb.org/t/p/original/poster.jpg',
      );
    }
    expect(
      originalPosterUrl('http://image.tmdb.org/t/p/w500/poster.jpg'),
      'http://image.tmdb.org/t/p/original/poster.jpg',
    );
  });

  test(
    'Bangumi viewer resolves legacy and resized covers to the large asset',
    () {
      const original = 'https://lain.bgm.tv/pic/cover/l/c2/0a/12_24O6L.jpg';
      for (final size in ['c', 'm', 's', 'g', 'l']) {
        expect(
          originalPosterUrl(
            'https://lain.bgm.tv/pic/cover/$size/c2/0a/12_24O6L.jpg',
          ),
          original,
        );
      }
      for (final size in ['400', '200x0', '0x200', '200x200']) {
        expect(
          originalPosterUrl(
            'https://lain.bgm.tv/r/$size/pic/cover/l/c2/0a/12_24O6L.jpg',
          ),
          original,
        );
      }
    },
  );

  test('changing the size preserves escaped filenames and URL options', () {
    expect(
      originalPosterUrl(
        'https://image.tmdb.org/t/p/w500/cover%20one.jpg?token=a%2Fb&tag=1&tag=2#image',
      ),
      'https://image.tmdb.org/t/p/original/cover%20one.jpg?token=a%2Fb&tag=1&tag=2#image',
    );
    expect(
      originalPosterUrl(
        'https://lain.bgm.tv/r/400/pic/cover/l/c2/0a/poster.jpg?v=2#cover',
      ),
      'https://lain.bgm.tv/pic/cover/l/c2/0a/poster.jpg?v=2#cover',
    );
  });

  test('originals and unknown or malformed URLs remain untouched', () {
    const urls = [
      '',
      'not a URL',
      'https://[broken',
      'file:///t/p/w500/poster.jpg',
      'https://image.tmdb.org/t/p/original/poster.jpg',
      'https://image.tmdb.org/t/p/w500/',
      'https://image.tmdb.org/other/w500/poster.jpg',
      'https://image.tmdb.org/t/p/unknown/poster.jpg',
      'https://image.tmdb.org.evil.example/t/p/w500/poster.jpg',
      'https://image.tmdb.org@custom.example/t/p/w500/poster.jpg',
      'https://custom.example/t/p/w500/poster.jpg?api_key=secret&MaxWidth=500',
      'https://lain.bgm.tv/pic/cover/l/c2/0a/poster.jpg',
      'https://lain.bgm.tv/img/no_icon_subject.png',
      'https://lain.bgm.tv/r/400/img/no_icon_subject.png',
      'https://lain.bgm.tv/r/400/pic/crt/l/c2/0a/person.jpg',
      'https://lain.bgm.tv/r/invalid/pic/cover/l/c2/0a/poster.jpg',
      'https://lain.bgm.tv.evil.example/r/400/pic/cover/l/c2/0a/poster.jpg',
    ];
    for (final url in urls) {
      expect(originalPosterUrl(url), url, reason: url);
    }
  });
}
