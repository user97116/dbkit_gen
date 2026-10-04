# 0.3.0

- `save` on autoincrement tables returns the saved model with its id.
- Per-file aggregates `createAllTables` / `dropAllTables` /
  `registerAllRelations` for one-call setup.
- New `@DbIgnore()` for computed members (`hashCode` / `runtimeType`
  overrides are always ignored); columns come from named `this.`
  constructor parameters.
- Generated `all()` delegates to `list()` (single implementation);
  per-model helpers avoid collisions in combined parts; pivot loaders use
  the typed `ref` handle; bool decoding is inline.

# 0.1.0

- Initial release: annotate models (`@DbTable`, `@DbColumn`, `@DbId`,
  `@DbIndex`, `@HasMany`/`@HasOne`/`@BelongsTo`/`@BelongsToMany`) and run
  `build_runner` to generate them.
- Generates `fromMap`/`toMap` helpers, column constants, table repositories
  (`all`/`list`/`findById`/`save`/`update`/…), lazy relation loaders,
  many-to-many link helpers, eager-load wrappers, `create`/`drop`/
  `registerRelations` setup functions, and a `Db` extension.
