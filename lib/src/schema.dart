/// In-memory model of one `@DbTable`-annotated class, built by the
/// resolver (see `resolver.dart`) from analyzer elements.
///
/// [ColumnSchema.name] is always the *database* column name while
/// [ColumnSchema.field] is the *Dart* field name (`@DbColumn(name:)` can
/// make them differ). Relation keys ([RelationSchema.localKey] etc.) are
/// likewise database column names; the emitter maps them back to fields.
library;

/// Thrown when annotated models are invalid. Carries every problem found.
class SchemaException implements Exception {
  final List<String> errors;
  SchemaException(this.errors) : assert(errors.isNotEmpty);

  @override
  String toString() => 'SchemaException:\n${errors.map((e) => '  - $e').join('\n')}';
}

/// Column types supported by the schema (mirror of dbkit's `SqlType`).
enum ColumnType { integer, text, real, blob, boolean, datetime }

/// A foreign-key reference on a column.
class ColumnReference {
  final String table;
  final String column;
  final String onDelete;
  final String onUpdate;

  const ColumnReference({
    required this.table,
    this.column = 'id',
    this.onDelete = 'CASCADE',
    this.onUpdate = 'CASCADE',
  });
}

/// One column of a table.
class ColumnSchema {
  /// Database column name (what SQL sees).
  final String name;

  /// Dart field name on the model (what generated code reads/writes).
  final String field;
  final ColumnType type;
  final bool required;
  final bool primaryKey;
  final bool autoIncrement;
  final bool unique;
  final Object? defaultValue;
  final bool defaultNow;
  final ColumnReference? references;
  final String? check;

  const ColumnSchema({
    required this.name,
    required this.field,
    required this.type,
    this.required = false,
    this.primaryKey = false,
    this.autoIncrement = false,
    this.unique = false,
    this.defaultValue,
    this.defaultNow = false,
    this.references,
    this.check,
  });

  /// True when the generated Dart field must be non-nullable.
  ///
  /// Note: `defaultNow` is deliberately excluded — `CURRENT_TIMESTAMP` is
  /// computed by SQLite itself, and the in-memory backend leaves such
  /// columns absent, so the model field stays nullable.
  bool get nonNull =>
      required || primaryKey || defaultValue != null;
}

/// A secondary index on a table.
class IndexSchema {
  final String? name;
  final List<String> columns;
  final bool unique;

  const IndexSchema({this.name, required this.columns, this.unique = false});
}

/// Relationship kinds (mirror of dbkit's `RelationKind`).
enum RelationKind { hasMany, hasOne, belongsTo, belongsToMany }

/// One named relationship declared on a table.
///
/// Key fields ([localKey], [foreignKey], [targetKey]) hold *database* column
/// names; [targetModel] is the Dart model they belong to.
class RelationSchema {
  final String name;
  final RelationKind kind;
  final String table;
  final String targetModel;
  final String localKey;
  final String? foreignKey;
  final String targetKey;
  final String? pivot;
  final String? pivotFromKey;
  final String? pivotToKey;
  final String? orderBy;
  final bool desc;
  final int? limit;

  const RelationSchema({
    required this.name,
    required this.kind,
    required this.table,
    required this.targetModel,
    this.localKey = 'id',
    this.foreignKey,
    this.targetKey = 'id',
    this.pivot,
    this.pivotFromKey,
    this.pivotToKey,
    this.orderBy,
    this.desc = false,
    this.limit,
  });
}

/// One table of the schema.
class TableSchema {
  final String name;
  final String model;
  final bool timestamps;
  final List<ColumnSchema> columns;
  final List<IndexSchema> indexes;
  final List<RelationSchema> relations;

  const TableSchema({
    required this.name,
    required this.model,
    this.timestamps = false,
    required this.columns,
    this.indexes = const [],
    this.relations = const [],
  });

  ColumnSchema? column(String name) {
    for (final c in columns) {
      if (c.name == name) return c;
    }
    return null;
  }

  /// Looks a column up by Dart field name.
  ColumnSchema? columnByField(String field) {
    for (final c in columns) {
      if (c.field == field) return c;
    }
    return null;
  }
}

