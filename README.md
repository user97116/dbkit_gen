# dbkit_gen

Code generator for [dbkit](../dbkit). Annotate plain Dart classes, run
`build_runner`, get typed Dart — `fromMap`/`toMap` helpers, table
repositories with query helpers, column constants, relationship loaders
and link helpers, eager-load wrappers, plus schema setup functions.

```sh
dart run build_runner build
```

```dart
import 'package:dbkit/dbkit.dart';

part 'models.g.dart';

@DbTable('users')
@HasMany(Post, name: 'posts', foreignKey: 'userId')
@HasOne(Profile, name: 'profile', foreignKey: 'userId')
class User {
  @DbId()
  final int? id;
  final String name;

  const User({this.id, required this.name});

  factory User.fromMap(Map<String, Object?> map) => _$UserFromMap(map);
  Map<String, Object?> toMap() => _$UserToMap(this);
}

@DbTable('posts')
@BelongsTo(User, name: 'author', foreignKey: 'userId')
@BelongsToMany(Tag, name: 'tags', pivot: 'post_tags',
    fromKey: 'post_id', toKey: 'tag_id')
class Post {
  @DbId()
  final int? id;
  @DbColumn(name: 'user_id', references: 'users')
  final int userId;
  final String title;

  const Post({this.id, required this.userId, required this.title});

  factory Post.fromMap(Map<String, Object?> map) => _$PostFromMap(map);
  Map<String, Object?> toMap() => _$PostToMap(this);
}
```

```dart
// db.users.all() instead of List<Map<String, Object?>>
var ada = await db.users.save(const User(name: 'Ada'));
final posts = await ada.posts(db); // hasMany → typed List<Post>
final profile = await ada.profile(db); // hasOne → Profile? (single object)
final author = await post.author(db); // belongsTo → User? (single object)
await post.addTag(db, tag); // belongsToMany link helpers
final withTags = await db.posts.withTags(); // typed wrappers
```

Add it as a dev dependency (it never ships in your app):

```yaml
dev_dependencies:
  build_runner: ^2.4.0
  dbkit_gen:
    path: ../dbkit_gen # or hosted once published
```

No `build.yaml` needed in consumers — just the `part 'models.g.dart';`
directive and `dart run build_runner build`.

## Annotations

| Annotation | Use |
|---|---|
| `@DbTable('users')` | Marks a model class. Every named `this.` ctor param becomes a column. |
| `@DbId()` | Integer autoincrement PK (`INTEGER PRIMARY KEY AUTOINCREMENT`). |
| `@DbColumn(name: 'user_id', references: 'users', unique: true, defaultValue: false, ...)` | Column options: rename, FK (`references` + `referencesColumn`/`onDelete`/`onUpdate`), `unique`, `defaultValue`, `defaultNow`, `check`, `primaryKey`. |
| `@DbIgnore()` | Excludes a computed member from codegen (`hashCode`/`runtimeType` are always ignored). |
| `@DbIndex(['age'])` | Secondary index (repeatable, `name:`/`unique:` optional). |
| `@HasMany(Post, name: 'posts', foreignKey: 'userId')` | One → many. FK on target. Generates `posts(db)` → `List<Post>`, `withPosts()` → `UserWithPosts`. `orderBy`/`desc`/`limit` optional. |
| `@HasOne(Profile, name: 'profile', foreignKey: 'userId')` | One → one. FK on target. Generates `profile(db)` → `Profile?` (single object), `withProfile()` → `UserWithProfile`. |
| `@BelongsTo(User, name: 'author', foreignKey: 'userId')` | Many → one. FK on this table. Generates `author(db)` → `User?` (single object), `withAuthor()` → `PostWithAuthor`. |
| `@BelongsToMany(Tag, name: 'tags', pivot: 'post_tags', fromKey: 'post_id', toKey: 'tag_id')` | Many ↔ many via pivot. Generates `tags(db)` → `List<Tag>`, `addTag`/`removeTag`, `withTags()` → `PostWithTags`. |

Column types: `int` (`integer`), `String` (`text`), `double` (`real`),
`bool` (`boolean`, stored as `0`/`1`), `DateTime` (`datetime`, ISO-8601
text), `Uint8List` (`blob`).

Field nullability decides nullability: `int? age` is nullable,
`String name` is `NOT NULL`. Every column field needs a matching named
`this.` constructor parameter (computed getters like `hashCode` are
ignored — columns come from the constructor, so `copyWith`/`==`/`toString`
are safe to add).

`@DbTable('posts', timestamps: true)` adds `created_at` / `updated_at`
(`CURRENT_TIMESTAMP`) columns. The model must declare matching nullable
fields (`DateTime? createdAt` / `DateTime? updatedAt`); they round-trip
through `fromMap`/`toMap` like any other column.

Rules the validator enforces (all reported at once, with paths like
`User.posts`): known FK/index/relation targets and key columns, single
primary key (no composites), Dart-safe and collision-free model/field/
relation names.

## Generated API

For a `users` table with model `User`:

| Generated | Use |
|---|---|
| `User`, `User.fromMap`, `toMap`, `copyWith`, `==` | Typed rows. |
| `UserColumns.name` | Refactor-safe queries: `w.eq(UserColumns.age, 18)`. |
| `db.users` (`UserTable`) | `all`, `list(where:...)`, `findById`, `findByIdOrFail`, `findOne`, `count`, `exists`, `insert`, `insertMany`, `save` (insert or replace by id), `update`, `updateById`, `deleteById`, `deleteWhere`, plus `ref` for anything custom. |
| `user.posts(db)`, `user.profile(db)`, `post.author(db)`, `post.tags(db)` | Lazy loaders: `List` for has-many / many-to-many, nullable single for has-one/belongs-to. |
| `post.addTag(db, tag)`, `post.removeTag(db, tag)` | Many-to-many link helpers. |
| `db.users.withPosts(...)`, `db.posts.withTags(...)` | Eager loading into `UserWithPosts(user, posts)` wrappers (filter/order/limit/offset supported). |
| `createAllTables(db)`, `dropAllTables(db)` | Schema setup/teardown for every table in the file (FK order handled). |
| `registerAllRelations(db)` (+ per-table `createUserTable` / `registerUserRelations`) | Defines every declared relationship. |

Notes:

- `insert` omits null fields so autoincrement ids and DB defaults apply;
  `update(model)` leaves null fields untouched (use `ref.updateById` with an
  explicit map to write `NULL`).
- `bool` reads accept both `1`/`0` and `true`/`false`; `double` reads accept
  ints; datetimes parse ISO-8601.
- `save` on autoincrement tables returns the saved model with its id
  (re-read after insert, or the upserted value).

## Typical setup

```dart
import 'package:dbkit/dbkit.dart';
import 'models.dart'; // annotated models (part 'models.g.dart')

Future<Db> openBlog() async {
  final db = Db.open('blog.db'); // or Db.memory(), Db.fake() in tests
  await createAllTables(db);
  registerAllRelations(db);
  return db;
}
```

## Running tests

```sh
dart test
dart analyze lib test
```

Golden output in `test/fixtures/models.expected.part` is compared verbatim;
regenerate after intentional emitter changes with
`DBKIT_UPDATE_GOLDENS=1 dart test test/builder_test.dart --plain-name "golden part output"`.
The checked-in generated client in `package:dbkit/test/gen/` is exercised
at runtime on both backends by `generated_test.dart`.

## Project structure & commands

```text
lib/dbkit_gen.dart        # public surface (builder, resolver, schema, emitter)
lib/builder.dart          # build_runner entry: SharedPartBuilder -> .g.dart
lib/src/table_generator.dart # source_gen Generator (one fragment per @DbTable)
lib/src/resolver.dart     # annotations + fields -> TableSchema (+ validation)
lib/src/schema.dart       # TableSchema / ColumnSchema / RelationSchema model
lib/src/emitter.dart      # TableSchema -> .g.part source
build.yaml                # declares the dbkit_tables builder (auto-applied)
test/builder_test.dart    # end-to-end builder tests + validation errors
test/emitter_test.dart    # emitter unit tests (hand-built schemas)
test/fixtures/           # golden part output + shared fixture sources
```

```sh
dart test
dart analyze lib test
```

Live, runnable examples of generated code live in `package:dbkit`:
`example/blog/` (typed CRUD + all four relation kinds) and `test/gen/`
(generator fixture + `generated_test.dart` on both backends).

## License

MIT — see `LICENSE`.
