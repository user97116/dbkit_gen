import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';
import 'dart:async';

import 'emitter.dart';
import 'resolver.dart';
import 'schema.dart';

/// Matches `@DbTable` without importing `package:dbkit` (which would be a
/// dependency cycle: `dbkit` already dev-depends on `dbkit_gen`).
final _tableChecker =
    TypeChecker.fromUrl('package:dbkit/src/annotations.dart#DbTable');

/// Generates one `.dbkit.g.part` per library, with a fragment for every
/// `@DbTable`-annotated class. `source_gen|combining_builder` merges the
/// parts into the `.g.dart` file named by the source's `part` directive.
class DbkitTablesGenerator extends Generator {
  const DbkitTablesGenerator();

  @override
  FutureOr<String?> generate(LibraryReader library, BuildStep buildStep) async {
    final out = StringBuffer();
    final models = <String>[];
    for (final element in library.classes) {
      if (!_tableChecker.hasAnnotationOf(element)) continue;
      final resolver = TableResolver();
      late final TableSchema table;
      try {
        table = resolver.resolve(element);
      } on SchemaException catch (e) {
        throw StateError(
            'dbkit_gen: invalid @DbTable on `${element.name}`:\n$e');
      }
      final targets = {
        for (final t in resolver.resolved.values) t.name: t,
      };
      out.writeln(emitTablePart(
        table,
        targets: targets,
        source: buildStep.inputId.pathSegments.last,
      ));
      models.add(table.model);
    }
    if (models.isEmpty) return null;
    // Aggregated setup for every table in this library (declaration order
    // should be FK-safe: parents first, pivots last).
    out.writeln('// Aggregated setup for all ${models.length} tables in this file.');
    out.writeln('Future<void> createAllTables(Db db) async {');
    for (final m in models) {
      out.writeln('  await create${m}Table(db);');
    }
    out.writeln('}');
    out.writeln('');
    out.writeln('Future<void> dropAllTables(Db db) async {');
    for (final m in models.reversed) {
      out.writeln('  await drop${m}Table(db);');
    }
    out.writeln('}');
    out.writeln('');
    out.writeln('void registerAllRelations(Db db) {');
    for (final m in models) {
      out.writeln('  register${m}Relations(db);');
    }
    out.writeln('}');
    return out.toString();
  }
}
