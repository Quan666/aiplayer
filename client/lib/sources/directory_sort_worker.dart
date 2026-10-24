import 'dart:async';
import 'dart:isolate';

import '../data/store.dart';
import 'directory_sort.dart';
import 'source.dart';

class DirectorySortCancelled implements Exception {
  const DirectorySortCancelled();
}

/// One worker per browser, with one running request and a bounded pending queue.
/// Search transfers the current folder's prepared records/titles once per data
/// revision, then reuses that index for subsequent query-only requests.
class DirectorySortWorker {
  final _queue = <_SortRequest>[];
  Isolate? _isolate;
  ReceivePort? _port;
  StreamIterator<dynamic>? _responses;
  SendPort? _requests;
  _SortRequest? _active;
  Object? _searchDataKey;
  bool _running = false, _closed = false;

  Future<List<SourceEntry>> sort(
    List<SourceEntry> entries,
    DirectorySort order, {
    required bool hideHiddenFiles,
  }) {
    if (_closed) return Future.error(const DirectorySortCancelled());
    final request = _SortRequest(entries, order, hideHiddenFiles);
    // A browser normally has one listing and at most four preview requests.
    // Navigation cancellation prevents obsolete folders accumulating behind it.
    if (_queue.length == 8) {
      _queue.removeAt(0).result.completeError(const DirectorySortCancelled());
    }
    _queue.add(request);
    unawaited(_drain());
    return request.result.future;
  }

  /// Search already prepared entries without changing their order or membership
  /// in the canonical listing used by directory reconciliation.
  Future<List<SourceEntry>> search(
    List<SourceEntry> entries,
    String query, {
    Map<String, SyncRecord> records = const {},
    Map<String, String> titles = const {},
  }) {
    if (_closed) return Future.error(const DirectorySortCancelled());
    cancelSearch();
    final request = _SortRequest.search(entries, query, records, titles);
    if (_queue.length == 8) {
      _queue.removeAt(0).result.completeError(const DirectorySortCancelled());
    }
    _queue.add(request);
    unawaited(_drain());
    return request.result.future;
  }

  void cancelSearch() {
    _queue.removeWhere((request) {
      if (request.query == null) return false;
      request.result.completeError(const DirectorySortCancelled());
      return true;
    });
  }

  void cancelPending() {
    for (final request in _queue) {
      request.result.completeError(const DirectorySortCancelled());
    }
    _queue.clear();
  }

  Future<void> _start() async {
    _port = ReceivePort();
    _responses = StreamIterator(_port!);
    final isolate = await Isolate.spawn(_sortDirectory, _port!.sendPort);
    if (_closed) {
      isolate.kill(priority: Isolate.immediate);
      throw const DirectorySortCancelled();
    }
    _isolate = isolate;
    if (!await _responses!.moveNext()) {
      throw const DirectorySortCancelled();
    }
    _requests = _responses!.current as SendPort;
  }

  Future<void> _drain() async {
    if (_running || _closed) return;
    _running = true;
    try {
      while (_queue.isNotEmpty && !_closed) {
        final request = _active = _queue.removeAt(0);
        try {
          if (_requests == null) await _start();
          if (_closed) break;
          final searchKey = (request.entries, request.records, request.titles);
          final reuseSearch =
              request.query != null && _searchDataKey == searchKey;
          if (request.query != null) _searchDataKey = searchKey;
          _requests!.send((
            reuseSearch ? null : request.entries,
            request.order?.field,
            request.order?.descending ?? false,
            request.order?.showSubtitles ?? false,
            request.hideHiddenFiles,
            request.query,
            reuseSearch ? const <String, SyncRecord>{} : request.records,
            reuseSearch ? const <String, String>{} : request.titles,
          ));
          if (!await _responses!.moveNext()) {
            throw const DirectorySortCancelled();
          }
          final response = _responses!.current as (List<SourceEntry>?, String?);
          if (request.result.isCompleted) continue;
          if (response.$2 != null) {
            request.result.completeError(StateError(response.$2!));
          } else {
            request.result.complete(response.$1!);
          }
        } catch (error, stack) {
          if (!request.result.isCompleted) {
            request.result.completeError(error, stack);
          }
        } finally {
          _active = null;
        }
      }
    } finally {
      _running = false;
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    cancelPending();
    final active = _active;
    if (active != null && !active.result.isCompleted) {
      active.result.completeError(const DirectorySortCancelled());
    }
    _isolate?.kill(priority: Isolate.immediate);
    unawaited(_responses?.cancel());
    _port?.close();
  }
}

class _SortRequest {
  final List<SourceEntry> entries;
  final DirectorySort? order;
  final bool hideHiddenFiles;
  final String? query;
  final Map<String, SyncRecord> records;
  final Map<String, String> titles;
  final result = Completer<List<SourceEntry>>();

  _SortRequest(this.entries, this.order, this.hideHiddenFiles)
    : query = null,
      records = const {},
      titles = const {};

  _SortRequest.search(this.entries, this.query, this.records, this.titles)
    : order = null,
      hideHiddenFiles = false;
}

List<SourceEntry> searchDirectoryEntries(
  List<SourceEntry> entries,
  String query, {
  Map<String, SyncRecord> records = const {},
  Map<String, String> titles = const {},
}) {
  final terms = query.trim().toLowerCase().split(RegExp(r'\s+'));
  if (terms.singleOrNull == '') return entries;
  return entries
      .where(
        (entry) =>
            terms.every(_searchableText(entry, records, titles).contains),
      )
      .toList();
}

String _searchableText(
  SourceEntry entry,
  Map<String, SyncRecord> records,
  Map<String, String> titles,
) {
  final record = records[entry.path.replaceAll('\\', '/')];
  return [
    entry.name,
    titles[entry.path] ?? titles['${record?.data['episode'] ?? ''}'] ?? '',
    record?.data['title'] ?? '',
    record?.data['metadataTitle'] ?? '',
    record?.data['series'] ?? '',
    record?.data['episodeTitle'] ?? '',
  ].join(' ').toLowerCase();
}

void _sortDirectory(SendPort replies) {
  final requests = ReceivePort();
  List<SourceEntry> searchEntries = const [];
  List<String> searchText = const [];
  replies.send(requests.sendPort);
  requests.listen((message) {
    final (
      entries,
      field,
      descending,
      showSubtitles,
      hideHidden,
      query,
      records,
      titles,
    ) = message
        as (
          List<SourceEntry>?,
          String?,
          bool,
          bool,
          bool,
          String?,
          Map<String, SyncRecord>,
          Map<String, String>,
        );
    try {
      final List<SourceEntry> sorted;
      if (field == null) {
        if (entries != null) {
          searchEntries = entries;
          searchText = [
            for (final entry in entries)
              _searchableText(entry, records, titles),
          ];
        }
        final terms = query!.trim().toLowerCase().split(RegExp(r'\s+'));
        sorted = [
          for (var i = 0; i < searchEntries.length; i++)
            if (terms.every(searchText[i].contains)) searchEntries[i],
        ];
      } else {
        sorted = DirectorySort(
          field: field,
          descending: descending,
          showSubtitles: showSubtitles,
        ).apply(entries!, hideHiddenFiles: hideHidden);
      }
      replies.send((sorted, null));
    } catch (error) {
      replies.send((null, error.toString()));
    }
  });
}
