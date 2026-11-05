import 'dart:typed_data';

import '../sources/directory_sort.dart';
import '../sources/media_kind.dart';
import '../sources/source.dart';

export '../sources/media_kind.dart';

/// Display-oriented facts prepared by a metadata worker. Missing data is null,
/// never a fabricated zero. Dimensions should already account for orientation.
class AlbumFileMetadata {
  final int? capturedAt, width, height, durationMilliseconds;
  const AlbumFileMetadata({
    this.capturedAt,
    this.width,
    this.height,
    this.durationMilliseconds,
  });
}

class AlbumOptions {
  static const _sortFields = {'name', 'modified', 'captured', 'size', 'type'};
  final Set<MediaKind> kinds;

  /// Empty retains the default media view; '*' explicitly includes all files.
  /// Other values are exact extensions, 'folder', or 'file' (no extension).
  final Set<String> types;
  final Set<String> includeExtensions, excludeExtensions;
  final String query, sortField, dateField, orientation;
  final bool descending, groupPhotos, showDirectories, hideHiddenFiles;
  final bool includeAudio, unknownDatesOnly;
  final int? minSize, maxSize, dateFrom, dateTo;
  final int? minWidth, minHeight, maxWidth, maxHeight;
  final int? minDurationMilliseconds, maxDurationMilliseconds;

  AlbumOptions({
    Iterable<MediaKind> kinds = const [],
    Iterable<String> types = const [],
    Iterable<String> includeExtensions = const [],
    Iterable<String> excludeExtensions = const [],
    this.query = '',
    String sortField = 'name',
    String dateField = 'captured',
    String orientation = 'any',
    this.descending = false,
    this.groupPhotos = true,
    this.showDirectories = true,
    this.hideHiddenFiles = true,
    this.includeAudio = false,
    this.unknownDatesOnly = false,
    this.minSize,
    this.maxSize,
    this.dateFrom,
    this.dateTo,
    this.minWidth,
    this.minHeight,
    this.maxWidth,
    this.maxHeight,
    this.minDurationMilliseconds,
    this.maxDurationMilliseconds,
  }) : types = Set.unmodifiable(
         types
             .map((type) => type.trim().toLowerCase())
             .map(
               (type) => const {'*', 'folder', 'file'}.contains(type)
                   ? type
                   : normalizeMediaExtension(type),
             )
             .where((type) => type.isNotEmpty),
       ),
       kinds = Set.unmodifiable(kinds),
       includeExtensions = _extensions(includeExtensions),
       excludeExtensions = _extensions(excludeExtensions),
       sortField = _sortFields.contains(sortField) ? sortField : 'name',
       dateField = dateField == 'captured' ? 'captured' : 'modified',
       orientation =
           const {
             'any',
             'landscape',
             'portrait',
             'square',
           }.contains(orientation)
           ? orientation
           : 'any';

  static Set<String> _extensions(Iterable<String> values) => Set.unmodifiable(
    values.map(normalizeMediaExtension).where((value) => value.isNotEmpty),
  );

  factory AlbumOptions.fromJson(dynamic value) {
    final map = value is Map ? value : const {};
    Iterable<String> strings(String key) =>
        map[key] is List ? (map[key] as List).whereType<String>() : const [];
    int? number(String key) => map[key] is num && (map[key] as num).isFinite
        ? (map[key] as num).toInt()
        : null;
    String string(String key, String fallback) =>
        map[key] is String ? map[key] as String : fallback;
    final requestedSort = string('sortField', 'name');
    final sortField = _sortFields.contains(requestedSort)
        ? requestedSort
        : 'name';
    return AlbumOptions(
      types: strings('types'),
      kinds: strings('kinds')
          .map(
            (name) =>
                MediaKind.values.where((kind) => kind.name == name).firstOrNull,
          )
          .whereType<MediaKind>(),
      includeExtensions: strings('includeExtensions'),
      excludeExtensions: strings('excludeExtensions'),
      query: string('query', ''),
      sortField: sortField,
      dateField: string('dateField', 'captured'),
      orientation: string('orientation', 'any'),
      descending: map['descending'] is bool
          ? map['descending'] == true
          : sortField != 'name',
      groupPhotos: map['groupPhotos'] != false,
      showDirectories: map['showDirectories'] != false,
      hideHiddenFiles: map['hideHiddenFiles'] != false,
      includeAudio: map['includeAudio'] == true,
      unknownDatesOnly: map['unknownDatesOnly'] == true,
      minSize: number('minSize'),
      maxSize: number('maxSize'),
      dateFrom: number('dateFrom'),
      dateTo: number('dateTo'),
      minWidth: number('minWidth'),
      minHeight: number('minHeight'),
      maxWidth: number('maxWidth'),
      maxHeight: number('maxHeight'),
      minDurationMilliseconds: number('minDurationMilliseconds'),
      maxDurationMilliseconds: number('maxDurationMilliseconds'),
    );
  }

  Map<String, dynamic> toJson() => {
    'types': types.toList(),
    'kinds': [for (final kind in kinds) kind.name],
    'includeExtensions': includeExtensions.toList(),
    'excludeExtensions': excludeExtensions.toList(),
    'query': query,
    'sortField': sortField,
    'dateField': dateField,
    'orientation': orientation,
    'descending': descending,
    'groupPhotos': groupPhotos,
    'showDirectories': showDirectories,
    'hideHiddenFiles': hideHiddenFiles,
    'includeAudio': includeAudio,
    'unknownDatesOnly': unknownDatesOnly,
    'minSize': minSize,
    'maxSize': maxSize,
    'dateFrom': dateFrom,
    'dateTo': dateTo,
    'minWidth': minWidth,
    'minHeight': minHeight,
    'maxWidth': maxWidth,
    'maxHeight': maxHeight,
    'minDurationMilliseconds': minDurationMilliseconds,
    'maxDurationMilliseconds': maxDurationMilliseconds,
  };

  AlbumOptions copyWith({
    Iterable<String>? types,
    Iterable<MediaKind>? kinds,
    Iterable<String>? includeExtensions,
    Iterable<String>? excludeExtensions,
    String? query,
    String? sortField,
    String? dateField,
    String? orientation,
    bool? descending,
    bool? groupPhotos,
    bool? showDirectories,
    bool? hideHiddenFiles,
    bool? includeAudio,
    bool? unknownDatesOnly,
    Object? minSize = _keep,
    Object? maxSize = _keep,
    Object? dateFrom = _keep,
    Object? dateTo = _keep,
    Object? minWidth = _keep,
    Object? minHeight = _keep,
    Object? maxWidth = _keep,
    Object? maxHeight = _keep,
    Object? minDurationMilliseconds = _keep,
    Object? maxDurationMilliseconds = _keep,
  }) => AlbumOptions(
    types: types ?? this.types,
    kinds: kinds ?? this.kinds,
    includeExtensions: includeExtensions ?? this.includeExtensions,
    excludeExtensions: excludeExtensions ?? this.excludeExtensions,
    query: query ?? this.query,
    sortField: sortField ?? this.sortField,
    dateField: dateField ?? this.dateField,
    orientation: orientation ?? this.orientation,
    descending: descending ?? this.descending,
    groupPhotos: groupPhotos ?? this.groupPhotos,
    showDirectories: showDirectories ?? this.showDirectories,
    hideHiddenFiles: hideHiddenFiles ?? this.hideHiddenFiles,
    includeAudio: includeAudio ?? this.includeAudio,
    unknownDatesOnly: unknownDatesOnly ?? this.unknownDatesOnly,
    minSize: identical(minSize, _keep) ? this.minSize : minSize as int?,
    maxSize: identical(maxSize, _keep) ? this.maxSize : maxSize as int?,
    dateFrom: identical(dateFrom, _keep) ? this.dateFrom : dateFrom as int?,
    dateTo: identical(dateTo, _keep) ? this.dateTo : dateTo as int?,
    minWidth: identical(minWidth, _keep) ? this.minWidth : minWidth as int?,
    minHeight: identical(minHeight, _keep) ? this.minHeight : minHeight as int?,
    maxWidth: identical(maxWidth, _keep) ? this.maxWidth : maxWidth as int?,
    maxHeight: identical(maxHeight, _keep) ? this.maxHeight : maxHeight as int?,
    minDurationMilliseconds: identical(minDurationMilliseconds, _keep)
        ? this.minDurationMilliseconds
        : minDurationMilliseconds as int?,
    maxDurationMilliseconds: identical(maxDurationMilliseconds, _keep)
        ? this.maxDurationMilliseconds
        : maxDurationMilliseconds as int?,
  );
}

const _keep = Object();

/// One visible tile. [members] contains only files satisfying every active
/// filter; [allMembers] is for the explicit original-files details view.
class AlbumItem {
  final String id, name;
  final MediaKind kind;
  final List<SourceEntry> members, allMembers;
  final SourceEntry preferred;
  final int? capturedAt;

  AlbumItem({
    required this.id,
    required this.name,
    required this.kind,
    required Iterable<SourceEntry> members,
    required Iterable<SourceEntry> allMembers,
    required this.preferred,
    this.capturedAt,
  }) : members = List.unmodifiable(members),
       allMembers = List.unmodifiable(allMembers);

  bool get isDirectory => kind == MediaKind.folder;
  bool get isPhoto => kind == MediaKind.image || kind == MediaKind.raw;
  bool get isVideo => kind == MediaKind.video;
  bool get isAudio => kind == MediaKind.audio;
  bool get isGroup => isPhoto && allMembers.length > 1;

  /// A shared timeline for photos and videos. The source modification time is
  /// a sorting fallback only; it never becomes a capture fact or filter value.
  int? get timelineAt =>
      capturedAt ?? (preferred.modified > 0 ? preferred.modified : null);
}

class AlbumSnapshot {
  final List<AlbumItem> items;
  final Map<String, int?> timelineById;
  final AlbumWallSections wallSections;
  final Map<String, int> indexById;
  final Map<String, int> indexByPath;
  final List<SourceEntry> metadataEntries, audioEntries;
  final Map<String, int> audioIndexByPath;
  final List<String> availableExtensions;
  final List<String> availableTypes;
  final Set<String> defaultTypes;
  final Map<int, int> previousMediaIndex, nextMediaIndex;
  final int matchedFileCount, pendingMetadataCount, totalFileCount;
  final int unavailableMetadataCount;

  AlbumSnapshot({
    required Iterable<AlbumItem> items,
    required Iterable<String> availableExtensions,
    required this.matchedFileCount,
    required this.pendingMetadataCount,
    required this.totalFileCount,
    String? groupingDateField,
    Iterable<String> availableTypes = const [],
    Iterable<String> defaultTypes = const [],
    this.unavailableMetadataCount = 0,
    Iterable<SourceEntry> metadataEntries = const [],
    Map<String, int?>? timelineById,
  }) : wallSections = AlbumWallSections.prepare(
         items,
         dateField: groupingDateField,
         timelineById: timelineById,
       ),
       timelineById = Map.unmodifiable(
         timelineById ?? {for (final item in items) item.id: item.timelineAt},
       ),
       previousMediaIndex = _mediaNeighbors(items, previous: true),
       nextMediaIndex = _mediaNeighbors(items, previous: false),
       availableTypes = List.unmodifiable(availableTypes),
       defaultTypes = Set.unmodifiable(defaultTypes),
       items = List.unmodifiable(items),
       metadataEntries = List.unmodifiable(metadataEntries),
       audioIndexByPath = Map.unmodifiable({
         for (final (index, item)
             in items.where((item) => item.isAudio).indexed)
           item.preferred.path: index,
       }),
       audioEntries = List.unmodifiable([
         for (final item in items)
           if (item.isAudio) item.preferred,
       ]),
       indexById = Map.unmodifiable({
         for (final (index, item) in items.indexed) item.id: index,
       }),
       indexByPath = Map.unmodifiable({
         for (final (index, item) in items.indexed)
           for (final member in item.members) member.path: index,
       }),
       availableExtensions = List.unmodifiable(availableExtensions);

  static final empty = AlbumSnapshot(
    items: const [],
    availableExtensions: const [],
    matchedFileCount: 0,
    pendingMetadataCount: 0,
    totalFileCount: 0,
  );
}

/// Date runs and row offsets are prepared with the catalog in its worker.
/// The wall performs only bounded lookups while building or scrolling.
class AlbumWallSection {
  final int itemStart, itemEnd, childStart, headersBefore;
  final DateTime? day;
  final List<int> rowsBefore;
  const AlbumWallSection({
    required this.itemStart,
    required this.itemEnd,
    required this.childStart,
    required this.headersBefore,
    required this.day,
    required this.rowsBefore,
  });
  bool get hasHeader => day != null;
  int get childCount => itemEnd - itemStart + (hasHeader ? 1 : 0);
}

class AlbumWallSections {
  final List<AlbumWallSection> sections;
  final List<int> childByItem, totalRows;
  final int headerCount;
  const AlbumWallSections._(
    this.sections,
    this.childByItem,
    this.totalRows,
    this.headerCount,
  );
  int get childCount => childByItem.length + headerCount;

  factory AlbumWallSections.prepare(
    Iterable<AlbumItem> items, {
    String? dateField,
    Map<String, int?>? timelineById,
  }) {
    final entries = items is List<AlbumItem> ? items : items.toList();
    final sections = <AlbumWallSection>[];
    final children = <int>[];
    final rows = List<int>.filled(24, 0);
    var headers = 0, start = 0;
    while (start < entries.length) {
      DateTime? dayOf(AlbumItem item) {
        if (item.isDirectory || dateField == null) return null;
        final milliseconds = dateField == 'modified'
            ? (item.preferred.modified > 0 ? item.preferred.modified : null)
            : timelineById?.containsKey(item.id) == true
            ? timelineById![item.id]
            : item.timelineAt;
        if (milliseconds == null) return null;
        final date = DateTime.fromMillisecondsSinceEpoch(milliseconds);
        return DateTime(date.year, date.month, date.day);
      }

      final day = dayOf(entries[start]);
      var end = start + 1;
      while (end < entries.length && dayOf(entries[end]) == day) {
        end++;
      }
      sections.add(
        AlbumWallSection(
          itemStart: start,
          itemEnd: end,
          childStart: start + headers,
          headersBefore: headers,
          day: day,
          rowsBefore: Uint32List.fromList(rows).asUnmodifiableView(),
        ),
      );
      if (day != null) headers++;
      for (var index = start; index < end; index++) {
        children.add(index + headers);
      }
      for (var columns = 1; columns <= rows.length; columns++) {
        rows[columns - 1] += (end - start + columns - 1) ~/ columns;
      }
      start = end;
    }
    return AlbumWallSections._(
      List.unmodifiable(sections),
      Uint32List.fromList(children).asUnmodifiableView(),
      List.unmodifiable(rows),
      headers,
    );
  }
}

Map<int, int> _mediaNeighbors(
  Iterable<AlbumItem> items, {
  required bool previous,
}) {
  final result = <int, int>{};
  int? last;
  for (final (index, item) in items.indexed) {
    if (!item.isPhoto && !item.isVideo && !item.isAudio) continue;
    if (last != null) result[previous ? index : last] = previous ? last : index;
    last = index;
  }
  return Map.unmodifiable(result);
}

/// Prepared once per directory revision, and retained only in the worker.
/// Do not construct/filter this index in build or on the UI isolate.
class AlbumIndex {
  final List<_AlbumGroup> _groups;
  final Map<String, AlbumFileMetadata> _metadata;
  AlbumIndex._(this._groups, this._metadata);

  factory AlbumIndex(
    List<SourceEntry> entries, {
    required String sourceId,
    required String directory,
    Map<String, AlbumFileMetadata> metadata = const {},
    bool caseSensitive = true,
  }) {
    final groups = <String, _AlbumGroup>{};
    for (final entry in entries) {
      final kind = entry.directory ? MediaKind.folder : mediaKindOf(entry.name);
      final extension = mediaExtension(entry.name);
      final photo = kind == MediaKind.image || kind == MediaKind.raw;
      final stem = photo
          ? entry.name.substring(0, entry.name.length - extension.length)
          : entry.name;
      // Length prefixes avoid collisions even for legal names containing a
      // delimiter. Keep actual paths and Unicode untouched.
      final separator = entry.path.lastIndexOf(RegExp(r'[/\\]'));
      final parent = separator < 0
          ? directory
          : entry.path.substring(0, separator);
      final nameKey = caseSensitive ? stem : stem.toLowerCase();
      final pathKey = caseSensitive ? entry.path : entry.path.toLowerCase();
      final parentKey = caseSensitive ? parent : parent.toLowerCase();
      final id = photo
          ? _identity('photo', [sourceId, parentKey, nameKey])
          : _identity(kind.name, [sourceId, pathKey]);
      final group = groups.putIfAbsent(
        id,
        () => _AlbumGroup(id, photo ? MediaKind.image : kind, stem),
      );
      // A duplicated listing entry must not become a duplicated original.
      group.entries.putIfAbsent(entry.path, () => entry);
    }
    final result = groups.values.toList();
    for (final group in result) {
      group.prepare(metadata);
    }
    return AlbumIndex._(result, Map.unmodifiable(metadata));
  }

  AlbumSnapshot filter(
    AlbumOptions options, {
    Map<String, int?> timelineById = const {},
  }) {
    final visible = <AlbumItem>[];
    final metadataEntries = <SourceEntry>[];
    final extensions = <String>{};
    final types = <String>{}, defaults = <String>{};
    final terms = options.query
        .toLowerCase()
        .trim()
        .split(RegExp(r'\s+'))
        .where((term) => term.isNotEmpty)
        .toList();
    var matchedCount = 0,
        pendingCount = 0,
        unavailableCount = 0,
        totalCount = 0;
    for (final group in _groups) {
      final eligible = [
        for (final entry in group.ordered)
          if (!options.hideHiddenFiles || !isHiddenEntry(entry)) entry,
      ];
      if (eligible.isEmpty) continue;
      if (group.kind == MediaKind.folder) {
        final entry = eligible.first;
        types.add('folder');
        if (options.showDirectories) defaults.add('folder');
        if (options.showDirectories &&
            (options.types.isEmpty ||
                options.types.contains('*') ||
                options.types.contains('folder')) &&
            terms.every(entry.name.toLowerCase().contains)) {
          visible.add(
            AlbumItem(
              id: group.id,
              name: entry.name,
              kind: MediaKind.folder,
              members: [entry],
              allMembers: [entry],
              preferred: entry,
            ),
          );
        }
        continue;
      }
      final matching = <SourceEntry>[];
      for (final entry in eligible) {
        final kind = mediaKindOf(entry.name);
        final extension = mediaExtension(entry.name);
        final type = extension.isEmpty ? 'file' : extension;
        types.add(type);
        if ((options.kinds.isEmpty
                ? kind == MediaKind.image ||
                      kind == MediaKind.raw ||
                      kind == MediaKind.video ||
                      kind == MediaKind.audio && options.includeAudio
                : options.kinds.contains(kind)) &&
            (options.includeExtensions.isEmpty ||
                options.includeExtensions.contains(extension)) &&
            !options.excludeExtensions.contains(extension)) {
          defaults.add(type);
        }
        if (options.types.isEmpty &&
            (kind == MediaKind.other || kind == MediaKind.sidecar)) {
          continue;
        }
        final photo = kind == MediaKind.image || kind == MediaKind.raw;
        if (kind == MediaKind.audio &&
            options.types.isEmpty &&
            !options.includeAudio &&
            !options.kinds.contains(MediaKind.audio)) {
          continue;
        }
        totalCount++;
        extensions.add(mediaExtension(entry.name));
        final match = _match(entry, _metadata[entry.path], options, terms);
        if (photo && _metadata[entry.path] == null && match != _Match.no) {
          metadataEntries.add(entry);
        }
        if (match == _Match.pending) {
          if (photo) {
            pendingCount++;
          } else {
            // The current metadata provider reads photos only. Do not offer a
            // retry that cannot complete for an audio/video-only filter.
            unavailableCount++;
          }
        }
        if (match == _Match.yes) matching.add(entry);
      }
      if (matching.isEmpty) continue;
      matchedCount += matching.length;
      if (group.kind == MediaKind.image && !options.groupPhotos) {
        for (final entry in matching) {
          visible.add(
            AlbumItem(
              id: _identity('file', [group.id, entry.path]),
              name: entry.name,
              kind: mediaKindOf(entry.name),
              members: [entry],
              allMembers: [entry],
              preferred: entry,
              capturedAt: _metadata[entry.path]?.capturedAt,
            ),
          );
        }
      } else {
        visible.add(
          AlbumItem(
            id: group.id,
            name: group.name,
            kind: group.kind,
            members: matching,
            allMembers: eligible,
            preferred: matching.first,
            capturedAt: group.capturedAt,
          ),
        );
      }
    }
    // Tokenize each name once rather than doing regex work per comparison.
    final names = {for (final item in visible) item.id: _NameKey(item.name)};
    // Freeze both the chronology and its date dividers for an active browsing
    // session. New facts remain available for filters, details and a later sort.
    final timeline = <String, int?>{
      for (final item in visible)
        item.id: timelineById.containsKey(item.id)
            ? timelineById[item.id]
            : item.timelineAt,
    };
    visible.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      int value;
      switch (options.sortField) {
        case 'modified':
          value = a.preferred.modified.compareTo(b.preferred.modified);
        case 'captured':
          final at = timeline[a.id], bt = timeline[b.id];
          // Files missing both capture and source dates stay last either way.
          if (at == null && bt != null) return 1;
          if (at != null && bt == null) return -1;
          value = (at ?? 0).compareTo(bt ?? 0);
        case 'size':
          value = a.preferred.size.compareTo(b.preferred.size);
        case 'type':
          value = mediaExtension(a.preferred.name)
              .compareTo(mediaExtension(b.preferred.name));
        default:
          value = names[a.id]!.compareTo(names[b.id]!);
      }
      if (value != 0) return options.descending ? -value : value;
      value = names[a.id]!.compareTo(names[b.id]!);
      return value != 0 ? value : a.id.compareTo(b.id);
    });
    return AlbumSnapshot(
      metadataEntries: metadataEntries,
      timelineById: timeline,
      items: visible,
      groupingDateField:
          const {'captured', 'modified'}.contains(options.sortField)
          ? options.sortField
          : null,
      availableTypes: types.toList()
        ..sort(
          (a, b) => a == b
              ? 0
              : a == 'folder'
              ? -1
              : b == 'folder'
              ? 1
              : a.compareTo(b),
        ),
      defaultTypes: defaults,
      availableExtensions: extensions.toList()..sort(),
      matchedFileCount: matchedCount,
      pendingMetadataCount: pendingCount,
      unavailableMetadataCount: unavailableCount,
      totalFileCount: totalCount,
    );
  }
}

enum _Match { yes, no, pending }

_Match _match(
  SourceEntry entry,
  AlbumFileMetadata? metadata,
  AlbumOptions options,
  List<String> terms,
) {
  final kind = mediaKindOf(entry.name);
  final type = mediaExtension(entry.name).isEmpty
      ? 'file'
      : mediaExtension(entry.name);
  if (options.types.isNotEmpty &&
      !options.types.contains('*') &&
      !options.types.contains(type)) {
    return _Match.no;
  }
  if (options.kinds.isNotEmpty && !options.kinds.contains(kind)) {
    return _Match.no;
  }
  final extension = mediaExtension(entry.name);
  if (options.excludeExtensions.contains(extension) ||
      options.includeExtensions.isNotEmpty &&
          !options.includeExtensions.contains(extension) ||
      !terms.every(entry.name.toLowerCase().contains)) {
    return _Match.no;
  }
  if (options.minSize != null && entry.size < options.minSize! ||
      options.maxSize != null && entry.size > options.maxSize!) {
    return _Match.no;
  }
  var pending = false;
  final date = options.dateField == 'captured'
      ? metadata?.capturedAt
      : entry.modified > 0
      ? entry.modified
      : null;
  if (options.unknownDatesOnly) {
    if (date != null) return _Match.no;
    if (options.dateField == 'captured' && metadata == null) pending = true;
  } else if (options.dateFrom != null || options.dateTo != null) {
    if (date == null) {
      if (options.dateField == 'modified' || metadata != null) return _Match.no;
      pending = true;
    } else if (options.dateFrom != null && date < options.dateFrom! ||
        options.dateTo != null && date > options.dateTo!) {
      return _Match.no;
    }
  }
  final dimensions =
      options.minWidth != null ||
      options.maxWidth != null ||
      options.minHeight != null ||
      options.maxHeight != null ||
      options.orientation != 'any';
  if (dimensions) {
    if (kind != MediaKind.image && kind != MediaKind.raw) return _Match.no;
    final width = metadata?.width, height = metadata?.height;
    if (width == null || height == null || width <= 0 || height <= 0) {
      if (metadata != null) return _Match.no;
      pending = true;
    } else if (options.minWidth != null && width < options.minWidth! ||
        options.maxWidth != null && width > options.maxWidth! ||
        options.minHeight != null && height < options.minHeight! ||
        options.maxHeight != null && height > options.maxHeight! ||
        options.orientation == 'landscape' && width <= height ||
        options.orientation == 'portrait' && height <= width ||
        options.orientation == 'square' && width != height) {
      return _Match.no;
    }
  }
  if (options.minDurationMilliseconds != null ||
      options.maxDurationMilliseconds != null) {
    if (kind != MediaKind.video && kind != MediaKind.audio) return _Match.no;
    final duration = metadata?.durationMilliseconds;
    if (duration == null || duration < 0) {
      if (metadata != null) return _Match.no;
      pending = true;
    } else if (options.minDurationMilliseconds != null &&
            duration < options.minDurationMilliseconds! ||
        options.maxDurationMilliseconds != null &&
            duration > options.maxDurationMilliseconds!) {
      return _Match.no;
    }
  }
  return pending ? _Match.pending : _Match.yes;
}

String _identity(String kind, List<String> fields) =>
    '$kind:${fields.map((field) => '${field.length}:$field').join()}';

class _AlbumGroup {
  final String id, name;
  final MediaKind kind;
  final entries = <String, SourceEntry>{};
  late final List<SourceEntry> ordered;
  int? capturedAt;
  _AlbumGroup(this.id, this.kind, this.name);

  void prepare(Map<String, AlbumFileMetadata> metadata) {
    ordered = entries.values.toList()
      ..sort((a, b) {
        final rank = _previewRank(a.name).compareTo(_previewRank(b.name));
        return rank != 0 ? rank : a.path.compareTo(b.path);
      });
    for (final entry in ordered) {
      final date = metadata[entry.path]?.capturedAt;
      if (date != null && date > 0) {
        capturedAt = date;
        break;
      }
    }
  }
}

int _previewRank(String name) {
  final extension = mediaExtension(name);
  if (extension == '.jpg') return 0;
  if (extension == '.jpeg' || extension == '.jpe' || extension == '.jfif') {
    return 1;
  }
  if (const {'.png', '.webp', '.gif', '.bmp'}.contains(extension)) return 2;
  return isRawImageFile(name) ? 4 : 3;
}

class _NameKey {
  final String original;
  final List<({String text, String? number})> parts;
  _NameKey(this.original)
    : parts = RegExp(r'\d+|\D+').allMatches(original.toLowerCase()).map((m) {
        final text = m[0]!;
        final first = text.codeUnitAt(0);
        final numeric = first >= 48 && first <= 57;
        return (
          text: text,
          number: numeric ? text.replaceFirst(RegExp(r'^0+'), '') : null,
        );
      }).toList();
  int compareTo(_NameKey other) {
    for (var i = 0; i < parts.length && i < other.parts.length; i++) {
      final a = parts[i], b = other.parts[i];
      final x = a.number, y = b.number;
      final value = x != null && y != null
          ? x.length != y.length
                ? x.length.compareTo(y.length)
                : x.compareTo(y)
          : a.text.compareTo(b.text);
      if (value != 0) return value;
    }
    final length = parts.length.compareTo(other.parts.length);
    return length != 0 ? length : original.compareTo(other.original);
  }
}
