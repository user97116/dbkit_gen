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
  /// One message per problem, each carrying a `Model.field` path.
  final List<String> errors;

  /// Creates an exception carrying [errors] (must not be empty).
  SchemaException(this.errors) : assert(errors.isNotEmpty);

  @override
  String toString() =>
      'SchemaException:\n${errors.map((e) => '  - $e').join('\n')}';
}

/// Column types supported by the schema (mirror of dbkit's `SqlType`).
enum ColumnType {
  /// 32/64-bit integers (`int`).
  integer,

  /// UTF-8 text (`String`).
  text,

  /// Floating-point numbers (`double`).
  real,

  /// Raw bytes (`Uint8List`).
  blob,

  /// Booleans, stored as `0`/`1` (`bool`).
  boolean,

  /// Timestamps, stored as ISO-8601 text (`DateTime`).
  datetime
}

/// A foreign-key reference on a column.
class ColumnReference {
  /// Referenced table name.
  final String table;

  /// Referenced column name (defaults to `'id'`).
  final String column;

  /// `ON DELETE` action (defaults to `'CASCADE'`).
  final String onDelete;

  /// `ON UPDATE` action (defaults to `'CASCADE'`).
  final String onUpdate;

  /// Creates a reference to [table].[column].
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

  /// Column data type.
  final ColumnType type;

  /// Whether the Dart field is non-nullable.
  final bool required;

  /// Whether this column is (part of) the primary key.
  final bool primaryKey;

  /// Whether this is an autoincrementing integer primary key.
  final bool autoIncrement;

  /// Whether values must be unique.
  final bool unique;

  /// Dart-level default value, if any.
  final Object? defaultValue;

  /// Whether the column defaults to `CURRENT_TIMESTAMP`.
  final bool defaultNow;

  /// Foreign-key reference, if any.
  final ColumnReference? references;

  /// Table-level `CHECK` expression on this column, if any.
  final String? check;

  /// Creates a column mapping [field] to database column [name].
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
  bool get nonNull => required || primaryKey || defaultValue != null;
}

/// A secondary index on a table.
class IndexSchema {
  /// Index name, if explicit (else derived from table + columns).
  final String? name;

  /// Indexed Dart field names.
  final List<String> columns;

  /// Whether the index enforces uniqueness.
  final bool unique;

  /// Creates an index over [columns].
  const IndexSchema({this.name, required this.columns, this.unique = false});
}

/// Relationship kinds (mirror of dbkit's `RelationKind`).
enum RelationKind {
  /// One parent row -> many child rows.
  hasMany,

  /// One parent row -> one child row.
  hasOne,

  /// Many child rows -> one parent row.
  belongsTo,

  /// Many rows <-> many rows via a pivot table.
  belongsToMany
}

/// One named relationship declared on a table.
///
/// Key fields ([localKey], [foreignKey], [targetKey]) hold *database* column
/// names; [targetModel] is the Dart model they belong to.
class RelationSchema {
  /// Relation/loader name (e.g. `'posts'`).
  final String name;

  /// The relationship kind.
  final RelationKind kind;

  /// Target table name.
  final String table;

  /// Target Dart model name.
  final String targetModel;

  /// Database column on this table used for the join.
  final String localKey;

  /// Database foreign-key column (null for `belongsTo`, where [localKey]
  /// already is the FK).
  final String? foreignKey;

  /// Database column on the target table used for the join.
  final String targetKey;

  /// Pivot table name (`belongsToMany` only).
  final String? pivot;

  /// Pivot column pointing at this table (`belongsToMany` only).
  final String? pivotFromKey;

  /// Pivot column pointing at the target table (`belongsToMany` only).
  final String? pivotToKey;

  /// Default ordering column (`hasMany` only).
  final String? orderBy;

  /// Whether the default ordering is descending.
  final bool desc;

  /// Default row limit (`hasMany` only).
  final int? limit;

  /// Creates a relationship named [name] of [kind] towards [table].
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
  /// Database table name.
  final String name;

  /// Dart model name.
  final String model;

  /// Whether `created_at`/`updated_at` timestamp columns are generated.
  final bool timestamps;

  /// Table columns, in declaration order.
  final List<ColumnSchema> columns;

  /// Secondary indexes.
  final List<IndexSchema> indexes;

  /// Declared relationships.
  final List<RelationSchema> relations;

  /// Creates a table schema for [name] with model [model].
  const TableSchema({
    required this.name,
    required this.model,
    this.timestamps = false,
    required this.columns,
    this.indexes = const [],
    this.relations = const [],
  });

  /// Looks a column up by database column [name].
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
