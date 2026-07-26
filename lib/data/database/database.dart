import 'package:drift/drift.dart';

import '../models/version_info.dart';

part 'database.g.dart';

/// 收藏表：记录用户收藏的模拟器。
///
/// - [emulatorId] 主键，对应 Emulator.id
/// - [consoleId] 所属机种，便于按机种分组展示
/// - [addedAt] 收藏时间（Unix 毫秒时间戳）
/// - [notify] 是否对该模拟器的新版本启用通知
@DataClassName('Favorite')
class Favorites extends Table {
  TextColumn get emulatorId => text()();
  TextColumn get consoleId => text()();
  IntColumn get addedAt => integer()();
  BoolColumn get notify => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {emulatorId};
}

/// 版本缓存表：缓存每个模拟器最近一次版本检查的结果。
///
/// - [emulatorId] 主键，对应 Emulator.id
/// - [currentVersion] 当前已知的最新版本号
/// - [lastCheckedAt] 上次检查时间（Unix 毫秒时间戳）
/// - [lastReleaseDate] 上次发现的发布时间（Unix 毫秒时间戳，可为空）
/// - [releaseNotes] 版本更新说明，可为空
/// - [isNew] 是否存在尚未被用户查看的新版本
/// - [resolvedDownloadUrl] 适配器动态解析的最新版直链下载地址，避免静态 URL 404
@DataClassName('CachedVersion')
class CachedVersions extends Table {
  TextColumn get emulatorId => text()();
  TextColumn get currentVersion => text()();
  IntColumn get lastCheckedAt => integer()();
  IntColumn get lastReleaseDate => integer().nullable()();
  TextColumn get releaseNotes => text().nullable()();
  BoolColumn get isNew => boolean().withDefault(const Constant(false))();

  /// 动态解析的下载直链，由适配器在版本检查时写入。
  /// 为 null 时回退到 emulators.json 中的静态 downloadUrl。
  TextColumn get resolvedDownloadUrl => text().nullable()();

  /// 动态解析的**开发版**下载直链，由适配器在版本检查时从 prerelease 提取。
  /// 为 null 时回退到 emulators.json 中的静态 devUrl。
  TextColumn get resolvedDevDownloadUrl => text().nullable()();

  /// 动态解析的**每夜版**下载直链，由适配器从 nightlyUrl 仓库提取。
  /// 为 null 时回退到 emulators.json 中的静态 nightlyUrl。
  TextColumn get resolvedNightlyDownloadUrl => text().nullable()();

  /// 开发版/预览版的更新说明（从 prerelease body 提取）。
  TextColumn get devReleaseNotes => text().nullable()();

  /// 每夜版的更新说明（从 nightly release body 提取）。
  TextColumn get nightlyReleaseNotes => text().nullable()();

  /// 动态解析的**预览版**下载直链，由适配器从 prerelease 提取。
  /// 为 null 时回退到 emulators.json 中的静态 previewUrl。
  TextColumn get resolvedPreviewDownloadUrl => text().nullable()();

  /// 预览版的更新说明（从 prerelease body 提取）。
  TextColumn get previewReleaseNotes => text().nullable()();

  @override
  Set<Column> get primaryKey => {emulatorId};
}

/// 收藏表的数据访问对象。
///
/// 提供收藏的增删查改、通知开关切换以及响应式监听。
@DriftAccessor(tables: [Favorites])
class FavoritesDao extends DatabaseAccessor<AppDatabase>
    with _$FavoritesDaoMixin {
  FavoritesDao(super.db);

  /// 获取全部收藏，按添加时间降序排列（最新收藏在前）。
  Future<List<Favorite>> getAllFavorites() {
    return (select(favorites)
          ..orderBy([(f) => OrderingTerm.desc(f.addedAt)]))
        .get();
  }

  /// 监听全部收藏的实时变化。
  Stream<List<Favorite>> watchAllFavorites() {
    return (select(favorites)
          ..orderBy([(f) => OrderingTerm.desc(f.addedAt)]))
        .watch();
  }

  /// 根据 [emulatorId] 查询单条收藏，不存在时返回 null。
  Future<Favorite?> getFavorite(String emulatorId) {
    return (select(favorites)
          ..where((f) => f.emulatorId.equals(emulatorId)))
        .getSingleOrNull();
  }

  /// 判断指定模拟器是否已被收藏。
  Future<bool> isFavorite(String emulatorId) async {
    final row = await getFavorite(emulatorId);
    return row != null;
  }

  /// 新增或更新收藏（按主键 [emulatorId] 冲突时覆盖更新）。
  Future<void> upsertFavorite(FavoritesCompanion entry) async {
    await into(favorites).insertOnConflictUpdate(entry);
  }

  /// 收藏指定模拟器，并记录当前时间作为收藏时间。
  Future<void> addFavorite({
    required String emulatorId,
    required String consoleId,
    bool notify = true,
  }) async {
    await into(favorites).insertOnConflictUpdate(
      FavoritesCompanion(
        emulatorId: Value(emulatorId),
        consoleId: Value(consoleId),
        addedAt: Value(DateTime.now().millisecondsSinceEpoch),
        notify: Value(notify),
      ),
    );
  }

  /// 取消收藏指定模拟器。
  Future<void> removeFavorite(String emulatorId) async {
    await (delete(favorites)
          ..where((f) => f.emulatorId.equals(emulatorId)))
        .go();
  }

  /// 切换指定模拟器的新版本通知开关。
  Future<void> setNotify(String emulatorId, bool notify) async {
    await (update(favorites)
          ..where((f) => f.emulatorId.equals(emulatorId)))
        .write(FavoritesCompanion(notify: Value(notify)));
  }

  /// 返回已开启通知的收藏数量（用于后台检查任务排程）。
  Future<int> countNotifiableFavorites() async {
    final result = await (select(favorites)
          ..where((f) => f.notify.equals(true)))
        .get();
    return result.length;
  }
}

/// 版本缓存表的数据访问对象。
///
/// 提供版本缓存的读写、新版本标记与查看、以及响应式监听。
@DriftAccessor(tables: [CachedVersions])
class CachedVersionsDao extends DatabaseAccessor<AppDatabase>
    with _$CachedVersionsDaoMixin {
  CachedVersionsDao(super.db);

  /// 获取全部已缓存的版本记录。
  Future<List<CachedVersion>> getAllCachedVersions() {
    return select(cachedVersions).get();
  }

  /// 监听全部版本缓存的实时变化。
  Stream<List<CachedVersion>> watchAllCachedVersions() {
    return select(cachedVersions).watch();
  }

  /// 根据 [emulatorId] 查询单条版本缓存，不存在时返回 null。
  Future<CachedVersion?> getCachedVersion(String emulatorId) {
    return (select(cachedVersions)
          ..where((c) => c.emulatorId.equals(emulatorId)))
        .getSingleOrNull();
  }

  /// 监听指定模拟器的版本缓存变化，不存在时流中产出 null。
  Stream<CachedVersion?> watchCachedVersion(String emulatorId) {
    return (select(cachedVersions)
          ..where((c) => c.emulatorId.equals(emulatorId)))
        .watchSingleOrNull();
  }

  /// 新增或更新版本缓存（按主键 [emulatorId] 冲突时覆盖更新）。
  Future<void> upsertCachedVersion(CachedVersionsCompanion entry) async {
    await into(cachedVersions).insertOnConflictUpdate(entry);
  }

  /// 将一个 [VersionInfo]（版本检查结果）写入缓存，并刷新检查时间。
  Future<void> upsertFromVersionInfo(VersionInfo info) async {
    await into(cachedVersions).insertOnConflictUpdate(
      CachedVersionsCompanion(
        emulatorId: Value(info.emulatorId),
        currentVersion: Value(info.version),
        lastReleaseDate: Value(info.releaseDate.millisecondsSinceEpoch),
        releaseNotes: Value(info.releaseNotes),
        isNew: Value(info.isNew),
        resolvedDownloadUrl: Value(info.downloadUrl),
        resolvedDevDownloadUrl: Value(info.devDownloadUrl),
        resolvedNightlyDownloadUrl: Value(info.nightlyDownloadUrl),
        devReleaseNotes: Value(info.devReleaseNotes),
        nightlyReleaseNotes: Value(info.nightlyReleaseNotes),
        resolvedPreviewDownloadUrl: Value(info.previewDownloadUrl),
        previewReleaseNotes: Value(info.previewReleaseNotes),
        lastCheckedAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
  }

  /// 将指定模拟器的“新版本”标记清除（用户已查看）。
  Future<void> markAsSeen(String emulatorId) async {
    await (update(cachedVersions)
          ..where((c) => c.emulatorId.equals(emulatorId)))
        .write(const CachedVersionsCompanion(isNew: Value(false)));
  }

  /// 删除指定模拟器的版本缓存。
  Future<void> removeCachedVersion(String emulatorId) async {
    await (delete(cachedVersions)
          ..where((c) => c.emulatorId.equals(emulatorId)))
        .go();
  }
}

/// 应用本地数据库。
///
/// 持有 [Favorites] 与 [CachedVersions] 两张表，并通过 [daos] 暴露
/// [FavoritesDao] / [CachedVersionsDao] 两个数据访问对象。
///
/// 使用方式：
/// ```dart
/// final db = AppDatabase(NativeDatabase.createInBackground(file));
/// db.favoritesDao.watchAllFavorites();
/// db.cachedVersionsDao.getCachedVersion('ppsspp');
/// ```
@DriftDatabase(
  tables: [Favorites, CachedVersions],
  daos: [FavoritesDao, CachedVersionsDao],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 6;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (m) => m.createAll(),
      onUpgrade: (m, from, to) async {
        if (from < 2) {
          await m.addColumn(cachedVersions, cachedVersions.resolvedDownloadUrl);
        }
        if (from < 3) {
          await m.addColumn(
              cachedVersions, cachedVersions.resolvedDevDownloadUrl);
        }
        if (from < 4) {
          await m.addColumn(
              cachedVersions, cachedVersions.resolvedNightlyDownloadUrl);
        }
        if (from < 5) {
          await m.addColumn(cachedVersions, cachedVersions.devReleaseNotes);
          await m.addColumn(cachedVersions, cachedVersions.nightlyReleaseNotes);
        }
        if (from < 6) {
          await m.addColumn(
              cachedVersions, cachedVersions.resolvedPreviewDownloadUrl);
          await m.addColumn(cachedVersions, cachedVersions.previewReleaseNotes);
        }
      },
    );
  }
}
