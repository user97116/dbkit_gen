import 'dart:io';

import 'package:build/build.dart';
import 'package:build_test/build_test.dart';
import 'package:dbkit_gen/builder.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

/// End-to-end builder tests: annotated sources in, generated parts out.
///
/// The fixtures import `package:dbkit/src/annotations.dart`, whose content
/// is injected as an in-memory asset (read from the real file, so it can
/// never drift). This keeps `dbkit_gen` free of a `dbkit` dependency —
/// `dbkit` already dev-depends on `dbkit_gen`, so a regular dependency
/// would be a cycle.
///
/// Re-generate the golden file after intentional emitter changes with:
/// `DBKIT_UPDATE_GOLDENS=1 dart test test/builder_test.dart`
void main() {
  /// In-memory sources for one test, always including the real annotations.
  Map<String, String> inputs(Map<String, String> sources) => {
        'dbkit|lib/src/annotations.dart': File(
                '../dbkit/lib/src/annotations.dart')
            .readAsStringSync(),
        for (final e in sources.entries) 'a|${e.key}': e.value,
      };

  Builder builder() => dbkitTablesBuilder(BuilderOptions.empty);

  test('generates parts for annotated models', () async {
    await testBuilder(
      builder(),
      inputs({
        'lib/models.dart': _models,
      }),
      outputs: {
        'a|lib/models.dbkit.g.part': decodedMatches(
          allOf([
            contains('abstract final class UserColumns'),
            contains(r"static const userId = 'user_id';"),
            contains(r'User _$UserFromMap(Map<String, Object?> map)'),
            contains(r'Map<String, Object?> _$UserToMap(User value)'),
            contains('class UserTable {'),
            contains('Future<List<Post>> posts(Db db)'),
            contains('Future<Profile?> profile(Db db)'),
            contains('Future<User?> author(Db db)'),
            contains('Future<List<Tag>> tags(Db db)'),
            contains('Future<void> addTag(Db db, Tag other)'),
            contains('class UserWithPosts {'),
            contains('Future<void> createUserTable(Db db)'),
            contains('void registerUserRelations(Db db)'),
            contains('Relation.belongsToMany('),
            contains('extension DbUserTable on Db {'),
          ]),
        ),
      },
    );
  });

  test('resolves relation targets across files', () async {
    await testBuilder(
      builder(),
      inputs({
        'lib/user.dart': '''
import 'package:dbkit/src/annotations.dart';
import 'post.dart';
part 'user.g.dart';

@DbTable('users')
@HasMany(Post, name: 'posts', foreignKey: 'userId')
class User {
  @DbId()
  final int? id;
  final String name;
  const User({this.id, required this.name});
  factory User.fromMap(Map<String, Object?> map) => _\$UserFromMap(map);
  Map<String, Object?> toMap() => _\$UserToMap(this);
}
''',
        'lib/post.dart': '''
import 'package:dbkit/src/annotations.dart';
import 'user.dart';
part 'post.g.dart';

@DbTable('posts')
@BelongsTo(User, name: 'author', foreignKey: 'userId')
class Post {
  @DbId()
  final int? id;
  @DbColumn(name: 'user_id')
  final int userId;
  final String title;
  const Post({this.id, required this.userId, required this.title});
  factory Post.fromMap(Map<String, Object?> map) => _\$PostFromMap(map);
  Map<String, Object?> toMap() => _\$PostToMap(this);
}
''',
      }),
      outputs: {
        'a|lib/user.dbkit.g.part':
            decodedMatches(contains('Future<List<Post>> posts(Db db)')),
        'a|lib/post.dbkit.g.part':
            decodedMatches(contains('Future<User?> author(Db db)')),
      },
    );
  });

  test('golden part output', () async {
    final goldenFile = File('test/fixtures/models.expected.part');
    var actual = '';
    await testBuilder(
      builder(),
      inputs({
        'lib/models.dart': _models,
      }),
      outputs: {
        'a|lib/models.dbkit.g.part': decodedMatches(
          allOf([contains('class UserTable {'), predicate((String s) {
            actual = s;
            return true;
          })]),
        ),
      },
    );
    if (Platform.environment['DBKIT_UPDATE_GOLDENS'] == '1') {
      goldenFile.writeAsStringSync(actual);
    }
    expect(goldenFile.existsSync(), isTrue,
        reason: 'run with DBKIT_UPDATE_GOLDENS=1 to create the golden file');
    expect(actual, goldenFile.readAsStringSync());
  });

  group('validation errors', () {
    Future<void> expectBuildError(String source, String fragment) async {
      final logs = <LogRecord>[];
      await testBuilder(
        builder(),
        inputs({'lib/models.dart': source}),
        onLog: logs.add,
      );
      final severe = logs.where((l) => l.level >= Level.SEVERE).toList();
      expect(
        severe.any((l) => '$l'.contains(fragment)),
        isTrue,
        reason: 'expected a SEVERE log containing "$fragment", got:\n'
            '${severe.map((l) => '  $l').join('\n')}',
      );
    }

    test('unknown relation target', () async {
      await expectBuildError(
        '''
import 'package:dbkit/src/annotations.dart';
part 'models.g.dart';

class Post {
  final int? id;
  const Post({this.id});
}

@DbTable('users')
@HasMany(Post, name: 'posts', foreignKey: 'userId')
class User {
  @DbId()
  final int? id;
  final String name;
  const User({this.id, required this.name});
  factory User.fromMap(Map<String, Object?> map) => _\$UserFromMap(map);
  Map<String, Object?> toMap() => _\$UserToMap(this);
}
''',
        'is not annotated with @DbTable',
      );
    });

    test('unknown foreign key field', () async {
      await expectBuildError(
        '''
import 'package:dbkit/src/annotations.dart';
part 'models.g.dart';

@DbTable('posts')
class Post {
  @DbId()
  final int? id;
  final String title;
  const Post({this.id, required this.title});
  factory Post.fromMap(Map<String, Object?> map) => _\$PostFromMap(map);
  Map<String, Object?> toMap() => _\$PostToMap(this);
}

@DbTable('users')
@HasMany(Post, name: 'posts', foreignKey: 'ownerId')
class User {
  @DbId()
  final int? id;
  final String name;
  const User({this.id, required this.name});
  factory User.fromMap(Map<String, Object?> map) => _\$UserFromMap(map);
  Map<String, Object?> toMap() => _\$UserToMap(this);
}
''',
        'unknown foreignKey field "ownerId"',
      );
    });

    test('field missing from constructor is rejected', () async {
      await expectBuildError(
        '''
import 'package:dbkit/src/annotations.dart';
part 'models.g.dart';

@DbTable('users')
class User {
  @DbId()
  final int? id;
  final String name;
  const User({this.id});
  factory User.fromMap(Map<String, Object?> map) => _\$UserFromMap(map);
  Map<String, Object?> toMap() => _\$UserToMap(this);
}
''',
        'not a named `this.` constructor parameter',
      );
    });

    test('@DbIgnore exempts computed getters', () async {
      await testBuilder(
        builder(),
        inputs({
          'lib/models.dart': '''
import 'package:dbkit/src/annotations.dart';
part 'models.g.dart';

@DbTable('users')
class User {
  @DbId()
  final int? id;
  final String name;
  const User({this.id, required this.name});
  factory User.fromMap(Map<String, Object?> map) => _\$UserFromMap(map);
  Map<String, Object?> toMap() => _\$UserToMap(this);

  @DbIgnore()
  String get displayName => name.toUpperCase();

  @override
  int get hashCode => Object.hash(id, name);
}
''',
        }),
        outputs: {
          'a|lib/models.dbkit.g.part': decodedMatches(
            contains('class UserTable {'),
          ),
        },
      );
    });

    test('List-typed field suggests class-level relations', () async {
      await expectBuildError(
        '''
import 'package:dbkit/src/annotations.dart';
part 'models.g.dart';

@DbTable('posts')
class Post {
  @DbId()
  final int? id;
  final String title;
  const Post({this.id, required this.title});
  factory Post.fromMap(Map<String, Object?> map) => _\$PostFromMap(map);
  Map<String, Object?> toMap() => _\$PostToMap(this);
}

@DbTable('users')
class User {
  @DbId()
  final int? id;
  final String name;
  final List<Post>? posts;
  const User({this.id, required this.name, this.posts});
  factory User.fromMap(Map<String, Object?> map) => _\$UserFromMap(map);
  Map<String, Object?> toMap() => _\$UserToMap(this);
}
''',
        'looks like a relation',
      );
    });

    test('composite primary keys are rejected', () async {
      await expectBuildError(
        '''
import 'package:dbkit/src/annotations.dart';
part 'models.g.dart';

@DbTable('post_tags')
class PostTag {
  @DbColumn(primaryKey: true)
  final int postId;
  @DbColumn(primaryKey: true)
  final int tagId;
  const PostTag({required this.postId, required this.tagId});
  factory PostTag.fromMap(Map<String, Object?> map) => _\$PostTagFromMap(map);
  Map<String, Object?> toMap() => _\$PostTagToMap(this);
}
''',
        'composite primary keys are not supported',
      );
    });

    test('timestamps require nullable DateTime fields', () async {
      await expectBuildError(
        '''
import 'package:dbkit/src/annotations.dart';
part 'models.g.dart';

@DbTable('events', timestamps: true)
class Event {
  @DbId()
  final int? id;
  final String name;
  const Event({this.id, required this.name});
  factory Event.fromMap(Map<String, Object?> map) => _\$EventFromMap(map);
  Map<String, Object?> toMap() => _\$EventToMap(this);
}
''',
        'needs a nullable `DateTime? createdAt` field',
      );
    });
  });
}

/// Rich single-file fixture: all four relation kinds, FK references,
/// defaults, unique columns and indexes.
const _models = r'''
import 'package:dbkit/src/annotations.dart';
part 'models.g.dart';

@DbTable('users')
@HasMany(Post, name: 'posts', foreignKey: 'userId', orderBy: 'title', limit: 10)
@HasOne(Profile, name: 'profile', foreignKey: 'userId')
class User {
  @DbId()
  final int? id;
  final String name;
  final int? age;
  final bool active;
  const User({this.id, required this.name, this.age, this.active = true});
  factory User.fromMap(Map<String, Object?> map) => _$UserFromMap(map);
  Map<String, Object?> toMap() => _$UserToMap(this);
}

@DbTable('profiles')
class Profile {
  @DbId()
  final int? id;
  @DbColumn(name: 'user_id', references: 'users')
  final int userId;
  final String? bio;
  const Profile({this.id, required this.userId, this.bio});
  factory Profile.fromMap(Map<String, Object?> map) => _$ProfileFromMap(map);
  Map<String, Object?> toMap() => _$ProfileToMap(this);
}

@DbTable('posts')
@BelongsTo(User, name: 'author', foreignKey: 'userId')
@BelongsToMany(Tag, name: 'tags', pivot: 'post_tags', fromKey: 'post_id', toKey: 'tag_id')
@DbIndex(['userId'])
class Post {
  @DbId()
  final int? id;
  @DbColumn(name: 'user_id', references: 'users')
  final int userId;
  final String title;
  @DbColumn(defaultValue: false)
  final bool published;
  const Post({this.id, required this.userId, required this.title, this.published = false});
  factory Post.fromMap(Map<String, Object?> map) => _$PostFromMap(map);
  Map<String, Object?> toMap() => _$PostToMap(this);
}

@DbTable('tags')
class Tag {
  @DbId()
  final int? id;
  @DbColumn(unique: true)
  final String label;
  const Tag({this.id, required this.label});
  factory Tag.fromMap(Map<String, Object?> map) => _$TagFromMap(map);
  Map<String, Object?> toMap() => _$TagToMap(this);
}

@DbTable('post_tags')
class PostTag {
  @DbId()
  final int? id;
  @DbColumn(name: 'post_id', references: 'posts')
  final int postId;
  @DbColumn(name: 'tag_id', references: 'tags')
  final int tagId;
  const PostTag({this.id, required this.postId, required this.tagId});
  factory PostTag.fromMap(Map<String, Object?> map) => _$PostTagFromMap(map);
  Map<String, Object?> toMap() => _$PostTagToMap(this);
}
''';
