# dbkit_gen example

Annotate plain Dart classes, run `build_runner`, get a typed database
client. Full runnable demo: [`package:dbkit/example/blog`](../../dbkit/example/blog).

```dart
// models.dart
import 'package:dbkit/dbkit.dart';

part 'models.g.dart';

@DbTable('users')
@HasMany(Post, name: 'posts', foreignKey: 'userId')
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

```sh
dart run build_runner build   # generates models.g.dart next to models.dart
```

```dart
final db = Db.memory();
await createAllTables(db);
registerAllRelations(db);

var ada = await db.users.save(const User(name: 'Ada'));
await db.posts.save(Post(userId: ada.id!, title: 'Hello'));

print(await ada.posts(db)); // hasMany → List<Post>
final rows = await db.users.withPosts(); // eager → UserWithPosts
print('${rows.single.user.name} wrote ${rows.single.posts.length} post(s)');
```

Every named `this.` constructor parameter becomes a column. Mark computed
members with `@DbIgnore()` (`hashCode`/`runtimeType` are always ignored).
