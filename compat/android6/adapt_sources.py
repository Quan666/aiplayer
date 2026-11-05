"""Adapt a disposable source copy to Flutter 3.32 without changing mainline.

This is intentionally a small, checked compatibility patch, not a Dart parser.
If the source around a patch changes, fail before writing anything so a release
cannot silently lose cache bounds, reorder semantics, or phone pairing.
"""

from __future__ import annotations

from pathlib import Path
import re


_REPOSITORY = Path(__file__).resolve().parents[2]
_VIEWPORT = re.compile(
    r"scrollCacheExtent:\s*const ScrollCacheExtent\.viewport\(\s*"
    r"(?P<factor>(?:\d+(?:\.\d*)?|\.\d+))\s*,?\s*\)"
)
_PIXELS = re.compile(
    r"scrollCacheExtent:\s*const ScrollCacheExtent\.pixels\(\s*"
    r"(?P<pixels>(?:\d+(?:\.\d*)?|\.\d+))\s*,?\s*\)"
)
_UNSUPPORTED = re.compile(
    r"\b(?:ScrollCacheExtent|scrollCacheExtent|onReorderItem|QrPayload|TickerModeData|getValuesNotifier|translateByDouble|scaleByDouble)\b"
    r"|TickerMode\.valuesOf\b"
    r"|QrErrorCorrectLevel\.(?:low|medium|quartile|high)\b"
)

# Each entry follows source order, with an anchor local to its scroll view.
# LayoutBuilder constraints preserve the actual viewport when available;
# otherwise use a finite screen-sized bound, never an unbounded cache.
_VIEWPORTS = {
    "client/lib/ui/album_wall.dart": [
        ("key: const ValueKey('album-wall')", "1", "constraints.maxHeight"),
    ],
    "client/lib/ui/library_page.dart": [
        ("key: const PageStorageKey('library-scroll')", ".75", "MediaQuery.sizeOf(context).height"),
        ("key: const PageStorageKey('library-history-grid')", ".75", "constraints.maxHeight"),
        ("key: const PageStorageKey('library-continue-scroll')", ".75", "constraints.maxWidth"),
        ("key: const ValueKey('series-details-list')", ".75", "MediaQuery.sizeOf(context).height"),
    ],
    "client/lib/ui/sources_page.dart": [
        ("key: const PageStorageKey('sources-scroll')", ".75", "MediaQuery.sizeOf(context).height"),
        ("key: scrollKey", ".75", "constraints.maxHeight"),
        ("controller: scroll", ".75", "MediaQuery.sizeOf(context).height"),
    ],
}

# Dart 3.9 made a private field formal expose a public named argument. Spell
# out those argument/initializer pairs for Dart 3.8, keeping all call sites and
# the private fields unchanged. Positional private field formals remain valid.
_PRIVATE_FORMALS = {
    "client/lib/core/third_party_network.dart": [
        (
            "ThirdPartyNetworkPolicy({this._enabled = true});",
            "ThirdPartyNetworkPolicy({bool enabled = true}) : _enabled = enabled;",
        ),
    ],
    "client/lib/data/media_ai_recognition.dart": [
        (
            "    this._folderAnalyzer,\n  }) : transport = transport ?? IoSubtitleAiTransport();",
            "    FolderFilenameAnalyzer? folderAnalyzer,\n"
            "  }) : _folderAnalyzer = folderAnalyzer,\n"
            "       transport = transport ?? IoSubtitleAiTransport();",
        ),
    ],
    "client/lib/data/media_title_translation.dart": [
        (
            "MediaTitleTranslations(this.store, {required this.settings, this._transport});",
            "MediaTitleTranslations(this.store, {required this.settings, SubtitleAiTransport? transport})\n"
            "    : _transport = transport;",
        ),
    ],
    "client/lib/data/library_catalog.dart": [
        (
            "    this._listedVideoCount,\n    this._membershipComplete,\n"
            "  }) : _preparedEpisodeCount = episodeCount;",
            "    int? listedVideoCount,\n    bool? membershipComplete,\n"
            "  }) : _listedVideoCount = listedVideoCount,\n"
            "       _membershipComplete = membershipComplete,\n"
            "       _preparedEpisodeCount = episodeCount;",
        ),
    ],
    "client/lib/data/app_model_metadata_tasks.dart": [
        (
            "    this._selection,\n    this._selectionSeason = '',\n"
            "    this._identity,\n    this._parentTask,\n  });",
            "    Map<String, dynamic>? selection,\n    String selectionSeason = '',\n"
            "    AiMediaIdentity? identity,\n    MetadataTask? parentTask,\n"
            "  }) : _selection = selection,\n"
            "       _selectionSeason = selectionSeason,\n"
            "       _identity = identity,\n       _parentTask = parentTask;",
        ),
    ],
    "client/lib/data/offline_downloads.dart": [
        (
            "    this._active = true,\n  });",
            "    bool active = true,\n  }) : _active = active;",
        ),
    ],
    "client/lib/playback/music_controller.dart": [
        ("    this._backgrounded = false,", "    bool backgrounded = false,"),
        (
            "  }) : queue = MusicQueue(entries.length, index: initialIndex),",
            "  }) : _backgrounded = backgrounded,\n"
            "       queue = MusicQueue(entries.length, index: initialIndex),",
        ),
    ],
    "client/lib/danmaku/layout.dart": [
        (
            "    this._retained = const [],\n  }) : _items = prepared,",
            "    List<ScheduledComment> retained = const [],\n"
            "  }) : _retained = retained,\n       _items = prepared,",
        ),
        (
            "    this._retained = const [],\n  }) : _items = const [],",
            "    List<ScheduledComment> retained = const [],\n"
            "  }) : _retained = retained,\n       _items = const [],",
        ),
    ],
}


def _replace_count(source: str, old: str, new: str, path: str, expected: int = 1) -> str:
    count = source.count(old)
    if count != expected:
        raise RuntimeError(f"Android 6 adaptation drift in {path}: expected {expected} {old!r}, found {count}")
    return source.replace(old, new)


def _viewport_caches(source: str, path: str) -> str:
    specifications = _VIEWPORTS[path]
    matches = list(_VIEWPORT.finditer(source))
    if len(matches) != len(specifications):
        raise RuntimeError(
            f"Android 6 cache adaptation drift in {path}: "
            f"expected {len(specifications)} viewports, found {len(matches)}"
        )
    edits = []
    previous_end = 0
    for match, (anchor, factor, dimension) in zip(matches, specifications):
        prefix = source[previous_end:match.start()]
        if match["factor"] != factor or anchor not in prefix[-700:]:
            raise RuntimeError(f"Android 6 cache anchor changed in {path}: {anchor}")
        if "library-continue-scroll" in anchor and "scrollDirection: Axis.horizontal" not in prefix[-700:]:
            raise RuntimeError(f"Android 6 horizontal cache axis changed in {path}")
        # LayoutBuilder may receive an unbounded main axis in an embedding.
        # Fall back to one screen dimension instead of constructing infinity.
        if dimension.startswith("constraints."):
            axis = "width" if dimension.endswith("maxWidth") else "height"
            dimension = f"({dimension}.isFinite ? {dimension} : MediaQuery.sizeOf(context).{axis})"
        edits.append((match.start(), match.end(), f"cacheExtent: {dimension} * {factor}"))
        previous_end = match.end()
    for start, end, replacement in reversed(edits):
        source = source[:start] + replacement + source[end:]
    return source


def _remove_cache_import(source: str) -> str:
    source = re.sub(
        r"^import 'package:flutter/rendering\.dart' show ScrollCacheExtent;\n",
        "",
        source,
        flags=re.MULTILINE,
    )
    # AlbumWall also imports its custom sliver layout types from rendering.
    return re.sub(r"^\s*ScrollCacheExtent,\n", "", source, flags=re.MULTILINE)


def _call_end(source: str, start: int) -> int:
    """Return the closing parenthesis for a known expression without strings."""
    depth = 1
    for index in range(start, len(source)):
        char = source[index]
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return index
    raise RuntimeError("Unbalanced Android 6 compatibility expression")


def _adapt_general_apis(source: str, path: str) -> str:
    prefix = "TickerMode.valuesOf("
    while prefix in source:
        start = source.index(prefix)
        arguments = start + len(prefix)
        end = _call_end(source, arguments)
        if source[end + 1:end + 9] != ".enabled":
            raise RuntimeError(f"Android 6 ticker mode must read enabled in {path}")
        source = source[:start] + "TickerMode.of(" + source[arguments:end] + ")" + source[end + 9:]

    for method, old_method in (("translateByDouble", "translate"), ("scaleByDouble", "scale")):
        prefix = method + "("
        while prefix in source:
            start = source.index(prefix)
            arguments = start + len(prefix)
            end = _call_end(source, arguments)
            # Current matrix arguments contain arithmetic only, no nested calls
            # with commas. Refuse future non-affine / vector conversions.
            parts = [part.strip() for part in source[arguments:end].split(",") if part.strip()]
            if len(parts) != 4 or parts[3] not in {"1", "1.0"}:
                raise RuntimeError(f"Android 6 matrix conversion is not affine in {path}")
            # vector_math 2.1's dynamic first argument accepts double but throws
            # for an int, unlike the newer explicitly typed methods.
            replacement = f"{old_method}(({parts[0]}).toDouble(), {parts[1]}, {parts[2]})"
            source = source[:start] + replacement + source[end + 1:]

    if path == "client/lib/ui/player_theme.dart":
        old = "constraints: const BoxConstraints(maxWidth: 520),\n      child: PlayerGlass("
        if source.count(old) != 1:
            raise RuntimeError("Android 6 dialog width anchor changed")
        start = source.index(old)
        child_start = start + len(old)
        end = _call_end(source, child_start)
        # Keep Dialog's outer margins and bound its content to the same width.
        source = (
            source[:start]
            + "child: ConstrainedBox(\n        constraints: const BoxConstraints(maxWidth: 520),\n"
            + "        child: PlayerGlass("
            + source[child_start:end + 1]
            + ",\n      )"
            + source[end + 1:]
        )
    return source


def _initialize_loading_controller(source: str) -> str:
    path = "client/lib/ui/album_thumbnail.dart"
    controller = (
        "  late final _animation = AnimationController(\n"
        "    vsync: this,\n    duration: const Duration(milliseconds: 1000),\n  );"
    )
    source = _replace_count(source, controller, "  late final AnimationController _animation;", path)
    # Flutter 3.32 reads the ticker ancestor during controller construction.
    # A loading placeholder can disappear before its lazy controller was read;
    # initializing here prevents dispose() from first constructing a ticker on
    # a deactivated element. Construction alone schedules no animation frames.
    return _replace_count(
        source,
        "    super.initState();\n    ArtworkLifecycle.instance.addListener(_activityChanged);",
        "    super.initState();\n"
        "    _animation = AnimationController(\n      vsync: this,\n"
        "      duration: const Duration(milliseconds: 1000),\n    );\n"
        "    ArtworkLifecycle.instance.addListener(_activityChanged);",
        path,
    )


def adapt_sources(root: Path) -> list[str]:
    """Patch ``root/client`` in a staging tree and return changed relative paths.

    Validate the entire patch first; errors leave all input files untouched.
    The real repository and files linked outside staging are never writable.
    """
    root = root.resolve(strict=True)
    if root == _REPOSITORY:
        raise RuntimeError("Android 6 source adaptation requires a disposable staging copy")
    sources: dict[str, str] = {}
    for directory in ("client/lib", "client/test", "client/integration_test"):
        for file in sorted((root / directory).rglob("*.dart")):
            if not file.resolve().is_relative_to(root):
                raise RuntimeError(f"Android 6 staging source escapes its root: {file}")
            sources[file.relative_to(root).as_posix()] = file.read_text(encoding="utf-8")
    required = {
        *_VIEWPORTS,
        *_PRIVATE_FORMALS,
        "client/lib/remote/remote_control_service.dart",
        "client/lib/ui/album_thumbnail.dart",
        "client/lib/ui/player_theme.dart",
    }
    if missing := required - sources.keys():
        raise RuntimeError(f"Android 6 staging source missing: {', '.join(sorted(missing))}")
    adapted = dict(sources)
    for path in _VIEWPORTS:
        adapted[path] = _viewport_caches(adapted[path], path)
    for path, patches in _PRIVATE_FORMALS.items():
        for old, new in patches:
            adapted[path] = _replace_count(adapted[path], old, new, path)

    path = "client/lib/ui/sources_page.dart"
    adapted[path] = _replace_count(
        adapted[path],
        "onReorderItem: (oldIndex, newIndex) {",
        "onReorder: (oldIndex, newIndex) {\n"
        "                    // Flutter 3.32 reports the insertion index before removal.\n"
        "                    if (oldIndex < newIndex) newIndex -= 1;",
        path,
    )
    path = "client/lib/remote/remote_control_service.dart"
    adapted[path] = _replace_count(
        adapted[path],
        "QrCode(\n        payload: QrPayload.fromString(url),\n"
        "        errorCorrectLevel: QrErrorCorrectLevel.medium,",
        "QrCode.fromData(\n        data: url,\n"
        "        errorCorrectLevel: QrErrorCorrectLevel.M,",
        path,
    )

    path = "client/lib/ui/album_thumbnail.dart"
    for old, new, count in (
        ("ValueListenable<TickerModeData>", "ValueListenable<bool>", 2),
        ("TickerMode.getValuesNotifier(context)", "TickerMode.getNotifier(context)", 2),
        ("_tickerMode?.value.enabled", "_tickerMode?.value", 3),
    ):
        adapted[path] = _replace_count(adapted[path], old, new, path, count)
    adapted[path] = _initialize_loading_controller(adapted[path])

    for path, source in adapted.items():
        source = _adapt_general_apis(source, path)
        source = _PIXELS.sub(lambda match: f"cacheExtent: {match['pixels']}", source)
        source = _remove_cache_import(source)
        if match := _UNSUPPORTED.search(source):
            raise RuntimeError(f"Unadapted Android 6 API in {path}: {match.group()}")
        adapted[path] = source

    changed = sorted(path for path, source in adapted.items() if source != sources[path])
    for path in changed:
        (root / path).write_text(adapted[path], encoding="utf-8")
    return changed
