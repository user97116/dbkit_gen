import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:source_gen/source_gen.dart';

import 'schema.dart';

/// Matches the annotations declared in `package:dbkit/src/annotations.dart`
/// without importing that package (which would be a dependency cycle:
/// `dbkit` already dev-depends on `dbkit_gen`).
abstract final class _Ann {
  static const _base = 'package:dbkit/src/annotations.dart';
  static const table = TypeChecker.fromUrl('$_base#DbTable');
  static const column = TypeChecker.fromUrl('$_base#DbColumn');
  static const id = TypeChecker.fromUrl('$_base#DbId');
  static const index = TypeChecker.fromUrl('$_base#DbIndex');
  static const ignore = TypeChecker.fromUrl('$_base#DbIgnore');
  static const hasMany = TypeChecker.fromUrl('$_base#HasMany');
  static const hasOne = TypeChecker.fromUrl('$_base#HasOne');
  static const belongsTo = TypeChecker.fromUrl('$_base#BelongsTo');
  static const belongsToMany = TypeChecker.fromUrl('$_base#BelongsToMany');
}

/// Members that generated relation loaders must not shadow.
const _reservedMembers = {
  'copyWith',
  'fromMap',
  'toMap',
  'toString',
  'hashCode',
  'noSuchMethod',
  'runtimeType',
};

/// Resolves `@DbTable`-annotated classes into [TableSchema] models.
///
/// Relation targets are resolved recursively; a per-run cache makes mutual
/// references (e.g. `User.posts` <-> `Post.author`) terminate. Only the
/// target's table name, model name and columns are needed for codegen, so
/// partially-resolved entries are safe to reuse mid-recursion.
///
/// All problems are collected and thrown together as a [SchemaException]
/// whose messages carry `Model.field` paths.
class TableResolver {
  final Map<ClassElement, TableSchema> _cache = {};
  final List<String> _errors = [];

  void _err(String message) => _errors.add(message);

  /// Every table resolved so far (the root plus all reachable relation
  /// targets), keyed by element. Read after [resolve] to feed the emitter.
  Map<ClassElement, TableSchema> get resolved => Map.unmodifiable(_cache);

  /// Resolves [element] (which must carry `@DbTable`) and returns its
  /// schema, throwing [SchemaException] if anything is invalid.
  TableSchema resolve(ClassElement element) {
    _errors.clear();
    final table = _resolveTable(element);
    if (_errors.isNotEmpty) {
      throw SchemaException(List.of(_errors));
    }
    return table;
  }

  TableSchema _resolveTable(ClassElement element) {
    final cached = _cache[element];
    if (cached != null) return cached;

    final model = element.name ?? '<anonymous>';
    final tableAnn = _Ann.table.firstAnnotationOf(element);
    if (tableAnn == null) {
      _err('$model: missing @DbTable annotation');
      throw SchemaException(List.of(_errors));
    }
    final tableReader = ConstantReader(tableAnn);
    final tableName = _readString(tableReader, 'name', '$model.@DbTable');
    if (tableName == null || tableName.isEmpty) {
      _err('$model.@DbTable: table name must be a non-empty string');
      throw SchemaException(List.of(_errors));
    }
    final timestamps =
        _readBool(tableReader, 'timestamps', '$model.@DbTable') ?? false;

    // Phase 1: columns are discovered from the unnamed constructor's
    // named field-formal parameters (`{this.id, ...}`). This is precise by
    // construction: computed getters such as `get hashCode` can never be
    // constructor parameters, so they can never become columns. Every
    // persisted field must be a named `this.` parameter (cached before
    // relations so mutual references terminate; targets only ever need
    // name/model/columns from each other).
    final ctor = element.unnamedConstructor;
    if (ctor == null) {
      _err('$model: add an unnamed constructor with named parameters, '
          'e.g. `const $model({required this.name});`');
      throw SchemaException(List.of(_errors));
    }
    final columns = <ColumnSchema>[];
    for (final param in ctor.formalParameters) {
      if (!param.isNamed) continue;
      final paramName = param.name;
      if (paramName == null) continue;
      if (param is! FieldFormalParameterElement || param.field == null) {
        _err('$model: constructor parameter `$paramName` must be a field '
            'formal (`this.$paramName`)');
        continue;
      }
      final column = _resolveColumn(model, param.field!, paramName);
      if (column != null) columns.add(column);
    }
    final partial = TableSchema(
      name: tableName,
      model: model,
      timestamps: timestamps,
      columns: _applyTimestamps(model, columns, timestamps),
    );
    _cache[element] = partial;

    final indexes = _resolveIndexes(model, element);
    final relations = _resolveRelations(model, element, partial);

    final table = TableSchema(
      name: tableName,
      model: model,
      timestamps: timestamps,
      columns: _applyTimestamps(model, columns, timestamps),
      indexes: indexes,
      relations: relations,
    );
    _validateTable(model, element, table);
    _checkUnmappedFields(model, element, table);
    _cache[element] = table;
    return table;
  }

  /// Every real field must either become a column or be explicitly ignored.
  /// (`get hashCode` / `get runtimeType` overrides are always exempt.)
  void _checkUnmappedFields(
      String model, ClassElement element, TableSchema table) {
    final mapped = {for (final c in table.columns) c.field};
    for (final field in element.fields) {
      if (field.isStatic) continue;
      final fieldName = field.name;
      if (fieldName == null || mapped.contains(fieldName)) continue;
      if (fieldName == 'hashCode' || fieldName == 'runtimeType') continue;
      if (_Ann.ignore.hasAnnotationOf(field)) continue;
      final getter = field.getter;
      if (getter != null && _Ann.ignore.hasAnnotationOf(getter)) continue;
      _err('$model.$fieldName: field is not a named `this.` constructor '
          'parameter, so it cannot be a column; mark computed members with '
          '@DbIgnore()');
    }
  }

  // -- columns -------------------------------------------------------------------

  ColumnSchema? _resolveColumn(
      String model, FieldElement field, String fieldName) {
    final path = '$model.$fieldName';
    final fieldType = _columnType(model, field, fieldName);
    if (fieldType == null) return null;

    final idAnn = _Ann.id.firstAnnotationOf(field);
    final colAnn = _Ann.column.firstAnnotationOf(field);
    if (idAnn != null && colAnn != null) {
      _err('$path: use either @DbId() or @DbColumn(), not both');
      return null;
    }

    final nullable = field.type.nullabilitySuffix == NullabilitySuffix.question;

    if (idAnn != null) {
      final reader = ConstantReader(idAnn);
      final autoIncrement =
          _readBool(reader, 'autoIncrement', '$path.@DbId') ?? true;
      if (autoIncrement && fieldType != ColumnType.integer) {
        _err('$path.@DbId: autoIncrement requires an int field');
        return null;
      }
      return ColumnSchema(
        name: _readString(reader, 'name', '$path.@DbId') ?? fieldName,
        field: fieldName,
        type: fieldType,
        primaryKey: true,
        autoIncrement: autoIncrement,
      );
    }

    final reader = colAnn == null ? null : ConstantReader(colAnn);
    final primaryKey = reader == null
        ? false
        : (_readBool(reader, 'primaryKey', path) ?? false);
    if (primaryKey && nullable) {
      _err('$path: primaryKey columns must be non-nullable (or use @DbId())');
      return null;
    }
    final defaultNow = reader == null
        ? false
        : (_readBool(reader, 'defaultNow', path) ?? false);
    if (defaultNow && fieldType != ColumnType.datetime) {
      _err('$path: defaultNow is only valid for DateTime fields');
      return null;
    }
    Object? defaultValue;
    if (reader != null && !reader.read('defaultValue').isNull) {
      defaultValue = _readScalar(
          reader.read('defaultValue'), '$path.@DbColumn(defaultValue)');
      if (defaultValue != null && !_defaultMatches(fieldType, defaultValue)) {
        _err('$path: default value does not match field type');
        return null;
      }
    }

    ColumnReference? references;
    final refTable =
        reader == null ? null : _readString(reader, 'references', path);
    if (refTable != null) {
      references = ColumnReference(
        table: refTable,
        column: reader == null
            ? 'id'
            : (_readString(reader, 'referencesColumn', path) ?? 'id'),
        onDelete: reader == null
            ? 'CASCADE'
            : (_readString(reader, 'onDelete', path) ?? 'CASCADE'),
        onUpdate: reader == null
            ? 'CASCADE'
            : (_readString(reader, 'onUpdate', path) ?? 'CASCADE'),
      );
    }

    return ColumnSchema(
      name: reader == null
          ? fieldName
          : (_readString(reader, 'name', path) ?? fieldName),
      field: fieldName,
      type: fieldType,
      required: !nullable,
      primaryKey: primaryKey,
      unique:
          reader == null ? false : (_readBool(reader, 'unique', path) ?? false),
      defaultValue: defaultValue,
      defaultNow: defaultNow,
      references: references,
      check: reader == null ? null : _readString(reader, 'check', path),
    );
  }

  /// Maps a field's Dart type to a [ColumnType], guiding away from
  /// relation-shaped fields.
  ColumnType? _columnType(String model, FieldElement field, String fieldName) {
    final path = '$model.$fieldName';
    final type = field.type;
    if (type is! InterfaceType) {
      _err('$path: unsupported type `${type.getDisplayString()}` '
          '(int, String, double, bool, DateTime, Uint8List)');
      return null;
    }
    if (type.typeArguments.isNotEmpty) {
      final arg = type.typeArguments.first;
      final argElement = arg is InterfaceType ? arg.element : null;
      if (argElement is ClassElement &&
          _Ann.table.hasAnnotationOf(argElement)) {
        _err('$path: looks like a relation — declare it on the class with '
            '@HasMany/@HasOne/@BelongsTo/@BelongsToMany instead of a field');
      } else {
        _err('$path: unsupported type `${type.getDisplayString()}` '
            '(int, String, double, bool, DateTime, Uint8List)');
      }
      return null;
    }
    return switch (type.element.name) {
      'int' => ColumnType.integer,
      'String' => ColumnType.text,
      'double' => ColumnType.real,
      'bool' => ColumnType.boolean,
      'DateTime' => ColumnType.datetime,
      'Uint8List' => ColumnType.blob,
      _ => () {
          _err('$path: unsupported type `${type.getDisplayString()}` '
              '(int, String, double, bool, DateTime, Uint8List)');
          return null;
        }(),
    };
  }

  bool _defaultMatches(ColumnType type, Object value) {
    switch (type) {
      case ColumnType.boolean:
        return value is bool;
      case ColumnType.integer:
        return value is int;
      case ColumnType.real:
        return value is num;
      case ColumnType.text:
      case ColumnType.datetime:
        return value is String;
      case ColumnType.blob:
        return false;
    }
  }

  /// Forces `createdAt`/`updatedAt` fields onto their `created_at` /
  /// `updated_at` DB columns when `timestamps: true` (the DDL is emitted
  /// as `t.timestamps()`, so the names are fixed).
  List<ColumnSchema> _applyTimestamps(
      String model, List<ColumnSchema> columns, bool timestamps) {
    if (!timestamps) return columns;
    return [
      for (final c in columns)
        if (c.field == 'createdAt' || c.field == 'updatedAt')
          () {
            if (c.name != c.field) {
              _err('$model.${c.field}: timestamps fields must not set '
                  '@DbColumn(name:)');
            }
            return ColumnSchema(
              name: c.field == 'createdAt' ? 'created_at' : 'updated_at',
              field: c.field,
              type: ColumnType.datetime,
              defaultNow: true,
            );
          }()
        else
          c,
    ];
  }

  // -- indexes ---------------------------------------------------------------------

  List<IndexSchema> _resolveIndexes(String model, ClassElement element) {
    final indexes = <IndexSchema>[];
    for (final ann in _Ann.index.annotationsOf(element)) {
      final reader = ConstantReader(ann);
      final path = '$model.@DbIndex';
      List<String> columns = const [];
      if (!reader.read('columns').isList) {
        _err('$path: columns must be a list of field names');
      } else {
        final parsed = <String>[];
        var ok = true;
        for (final e in reader.read('columns').listValue) {
          String? name;
          try {
            name = e.toStringValue();
          } catch (_) {
            name = null;
          }
          if (name == null || name.isEmpty) {
            ok = false;
          } else {
            parsed.add(name);
          }
        }
        if (!ok || parsed.isEmpty) {
          _err('$path: columns must be a non-empty list of field names');
        }
        columns = parsed;
      }
      indexes.add(IndexSchema(
        name: _readString(reader, 'name', path),
        columns: columns,
        unique: _readBool(reader, 'unique', path) ?? false,
      ));
    }
    return indexes;
  }

  // -- relations ---------------------------------------------------------------------

  List<RelationSchema> _resolveRelations(
      String model, ClassElement element, TableSchema partial) {
    final relations = <RelationSchema>[];
    relations.addAll(_resolveKind(
        model, element, partial, _Ann.hasMany, RelationKind.hasMany));
    relations.addAll(_resolveKind(
        model, element, partial, _Ann.hasOne, RelationKind.hasOne));
    relations.addAll(_resolveKind(
        model, element, partial, _Ann.belongsTo, RelationKind.belongsTo));
    relations.addAll(_resolveKind(model, element, partial, _Ann.belongsToMany,
        RelationKind.belongsToMany));
    return relations;
  }

  List<RelationSchema> _resolveKind(
    String model,
    ClassElement element,
    TableSchema partial,
    TypeChecker checker,
    RelationKind kind,
  ) {
    final relations = <RelationSchema>[];
    for (final ann in checker.annotationsOf(element)) {
      final reader = ConstantReader(ann);
      final path = '$model.@${kind.name}';
      final name = _readString(reader, 'name', path);
      if (name == null || name.isEmpty) {
        _err('$path: name must be a non-empty string');
        continue;
      }
      final relPath = '$model.$name';

      final target = _resolveTarget(relPath, reader);
      if (target == null) continue;

      String? dbOf(String? field, String which) {
        if (field == null) return null;
        final col = partial.columnByField(field);
        if (col == null) {
          _err('$relPath: unknown $which field "$field" on $model');
          return null;
        }
        return col.name;
      }

      String? targetDbOf(String? field, String which) {
        if (field == null) return null;
        final col = target.columnByField(field);
        if (col == null) {
          _err('$relPath: unknown $which field "$field" on ${target.model}');
          return null;
        }
        return col.name;
      }

      switch (kind) {
        case RelationKind.hasMany:
        case RelationKind.hasOne:
          final foreignKey = _readString(reader, 'foreignKey', relPath);
          if (foreignKey == null) {
            _err('$relPath: foreignKey is required');
            continue;
          }
          final localKey =
              _readString(reader, 'localKey', relPath) ?? _pkField(partial);
          if (localKey == null) {
            _err('$relPath: localKey is required (no primary key on $model)');
            continue;
          }
          final localDb = dbOf(localKey, 'localKey');
          final foreignDb = targetDbOf(foreignKey, 'foreignKey');
          if (localDb == null || foreignDb == null) continue;
          String? orderDb;
          var desc = false;
          int? limit;
          if (kind == RelationKind.hasMany) {
            final orderBy = _readString(reader, 'orderBy', relPath);
            if (orderBy != null) {
              orderDb = targetDbOf(orderBy, 'orderBy');
              if (orderDb == null) continue;
            }
            desc = _readBool(reader, 'desc', relPath) ?? false;
            if (desc && orderBy == null) {
              _err('$relPath: desc needs orderBy to sort by');
              continue;
            }
            limit = _readInt(reader, 'limit', relPath);
            if (limit != null && limit < 1) {
              _err('$relPath: limit must be a positive integer');
              continue;
            }
          }
          relations.add(RelationSchema(
            name: name,
            kind: kind,
            table: target.name,
            targetModel: target.model,
            localKey: localDb,
            foreignKey: foreignDb,
            orderBy: orderDb,
            desc: desc,
            limit: limit,
          ));
        case RelationKind.belongsTo:
          final foreignKey = _readString(reader, 'foreignKey', relPath);
          if (foreignKey == null) {
            _err('$relPath: foreignKey is required');
            continue;
          }
          final targetKey =
              _readString(reader, 'targetKey', relPath) ?? _pkField(target);
          if (targetKey == null) {
            _err('$relPath: targetKey is required '
                '(no primary key on ${target.model})');
            continue;
          }
          final foreignDb = dbOf(foreignKey, 'foreignKey');
          final targetDb = targetDbOf(targetKey, 'targetKey');
          if (foreignDb == null || targetDb == null) continue;
          relations.add(RelationSchema(
            name: name,
            kind: kind,
            table: target.name,
            targetModel: target.model,
            // belongsTo looks the parent up BY the FK: fromKey IS the FK.
            localKey: foreignDb,
            foreignKey: foreignDb,
            targetKey: targetDb,
          ));
        case RelationKind.belongsToMany:
          final pivot = _readString(reader, 'pivot', relPath);
          final fromKey = _readString(reader, 'fromKey', relPath);
          final toKey = _readString(reader, 'toKey', relPath);
          if (pivot == null || pivot.isEmpty) {
            _err('$relPath: pivot table name is required');
            continue;
          }
          if (fromKey == null || toKey == null) {
            _err('$relPath: fromKey and toKey pivot columns are required');
            continue;
          }
          final localKey =
              _readString(reader, 'localKey', relPath) ?? _pkField(partial);
          final targetKey =
              _readString(reader, 'targetKey', relPath) ?? _pkField(target);
          if (localKey == null) {
            _err('$relPath: localKey is required (no primary key on $model)');
            continue;
          }
          if (targetKey == null) {
            _err('$relPath: targetKey is required '
                '(no primary key on ${target.model})');
            continue;
          }
          final localDb = dbOf(localKey, 'localKey');
          final targetDb = targetDbOf(targetKey, 'targetKey');
          if (localDb == null || targetDb == null) continue;
          relations.add(RelationSchema(
            name: name,
            kind: kind,
            table: target.name,
            targetModel: target.model,
            localKey: localDb,
            targetKey: targetDb,
            pivot: pivot,
            pivotFromKey: fromKey,
            pivotToKey: toKey,
          ));
      }
    }
    return relations;
  }

  /// Resolves a relation `target:` type to its table schema.
  TableSchema? _resolveTarget(String relPath, ConstantReader reader) {
    if (reader.read('target').isNull) {
      _err('$relPath: target model type is required');
      return null;
    }
    final DartType targetType;
    try {
      targetType = reader.read('target').typeValue;
    } catch (_) {
      _err('$relPath: target must be a model type');
      return null;
    }
    final targetElement = targetType.element;
    if (targetElement is! ClassElement ||
        !_Ann.table.hasAnnotationOf(targetElement)) {
      _err('$relPath: target `${targetType.getDisplayString()}` '
          'is not annotated with @DbTable');
      return null;
    }
    return _resolveTable(targetElement);
  }

  /// Primary-key *field* name, for `localKey`/`targetKey` defaults.
  String? _pkField(TableSchema table) {
    final pks = table.columns.where((c) => c.primaryKey).toList();
    if (pks.length != 1) return null;
    return pks.first.field;
  }

  // -- whole-table validation ------------------------------------------------------------

  void _validateTable(String model, ClassElement element, TableSchema table) {
    if (table.columns.isEmpty) {
      _err('$model: table needs at least one column field');
    }
    final dbNames = <String>{};
    for (final c in table.columns) {
      if (!dbNames.add(c.name)) {
        _err('$model.${c.field}: duplicate column name "${c.name}"');
      }
    }
    if (table.timestamps) {
      for (final reserved in ['created_at', 'updated_at']) {
        if (table.columns.any((c) => c.name == reserved)) {
          _err('$model: `timestamps: true` generates "$reserved" — '
              'remove the manual field');
        }
      }
      for (final requiredField in ['createdAt', 'updatedAt']) {
        FieldElement? fieldElement;
        for (final f in element.fields) {
          if (!f.isStatic && f.name == requiredField) fieldElement = f;
        }
        final fieldType = fieldElement?.type;
        final ok = fieldType is InterfaceType &&
            fieldType.element.name == 'DateTime' &&
            fieldType.nullabilitySuffix == NullabilitySuffix.question;
        if (!ok) {
          _err('$model: `timestamps: true` needs a nullable '
              '`DateTime? $requiredField` field');
        }
      }
    }
    final pks = table.columns.where((c) => c.primaryKey).toList();
    if (pks.length > 1) {
      _err('$model: composite primary keys are not supported by codegen '
          '(${pks.map((c) => c.field).join(', ')})');
    }
    for (final idx in table.indexes) {
      for (final field in idx.columns) {
        if (table.columnByField(field) == null) {
          _err('$model.@DbIndex: unknown field "$field"');
        }
      }
    }
    // relation names
    final seenRels = <String>{};
    final memberNames = <String>{
      for (final c in table.columns) c.field,
      for (final m in element.methods)
        if (m.name != null) m.name!,
    };
    for (final r in table.relations) {
      final rp = '$model.${r.name}';
      if (!_isIdentifier(r.name)) {
        _err('$rp: invalid relation name');
        continue;
      }
      if (!seenRels.add(r.name)) {
        _err('$rp: duplicate relation name');
      }
      if (memberNames.contains(r.name) || _reservedMembers.contains(r.name)) {
        _err('$rp: relation name collides with a member of $model');
      }
      if (table.columnByField(r.name) != null) {
        _err('$rp: relation name collides with a field of $model');
      }
    }
    // wrapper class names must be unique per model
    final wrappers = <String>{};
    for (final r in table.relations) {
      final prop = _camel(r.name);
      final wrapper =
          '${table.model}With${prop[0].toUpperCase()}${prop.substring(1)}';
      if (!wrappers.add(wrapper)) {
        _err('$model.${r.name}: wrapper class "$wrapper" collides with '
            'another relation (names differ only by case or _)');
      }
    }
  }

  // -- annotation scalar readers -----------------------------------------------------

  String? _readString(ConstantReader reader, String field, String path) {
    final value = reader.read(field);
    if (value.isNull) return null;
    if (!value.isString) {
      _err('$path: `$field` must be a string');
      return null;
    }
    final s = value.stringValue;
    if (s.isEmpty) {
      _err('$path: `$field` must be a non-empty string');
      return null;
    }
    return s;
  }

  bool? _readBool(ConstantReader reader, String field, String path) {
    final value = reader.read(field);
    if (value.isNull) return null;
    if (!value.isBool) {
      _err('$path: `$field` must be true or false');
      return null;
    }
    return value.boolValue;
  }

  int? _readInt(ConstantReader reader, String field, String path) {
    final value = reader.read(field);
    if (value.isNull) return null;
    if (!value.isInt) {
      _err('$path: `$field` must be an integer');
      return null;
    }
    return value.intValue;
  }

  Object? _readScalar(ConstantReader value, String path) {
    if (value.isBool) return value.boolValue;
    if (value.isInt) return value.intValue;
    if (value.isDouble) return value.doubleValue;
    if (value.isString) return value.stringValue;
    _err('$path: must be a bool, number or string');
    return null;
  }

  bool _isIdentifier(String s) =>
      RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(s);

  String _camel(String s) {
    final parts = s.split('_').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return s;
    return parts.first +
        parts.skip(1).map((p) => p[0].toUpperCase() + p.substring(1)).join();
  }
}
