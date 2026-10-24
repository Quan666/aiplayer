/// Portable all-video ordering. Collection membership and episode order are
/// independent of the selected card order.
class LibrarySort {
  final String field;
  final bool descending;

  const LibrarySort({this.field = 'recent', this.descending = true});

  static const fields = ['recent', 'name', 'modified', 'size', 'updated'];
  static const labels = {
    'recent': '最近播放',
    'name': '名称',
    'modified': '修改时间',
    'size': '文件大小',
    'updated': '更新时间',
  };

  LibrarySort copyWith({String? field, bool? descending}) => LibrarySort(
    field: field ?? this.field,
    descending: descending ?? this.descending,
  );

  @override
  bool operator ==(Object other) =>
      other is LibrarySort &&
      field == other.field &&
      descending == other.descending;

  @override
  int get hashCode => Object.hash(field, descending);
}
