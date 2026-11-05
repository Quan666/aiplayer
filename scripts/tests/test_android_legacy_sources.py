"""The Android 6 staging patch must preserve cache bounds and interaction."""

import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "legacy_sources", ROOT / "compat/android6/adapt_sources.py"
)
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)


class LegacySourcesTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.staging = Path(self.temporary.name)
        required = {
            *adapter._VIEWPORTS,
            *adapter._PRIVATE_FORMALS,
            "client/lib/remote/remote_control_service.dart",
            "client/lib/ui/album_thumbnail.dart",
            "client/lib/ui/player_theme.dart",
        }
        for relative in required:
            destination = self.staging / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, destination)

    def test_real_source_keeps_lazy_cache_axis_reorder_and_pairing(self):
        changed = adapter.adapt_sources(self.staging)
        self.assertEqual(len(changed), 14)
        library = (self.staging / "client/lib/ui/library_page.dart").read_text()
        carousel = library.split("key: const PageStorageKey('library-continue-scroll')", 1)[1][:500]
        self.assertIn("constraints.maxWidth.isFinite", carousel)
        self.assertIn("MediaQuery.sizeOf(context).width", carousel)
        self.assertNotIn("maxHeight", carousel)
        album = (self.staging / "client/lib/ui/album_wall.dart").read_text()
        self.assertIn("GridView.builder(", album)
        self.assertIn("constraints.maxHeight.isFinite", album)
        self.assertIn("SliverGridLayout", album)
        sources = (self.staging / "client/lib/ui/sources_page.dart").read_text()
        self.assertIn("if (oldIndex < newIndex) newIndex -= 1;", sources)
        self.assertLess(sources.index("newIndex -= 1;"), sources.index("if (oldIndex == newIndex) return;"))
        remote = (self.staging / "client/lib/remote/remote_control_service.dart").read_text()
        self.assertIn("QrCode.fromData(\n        data: url,", remote)
        self.assertIn("errorCorrectLevel: QrErrorCorrectLevel.M", remote)
        thumbnail = (self.staging / "client/lib/ui/album_thumbnail.dart").read_text()
        self.assertEqual(thumbnail.count("TickerMode.getNotifier(context)"), 2)
        self.assertIn("(_tickerMode?.value ?? false)", thumbnail)
        self.assertIn("_tickerMode?.value != true", thumbnail)
        self.assertIn("ArtworkLifecycle.instance.addListener(_retryActivity)", thumbnail)
        self.assertIn("late final AnimationController _animation;", thumbnail)
        self.assertIn("super.initState();\n    _animation = AnimationController(", thumbnail)

    def test_private_named_fields_keep_public_arguments_and_initial_values(self):
        adapter.adapt_sources(self.staging)
        task = (self.staging / "client/lib/data/app_model_metadata_tasks.dart").read_text()
        self.assertIn("String selectionSeason = ''", task)
        self.assertIn("_selectionSeason = selectionSeason", task)
        self.assertIn("this._records, {", task)
        music = (self.staging / "client/lib/playback/music_controller.dart").read_text()
        self.assertIn("bool backgrounded = false", music)
        self.assertIn("_backgrounded = backgrounded", music)
        danmaku = (self.staging / "client/lib/danmaku/layout.dart").read_text()
        original = (ROOT / "client/lib/danmaku/layout.dart").read_text()
        self.assertEqual(
            danmaku.count("List<ScheduledComment> retained = const []"),
            original.count("List<ScheduledComment> retained = const []") + 2,
        )
        self.assertEqual(danmaku.count("_retained = retained"), 2)

    def test_pixel_cache_tests_keep_exact_budget(self):
        target = self.staging / "client/test/cache_test.dart"
        target.parent.mkdir(parents=True)
        target.write_text(
            "import 'package:flutter/rendering.dart' show ScrollCacheExtent;\n"
            "ListView.builder(scrollCacheExtent: const ScrollCacheExtent.pixels(\n128,\n));\n"
            "ListView.builder(scrollCacheExtent: const ScrollCacheExtent.pixels(0));\n"
        )
        adapter.adapt_sources(self.staging)
        self.assertEqual(target.read_text(), "ListView.builder(cacheExtent: 128);\nListView.builder(cacheExtent: 0);\n")

    def test_ticker_mode_and_matrix_keep_boolean_and_double_semantics(self):
        source = (
            "TickerMode.valuesOf(tester.element(find.byType(LibraryPage))).enabled;\n"
            "matrix.scaleByDouble(2, 2, 1, 1);\n"
            "matrix.translateByDouble(center.dx * (1 - scale), center.dy, 0, 1);"
        )
        converted = adapter._adapt_general_apis(source, "test.dart")
        self.assertIn("TickerMode.of(tester.element(find.byType(LibraryPage)));", converted)
        self.assertIn("scale((2).toDouble(), 2, 1)", converted)
        self.assertIn("translate((center.dx * (1 - scale)).toDouble(), center.dy, 0)", converted)
        with self.assertRaisesRegex(RuntimeError, "not affine"):
            adapter._adapt_general_apis("matrix.scaleByDouble(2, 2, 1, .5)", "test.dart")

    def test_unknown_new_usage_fails_without_partial_writes(self):
        target = self.staging / "client/lib/new_page.dart"
        target.write_text("ListView(scrollCacheExtent: const ScrollCacheExtent.viewport(.5));")
        before = {str(p): p.read_bytes() for p in self.staging.rglob("*.dart")}
        with self.assertRaisesRegex(RuntimeError, "Unadapted Android 6 API"):
            adapter.adapt_sources(self.staging)
        self.assertEqual(before, {str(p): p.read_bytes() for p in self.staging.rglob("*.dart")})

    def test_moved_cache_anchor_fails_before_writing(self):
        target = self.staging / "client/lib/ui/library_page.dart"
        target.write_text(target.read_text().replace("library-continue-scroll", "different-carousel"))
        with self.assertRaisesRegex(RuntimeError, "cache anchor changed"):
            adapter.adapt_sources(self.staging)
        self.assertIn("ScrollCacheExtent", target.read_text())

    def test_mainline_and_linked_sources_are_never_modified(self):
        with self.assertRaisesRegex(RuntimeError, "disposable staging"):
            adapter.adapt_sources(ROOT)
        target = self.staging / "client/lib/external.dart"
        target.symlink_to(ROOT / "client/lib/main.dart")
        with self.assertRaisesRegex(RuntimeError, "escapes its root"):
            adapter.adapt_sources(self.staging)


if __name__ == "__main__":
    unittest.main()
