import 'package:dbkit_gen/dbkit_gen.dart';
import 'package:test/test.dart';

/// Unit tests for [emitTablePart] with hand-built schemas — covers branches
/// the builder-test fixtures don't (blob, datetime, table-level checks,
/// text primary keys, empty-relation tables).
void main() {
  String emit(TableSchema table, [Map<String, TableSchema>? targets]) =>
      emitTablePart(table, targets: targets ?? const {}, source: 'models.dart');

  TableSchema filesTable() => const TableSchema(
        name: 'files',
        model: 'FileEntry',
        columns: [
          ColumnSchema(
              name: 'id',
              field: 'id',
              type: ColumnType.integer,
              primaryKey: true,
              autoIncrement: true),
          ColumnSchema(
              name: 'path',
              field: 'path',
              type: ColumnType.text,
              required: true),
          ColumnSchema(name: 'data', field: 'data', type: ColumnType.blob),
          ColumnSchema(
              name: 'size',
              field: 'size',
              type: ColumnType.real,
              required: true),
          ColumnSchema(
              name: 'created', field: 'created', type: ColumnType.datetime),
          ColumnSchema(
              name: 'seen_at',
              field: 'seenAt',
              type: ColumnType.datetime,
              defaultNow: true),
          ColumnSchema(
              name: 'note',
              field: 'note',
              type: ColumnType.text,
              check: 'length(note) < 100'),
        ],
      );

  test('mapping handles every column type', () {
    final code = emit(filesTable());
    expect(code, contains('FileEntry _\$FileEntryFromMap('));
    expect(code, contains('data: map[\'data\'] as Uint8List?,'));
    expect(code, contains('(map[\'size\'] as num).toDouble(),'));
    expect(
        code,
        contains(
            'seenAt: map[\'seen_at\'] == null ? null : DateTime.parse(map[\'seen_at\'] as String),'));
    expect(code, contains("'seen_at': value.seenAt?.toIso8601String(),"));
    // part files share the owner's imports — no import directives emitted
    expect(code.contains('import '), isFalse);
  });

  test('DDL covers defaults, checks and timestamps flag', () {
    final code = emit(filesTable());
    expect(code, contains("t.text('note');"));
    expect(code, contains("t.check('length(note) < 100');"));
    expect(code, contains('Future<void> createFileEntryTable(Db db)'));
    expect(code, contains('void registerFileEntryRelations(Db db)'));
  });

  test('text primary key: void save, direct update', () {
    const table = TableSchema(
      name: 'settings',
      model: 'Setting',
      columns: [
        ColumnSchema(
            name: 'key',
            field: 'key',
            type: ColumnType.text,
            required: true,
            primaryKey: true),
        ColumnSchema(name: 'value', field: 'value', type: ColumnType.text),
      ],
    );
    final code = emit(table);
    expect(
        code,
        contains(
            'Future<void> save(Setting value) => ref.upsert(value.toMap());'));
    expect(code,
        contains("return ref.updateById(value.key, values, idColumn: 'key');"));
    expect(code, contains('Future<Setting?> findById(Object id)'));
  });

  test('tables without relations skip loaders and wrappers', () {
    const table = TableSchema(
      name: 'tags',
      model: 'Tag',
      columns: [
        ColumnSchema(
            name: 'id',
            field: 'id',
            type: ColumnType.integer,
            primaryKey: true,
            autoIncrement: true),
        ColumnSchema(
            name: 'label',
            field: 'label',
            type: ColumnType.text,
            required: true),
      ],
    );
    final code = emit(table);
    expect(code.contains('extension TagRelations'), isFalse);
    expect(code.contains('With'), isFalse);
    expect(code, contains('extension DbTagTable on Db {'));
  });

  test('bool columns decode inline, helpers are per-model', () {
    const withBool = TableSchema(
      name: 'posts',
      model: 'Post',
      columns: [
        ColumnSchema(
            name: 'id',
            field: 'id',
            type: ColumnType.integer,
            primaryKey: true,
            autoIncrement: true),
        ColumnSchema(
            name: 'published',
            field: 'published',
            type: ColumnType.boolean,
            required: true,
            defaultValue: false),
      ],
    );
    // Bool reads are inline (no shared helper to collide in combined parts).
    expect(emit(withBool),
        contains("(map['published'] == 1 || map['published'] == true)"));
    // Per-model null-stripper avoids duplicate definitions in one .g.dart.
    expect(emit(withBool), contains('_withoutNullsPost('));
    expect(emit(filesTable()), contains('_withoutNullsFileEntry('));
  });
}
