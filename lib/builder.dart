/// Build setup for `dbkit_gen`.
///
/// The [dbkitTablesBuilder] picks up every `@DbTable`-annotated class and
/// emits a `.dbkit.g.part` file; `source_gen|combining_builder` (applied
/// automatically) merges parts into the `.g.dart` file named by the
/// `part` directive in the source.
///
/// Consumers need no `build.yaml` of their own — just:
///
/// ```dart
/// import 'package:dbkit/dbkit.dart';
///
/// part 'user.g.dart';
///
/// @DbTable('users')
/// class User { ... }
/// ```
///
/// and `dart run build_runner build`.
library;

import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';

import 'src/table_generator.dart';

/// See [dbkitTablesBuilder].
Builder dbkitTablesBuilder(BuilderOptions options) =>
    SharedPartBuilder([const DbkitTablesGenerator()], 'dbkit');
