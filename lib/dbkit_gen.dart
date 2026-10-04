/// dbkit_gen — annotation-based code generator for dbkit.
///
/// Annotate model classes and run build_runner:
///
/// ```dart
/// import 'package:dbkit/dbkit.dart';
///
/// part 'user.g.dart';
///
/// @DbTable('users')
/// class User {
///   @DbId()
///   final int? id;
///
///   final String name;
///
///   const User({this.id, required this.name});
///
///   factory User.fromMap(Map<String, Object?> map) => _$UserFromMap(map);
///   Map<String, Object?> toMap() => _$UserToMap(this);
/// }
/// ```
///
/// ```sh
/// dart run build_runner build
/// ```
library;

export 'src/emitter.dart' show emitTablePart;
export 'src/resolver.dart' show TableResolver;
export 'src/schema.dart';
export 'src/table_generator.dart' show DbkitTablesGenerator;
