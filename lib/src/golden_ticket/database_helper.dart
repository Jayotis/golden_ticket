import 'dart:io'; // For file operations (deleting the database file)
import 'package:path_provider/path_provider.dart'; // To find the local file system path
import 'package:sqflite/sqflite.dart'; // For SQLite DB operations
import 'package:sqflite/sqlite_api.dart'; // For batch operations
import 'ingot_crucible.dart'; // Data model for user's selected combinations
import 'dart:convert'; // For encoding/decoding JSON
import 'GameResultData.dart'; // Data model for cached game results
import 'game_rules.dart'; // Data model for game rules
import 'package:logging/logging.dart'; // Logging framework
import 'logging_utils.dart'; // Logger setup utility

/// Model representing a user's active game selection.
/// This table records which games a user has currently activated, and when.
/// Deactivation is soft (row remains, with deactivated_at set).
class UserActiveGame {
  final int id; // Primary key
  final int userId; // Reference to user
  final String gameName; // Name of the game
  final DateTime activatedAt; // When the game was activated
  final DateTime? deactivatedAt; // When the game was deactivated, if any

  UserActiveGame({
    required this.id,
    required this.userId,
    required this.gameName,
    required this.activatedAt,
    this.deactivatedAt,
  });

  /// Construct a UserActiveGame from a database row (map).
  factory UserActiveGame.fromMap(Map<String, dynamic> map) => UserActiveGame(
        id: map['id'],
        userId: map['user_id'],
        gameName: map['game_name'],
        activatedAt: DateTime.parse(map['activated_at']),
        deactivatedAt: map['deactivated_at'] != null ? DateTime.tryParse(map['deactivated_at']) : null,
      );
}

// --- GameDrawInfo Class Definition ---
final _logGameDrawInfo = Logger('GameDrawInfo');
/// Contains information about a specific game draw, including combination limits and request counters.
class GameDrawInfo {
  final String gameName;
  final String drawDate;
  final int? totalCombinations;
  final int? userRequestLimit;
  final int? userCombinationsRequested;
  final String? archiveChecksum;
  final DateTime? lastUpdated;

  GameDrawInfo({
    required this.gameName,
    required this.drawDate,
    this.totalCombinations,
    this.userRequestLimit,
    this.userCombinationsRequested,
    this.archiveChecksum,
    this.lastUpdated,
  });

  /// Convert this object to a map for database storage.
  Map<String, dynamic> toMap() {
    return {
      'game_name': gameName,
      'draw_date': drawDate,
      'total_combinations': totalCombinations,
      'user_request_limit': userRequestLimit,
      'user_combinations_requested': userCombinationsRequested,
      'archive_checksum': archiveChecksum,
      'last_updated': lastUpdated?.toIso8601String(),
    };
  }

  /// Construct a GameDrawInfo from a database row (map).
  factory GameDrawInfo.fromMap(Map<String, dynamic> map) {
    return GameDrawInfo(
      gameName: map['game_name'] as String,
      drawDate: map['draw_date'] as String,
      totalCombinations: map['total_combinations'] as int?,
      userRequestLimit: map['user_request_limit'] as int?,
      userCombinationsRequested: map['user_combinations_requested'] as int?,
      archiveChecksum: map['archive_checksum'] as String?,
      lastUpdated: map['last_updated'] != null ? DateTime.parse(map['last_updated']) : null,
    );
  }

  @override
  String toString() {
    return 'GameDrawInfo{gameName: $gameName, drawDate: $drawDate, totalCombinations: $totalCombinations, userRequestLimit: $userRequestLimit, userCombinationsRequested: $userCombinationsRequested, lastUpdated: $lastUpdated}';
  }
}

/// Singleton class for managing the application's SQLite database.
/// Handles schema creation, migrations, and all CRUD operations.
class DatabaseHelper {
  // --- Singleton Pattern Implementation ---
  DatabaseHelper._internal() {
    // Ensure logger is set up for this instance.
    LoggingUtils.setupLogger(_log);
  }
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  factory DatabaseHelper() => _instance;
  final _log = Logger('DatabaseHelper');
  static Database? _database;

  // Database version. Increment when changing schema.
  static const int _databaseVersion = 3; // Bump version when altering schema.
  // Filename for the SQLite database.
  static const String _databaseName = "play_cards.db";

  /// Return the database instance, initializing if needed.
  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  /// Initialize the database by opening the file and creating tables if necessary.
  Future<Database> _initDatabase() async {
    Directory documentsDirectory = await getApplicationDocumentsDirectory();
    String path = "${documentsDirectory.path}/$_databaseName";
    _log.info("Database path: $path (Version: $_databaseVersion)");
    return await openDatabase(
      path,
      version: _databaseVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  /// Called when creating a new database file. Creates all tables and populates defaults.
  Future<void> _onCreate(Database db, int version) async {
    _log.info("Creating database schema (version $version)...");
    await _createAllTables(db);
    _log.info("Database tables created.");
    _log.info("Populating game_rules table...");
    await _populateGameRules(db);
    _log.info("game_rules table populated.");
  }

  /// Called when upgrading the database version. Applies schema migrations.
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    _log.warning("Upgrading database from version $oldVersion to $newVersion...");
    // Migration for user_active_games table (version 3)
    if (oldVersion < 3) {
      _log.info("Adding user_active_games table for v3...");
      await db.execute('''
        CREATE TABLE IF NOT EXISTS user_active_games(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          user_id INTEGER NOT NULL,
          game_name TEXT NOT NULL,
          activated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
          deactivated_at DATETIME
        )
      ''');
      _log.info("user_active_games table created (upgrade).");
    }
    _log.info("Database upgrade complete.");
  }

  /// Create all database tables using a batch operation.
  Future<void> _createAllTables(Database db) async {
    Batch batch = db.batch();
    _createIngotCruciblesTable(batch);
    _createGameResultsCacheTable(batch);
    _createUserProfilesTable(batch);
    _createUserGameProgressTable(batch);
    _createGameRulesTable(batch);
    _createGameDrawInfoTable(batch);
    _createIngotCollectionTable(batch);
    _createUserActiveGamesTable(batch); // Add user_active_games table
    await batch.commit(noResult: true);
  }

  /// Defines and creates the user_active_games table, which tracks games a user has activated.
  /// Each row indicates a game the user is currently playing (deactivated_at IS NULL) or has played in the past.
  void _createUserActiveGamesTable(Batch batch) {
    batch.execute('''
      CREATE TABLE IF NOT EXISTS user_active_games(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        game_name TEXT NOT NULL,
        activated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        deactivated_at DATETIME
      )
    ''');
    _log.fine("Schema: user_active_games defined.");
    // Create index for fast lookups by user_id.
    batch.execute('CREATE INDEX IF NOT EXISTS idx_user_active_games_user ON user_active_games (user_id)');
  }

  /// Defines and creates the 'ingot_crucibles' table schema (formerly 'play_cards').
  void _createIngotCruciblesTable(Batch batch) {
    batch.execute('''
      CREATE TABLE ingot_crucibles(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT,
        user_id INTEGER,
        submitted_date TEXT NOT NULL,
        status TEXT NOT NULL,
        combinations TEXT NOT NULL,
        draw_date TEXT NOT NULL
      )
    ''');
    _log.fine("Schema: ingot_crucibles defined.");
    batch.execute('CREATE INDEX IF NOT EXISTS idx_crucible_user_draw ON ingot_crucibles (user_id, draw_date)');
    _log.fine("Index: idx_crucible_user_draw defined.");
  }

  /// Defines and creates the 'game_results_cache' table schema.
  void _createGameResultsCacheTable(Batch batch) {
    batch.execute('''
      CREATE TABLE game_results_cache(
        game_name TEXT NOT NULL,
        draw_date TEXT NOT NULL,
        last_draw_numbers TEXT,
        bonus_number INTEGER,
        total_combinations INTEGER,
        odds_6_6 REAL,
        odds_5_6_plus REAL,
        odds_5_6 REAL,
        odds_4_6 REAL,
        odds_3_6 REAL,
        odds_2_6_plus REAL,
        odds_2_6 REAL,
        odds_any_prize REAL,
        user_score INTEGER,
        fetched_at TEXT NOT NULL,
        new_draw_flag INTEGER DEFAULT 0 NOT NULL,
        win_id TEXT,
        archive_password TEXT,
        archive_checksum TEXT,
        PRIMARY KEY (game_name, draw_date)
      )
    ''');
    _log.fine("Schema: game_results_cache defined.");
  }

  /// Defines and creates the 'user_profiles' table schema.
  void _createUserProfilesTable(Batch batch) {
    batch.execute('''
      CREATE TABLE user_profiles(
        user_id INTEGER PRIMARY KEY,
        membership_level TEXT,
        global_awards TEXT,
        global_statistics TEXT,
        last_updated TEXT NOT NULL
      )
    ''');
    _log.fine("Schema: user_profiles defined.");
  }

  /// Defines and creates the 'user_game_progress' table schema.
  void _createUserGameProgressTable(Batch batch) {
    batch.execute('''
      CREATE TABLE user_game_progress(
        user_id INTEGER NOT NULL,
        game_name TEXT NOT NULL,
        game_score INTEGER NOT NULL DEFAULT 0,
        game_awards TEXT,
        game_statistics TEXT,
        membership_level TEXT,
        last_played TEXT,
        PRIMARY KEY (user_id, game_name),
        FOREIGN KEY (user_id) REFERENCES user_profiles(user_id) ON DELETE CASCADE
      )
    ''');
    _log.fine("Schema: user_game_progress defined.");
    batch.execute('CREATE INDEX IF NOT EXISTS idx_user_game_progress_user ON user_game_progress (user_id)');
    _log.fine("Index: idx_user_game_progress_user defined.");
  }

  /// Defines and creates the 'game_rules' table schema.
  void _createGameRulesTable(Batch batch) {
    batch.execute('''
      CREATE TABLE game_rules(
        game_name TEXT PRIMARY KEY NOT NULL,
        total_numbers INTEGER NOT NULL,
        regular_balls_drawn INTEGER NOT NULL,
        bonus_ball_pool INTEGER NOT NULL,
        bonus_balls_drawn INTEGER NOT NULL,
        draw_schedule TEXT,
        prize_tier_format TEXT,
        official_odds_json TEXT
      )
    ''');
    _log.fine("Schema: game_rules defined.");
  }
  
  /// Fetches all game rules from the game_rules table.
  Future<List<GameRule>> fetchAllGameRules() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query('game_rules');
    // Use GameRule.fromMap for each row
    return List.generate(maps.length, (i) => GameRule.fromMap(maps[i]));
  }

  /// Defines and creates the 'game_draw_info' table schema.
  void _createGameDrawInfoTable(Batch batch) {
    batch.execute('''
      CREATE TABLE game_draw_info(
        game_name TEXT NOT NULL,
        draw_date TEXT NOT NULL,
        total_combinations INTEGER,
        user_request_limit INTEGER,
        user_combinations_requested INTEGER,
        last_updated TEXT,
        archive_checksum TEXT,
        PRIMARY KEY (game_name, draw_date)
      )
    ''');
    _log.fine("Schema: game_draw_info defined.");
  }

  /// Defines and creates the 'ingot_collection' table schema.
  void _createIngotCollectionTable(Batch batch) {
    batch.execute('''
      CREATE TABLE ingot_collection(
        ingot_id INTEGER PRIMARY KEY,
        user_id INTEGER NOT NULL,
        game_name TEXT NOT NULL,
        draw_date TEXT NOT NULL,
        numbers TEXT NOT NULL,
        added_timestamp TEXT NOT NULL
      )
    ''');
    batch.execute('CREATE INDEX IF NOT EXISTS idx_ingot_collection_user_game_draw ON ingot_collection (user_id, game_name, draw_date)');
    _log.fine("Schema: ingot_collection defined with index.");
  }

  /// Populates the 'game_rules' table with initial data defined in GameRules.gameRulesData.
  Future<void> _populateGameRules(Database db) async {
    Batch populateBatch = db.batch();
    for (final rule in GameRules.gameRulesData) {
      _log.fine("Inserting game rule: ${rule.toString()}");
      populateBatch.insert('game_rules', rule.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await populateBatch.commit(noResult: true);
    _log.info("game_rules table populated successfully.");
  }

  // --- User Active Games Methods ---

  /// Returns a list of game names for the games the user has activated (still active).
  /// Only rows where deactivated_at IS NULL are considered active.
  Future<List<String>> getActiveGamesForUser(int userId) async {
    final db = await database;
    final res = await db.query(
      'user_active_games',
      columns: ['game_name'],
      where: 'user_id = ? AND deactivated_at IS NULL',
      whereArgs: [userId],
    );
    // Only return the game_name values as a list of strings.
    return res.map((row) => row['game_name'] as String).toList();
  }

  /// Activates a game for the user.
  /// If the row exists and is deactivated, reactivates it. If it does not exist, inserts a new row.
  /// Now includes error handling and logging.
  Future<void> activateGameForUser(int userId, String gameName) async {
    try {
      final db = await database;
      // Query for an existing row for this user/game.
      final res = await db.query(
        'user_active_games',
        where: 'user_id = ? AND game_name = ?',
        whereArgs: [userId, gameName],
      );

      if (res.isNotEmpty && res.first['deactivated_at'] != null) {
        // Row exists but is currently deactivated: reactivate it.
        await db.update(
          'user_active_games',
          {
            'deactivated_at': null,
            'activated_at': DateTime.now().toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: [res.first['id']],
        );
        print('INFO: Reactivated game "$gameName" for user $userId.');
      } else if (res.isEmpty) {
        // No row exists: insert new active row.
        await db.insert('user_active_games', {
          'user_id': userId,
          'game_name': gameName,
          'activated_at': DateTime.now().toIso8601String(),
        });
        print('INFO: Activated new game "$gameName" for user $userId.');
      } else {
        // Already active, do nothing.
        print('INFO: Game "$gameName" already active for user $userId.');
      }
    } catch (e, stack) {
      // Log the error and optionally rethrow or handle as needed
      print('ERROR: Failed to activate game "$gameName" for user $userId: $e');
      print(stack);
      // Optionally: rethrow or handle error as appropriate for your app
      // throw e;
    }
  }

  /// Deactivates a game for the user (soft delete).
  /// Sets deactivated_at to current time, leaving the row for history.
  Future<void> deactivateGameForUser(int userId, String gameName) async {
    final db = await database;
    await db.update(
      'user_active_games',
      {'deactivated_at': DateTime.now().toIso8601String()},
      where: 'user_id = ? AND game_name = ? AND deactivated_at IS NULL',
      whereArgs: [userId, gameName],
    );
  }

  /// Returns a list of GameRule objects for all games the user currently has activated.
  /// This performs a join with the game_rules table to provide the full rules for each active game.
  Future<List<GameRule>> getActiveGameRulesForUser(int userId) async {
    final db = await database;
    final res = await db.rawQuery('''
      SELECT gr.* FROM game_rules gr
      JOIN user_active_games uag ON gr.game_name = uag.game_name
      WHERE uag.user_id = ? AND uag.deactivated_at IS NULL
    ''', [userId]);
    return res.map((row) => GameRule.fromMap(row)).toList();
  }

  // --- CRUD Methods for IngotCrucible ---

  /// Inserts a new IngotCrucible record or replaces an existing one if the ID matches.
  /// Returns the row ID of the inserted/replaced record.
  Future<int> insertIngotCrucible(IngotCrucible crucible) async {
    final db = await database;
    _log.fine("Inserting/Replacing IngotCrucible: ${crucible.toMap()}");
    int id = await db.insert(
      'ingot_crucibles',
      crucible.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _log.info("IngotCrucible inserted/replaced with ID: $id");
    return id;
  }

  /// Retrieves a specific IngotCrucible for a given user and draw date.
  /// Returns the IngotCrucible object or null if not found.
  Future<IngotCrucible?> getUserCrucibleForDraw(int userId, String drawDate) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'ingot_crucibles',
      where: 'user_id = ? AND draw_date = ?',
      whereArgs: [userId, drawDate],
      limit: 1,
    );
    if (maps.isNotEmpty) {
      _log.fine("Found IngotCrucible for user $userId, draw $drawDate: ${maps.first}");
      return IngotCrucible.fromMap(maps.first);
    } else {
      _log.fine("No IngotCrucible found for user $userId, draw $drawDate.");
      return null;
    }
  }

  /// Checks if an IngotCrucible record exists for a given user and draw date.
  /// Returns true if a record exists, false otherwise.
  Future<bool> hasCrucibleForDrawDate(int userId, String drawDate) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'ingot_crucibles',
      columns: ['id'],
      where: 'user_id = ? AND draw_date = ?',
      whereArgs: [userId, drawDate],
      limit: 1,
    );
    bool exists = maps.isNotEmpty;
    _log.fine("Checked for IngotCrucible existence for user $userId, draw $drawDate: $exists");
    return exists;
  }

  // --- CRUD Methods for Ingot Collection ---

  /// Adds a new ingot (combination) to the user's collection.
  /// Replaces if an ingot with the same ingotId already exists.
  Future<int> addIngotToCollection({
    required int userId,
    required String gameName,
    required String drawDate,
    required int ingotId,
    required List<int> numbers,
  }) async {
    final db = await database;
    final data = {
      'ingot_id': ingotId,
      'user_id': userId,
      'game_name': gameName,
      'draw_date': drawDate,
      'numbers': jsonEncode(numbers),
      'added_timestamp': DateTime.now().toIso8601String(),
    };
    _log.fine("Adding Ingot to Collection: $data");
    try {
      int id = await db.insert('ingot_collection', data, conflictAlgorithm: ConflictAlgorithm.replace);
      _log.info("Ingot ID $ingotId added/replaced in collection for $userId/$gameName/$drawDate. Result: $id");
      return id;
    } catch (e) {
      _log.severe("Error adding ingot $ingotId to collection: $e");
      rethrow;
    }
  }

  /// Retrieves all ingots from the collection for a specific user, game, and draw date.
  /// Returns a list of CombinationWithId objects.
  Future<List<CombinationWithId>> getIngotCollection(int userId, String gameName, String drawDate) async {
    final db = await database;
    List<CombinationWithId> collection = [];
    _log.fine("Getting Ingot Collection for $userId/$gameName/$drawDate");
    try {
      final List<Map<String, dynamic>> maps = await db.query(
        'ingot_collection',
        where: 'user_id = ? AND game_name = ? AND draw_date = ?',
        whereArgs: [userId, gameName, drawDate],
        orderBy: 'added_timestamp DESC',
      );
      for (var map in maps) {
        try {
          final numbersList = jsonDecode(map['numbers'] as String);
          if (numbersList is List) {
            collection.add(CombinationWithId(
              ingotId: map['ingot_id'] as int,
              numbers: numbersList.map((e) => int.parse(e.toString())).toList(),
            ));
          } else {
            _log.warning("Could not decode 'numbers' as List from ingot_collection: ${map['numbers']}");
          }
        } catch (e) {
          _log.warning("Error parsing ingot from map $map: $e");
        }
      }
      _log.info("Retrieved ${collection.length} ingots from collection for $userId/$gameName/$drawDate.");
    } catch (e) {
      _log.severe("Error getting ingot collection: $e");
    }
    return collection;
  }

  /// Removes a specific ingot from the collection based on its ID.
  /// Returns the number of rows affected (should be 0 or 1).
  Future<int> removeIngotFromCollection(int ingotId) async {
    final db = await database;
    _log.fine("Removing Ingot ID $ingotId from Collection.");
    try {
      int count = await db.delete('ingot_collection', where: 'ingot_id = ?', whereArgs: [ingotId]);
      if (count > 0) {
        _log.info("Removed Ingot ID $ingotId from collection.");
      } else {
        _log.warning("Ingot ID $ingotId not found in collection to remove.");
      }
      return count;
    } catch (e) {
      _log.severe("Error removing ingot $ingotId from collection: $e");
      rethrow;
    }
  }

  /// Clears (deletes) all ingots from the collection for a specific user, game, and draw date.
  /// Typically used after a crucible is successfully forged/submitted.
  /// Returns the number of rows affected.
  Future<int> clearIngotCollectionForDraw(int userId, String gameName, String drawDate) async {
    final db = await database;
    _log.fine("Clearing Ingot Collection for $userId/$gameName/$drawDate.");
    try {
      int count = await db.delete(
        'ingot_collection',
        where: 'user_id = ? AND game_name = ? AND draw_date = ?',
        whereArgs: [userId, gameName, drawDate],
      );
      _log.info("Cleared $count ingots from collection for $userId/$gameName/$drawDate.");
      return count;
    } catch (e) {
      _log.severe("Error clearing ingot collection for $userId/$gameName/$drawDate: $e");
      rethrow;
    }
  }

  // --- CRUD Methods for Game Results Cache ---

  /// Inserts or updates a game result in the cache table.
  /// Sets the 'new_draw_flag' based on whether actual draw numbers are present.
  Future<int> insertOrUpdateGameResultCache(GameResultData result) async {
    final db = await database;
    Map<String, dynamic> dataMap = result.toMap();
    if (result.drawNumbers != null && result.drawNumbers!.isNotEmpty) {
      dataMap['new_draw_flag'] = 1;
      _log.fine("Setting new_draw_flag to 1 for actual results: ${result.gameName}/${result.drawDate}");
    } else {
      dataMap['new_draw_flag'] = 0;
      _log.fine("Setting new_draw_flag to 0 for placeholder: ${result.gameName}/${result.drawDate}");
    }
    dataMap['fetched_at'] = DateTime.now().toIso8601String();

    _log.fine("Inserting/Replacing GameResultCache: ${dataMap.keys.map((k) => '$k: ${dataMap[k]}').join(', ')}");
    int resultId = await db.insert(
      'game_results_cache',
      dataMap,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _log.info("GameResultCache inserted/replaced for ${result.gameName}/${result.drawDate}. Result ID/Rows affected: $resultId. new_draw_flag was set to ${dataMap['new_draw_flag']}");
    return resultId;
  }

  /// Retrieves a cached game result for a specific game and draw date.
  /// Returns the GameResultData object or null if not found in cache.
  Future<GameResultData?> getGameResultFromCache(String gameName, String drawDate) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'game_results_cache',
      where: 'game_name = ? AND draw_date = ?',
      whereArgs: [gameName, drawDate],
      limit: 1,
    );

    if (maps.isNotEmpty) {
      _log.fine("Found GameResultCache for $gameName/$drawDate: ${maps.first}");
      return GameResultData.fromMap(maps.first);
    } else {
      _log.fine("No GameResultCache found for $gameName/$drawDate.");
      return null;
    }
  }

  /// Clears the 'new_draw_flag' (sets it to 0) for a specific game result in the cache.
  /// Typically called after the user has viewed the new result.
  /// Returns the number of rows affected.
  Future<int> clearNewDrawFlag(String gameName, String drawDate) async {
    final db = await database;
    _log.fine("Clearing new_draw_flag for $gameName / $drawDate.");
    int count = await db.update(
      'game_results_cache',
      {'new_draw_flag': 0},
      where: 'game_name = ? AND draw_date = ? AND new_draw_flag = ?',
      whereArgs: [gameName, drawDate, 1],
    );
    _log.info("Cleared new_draw_flag for $gameName / $drawDate. Rows affected: $count");
    return count;
  }

  // --- CRUD Methods for User Profiles ---

  /// Inserts or updates a user's profile information.
  Future<int> insertOrUpdateUserProfile({
    required int userId,
    String? membershipLevel,
    List<String>? globalAwards,
    String? globalStatistics,
  }) async {
    final db = await database;
    final data = {
      'user_id': userId,
      'membership_level': membershipLevel,
      'global_awards': globalAwards != null ? jsonEncode(globalAwards) : null,
      'global_statistics': globalStatistics,
      'last_updated': DateTime.now().toIso8601String(),
    };
    data.removeWhere((key, value) => value == null);
    _log.fine("Inserting/Replacing UserProfile: $data");
    int id = await db.insert(
      'user_profiles',
      data,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _log.info("UserProfile inserted/replaced for user ID: $userId. Result ID/Rows affected: $id");
    return id;
  }

  /// Retrieves a user's profile information by user ID.
  /// Returns a map representing the profile or null if not found.
  Future<Map<String, dynamic>?> getUserProfile(int userId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'user_profiles',
      where: 'user_id = ?',
      whereArgs: [userId],
      limit: 1,
    );
    if (maps.isNotEmpty) {
      _log.fine("Found UserProfile for user $userId: ${maps.first}");
      return maps.first;
    } else {
      _log.fine("No UserProfile found for user $userId.");
      return null;
    }
  }

  // --- CRUD Methods for User Game Progress ---

  /// Inserts or updates a user's progress for a specific game.
  /// Merges awards and statistics, adds to score.
  Future<int> upsertUserGameProgress({
    required int userId,
    required String gameName,
    int scoreToAdd = 0,
    List<String>? gameAwardsToAdd,
    String? gameStatistics,
    String? membershipLevel,
  }) async {
    final db = await database;
    final existing = await getUserGameProgress(userId, gameName);
    int currentScore = 0;
    List<String> currentAwards = [];
    Map<String, dynamic> currentStats = {};
    if (existing != null) {
      currentScore = existing['game_score'] ?? 0;
      try {
        if (existing['game_awards'] != null) {
          currentAwards = List<String>.from(jsonDecode(existing['game_awards']));
        }
        if (existing['game_statistics'] != null) {
          currentStats = jsonDecode(existing['game_statistics']);
        }
      } catch (e) {
        _log.warning("Error decoding existing progress JSON for $userId/$gameName: $e");
      }
    }
    int newScore = currentScore + scoreToAdd;
    if (gameAwardsToAdd != null) {
      currentAwards.addAll(gameAwardsToAdd);
      currentAwards = currentAwards.toSet().toList();
    }
    if (gameStatistics != null) {
      try {
        currentStats.addAll(jsonDecode(gameStatistics));
      } catch (e) {
        _log.warning("Error decoding new gameStatistics JSON for $userId/$gameName: $e");
      }
    }
    final data = {
      'user_id': userId,
      'game_name': gameName,
      'game_score': newScore,
      'game_awards': jsonEncode(currentAwards),
      'game_statistics': jsonEncode(currentStats),
      'membership_level': membershipLevel,
      'last_played': DateTime.now().toIso8601String(),
    };
    data.removeWhere((key, value) => key != 'game_score' && key != 'game_awards' && key != 'game_statistics' && value == null);
    _log.fine("Upserting UserGameProgress: $data");
    int id = await db.insert(
      'user_game_progress',
      data,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _log.info("UserGameProgress upserted for $userId/$gameName. Result ID/Rows affected: $id");
    return id;
  }

  /// Retrieves a user's game progress for a specific game.
  /// Returns a map representing the progress or null if not found.
  Future<Map<String, dynamic>?> getUserGameProgress(int userId, String gameName) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'user_game_progress',
      where: 'user_id = ? AND game_name = ?',
      whereArgs: [userId, gameName],
      limit: 1,
    );
    if (maps.isNotEmpty) {
      _log.fine("Found UserGameProgress for $userId/$gameName: ${maps.first}");
      return maps.first;
    } else {
      _log.fine("No UserGameProgress found for $userId/$gameName.");
      return null;
    }
  }

  /// Retrieves all game progress records for a specific user.
  /// Returns a list of maps.
  Future<List<Map<String, dynamic>>> getAllUserGameProgress(int userId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'user_game_progress',
      where: 'user_id = ?',
      whereArgs: [userId],
      orderBy: 'game_name ASC',
    );
    _log.fine("Found ${maps.length} UserGameProgress entries for user $userId.");
    return maps;
  }

  /// Calculates the total score for a user across all games.
  Future<int> getTotalUserScore(int userId) async {
    final db = await database;
    final List<Map<String, dynamic>> result = await db.rawQuery(
      'SELECT SUM(game_score) as total_score FROM user_game_progress WHERE user_id = ?',
      [userId],
    );
    int totalScore = Sqflite.firstIntValue(result) ?? 0;
    _log.fine("Calculated total score for user $userId: $totalScore");
    return totalScore;
  }

  // --- Methods for Game Rules ---

  /// Retrieves the rules for a specific game by its name.
  /// Returns a GameRule object or null if not found.
  Future<GameRule?> getGameRule(String gameName) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'game_rules',
      columns: GameRule.columns,
      where: 'game_name = ?',
      whereArgs: [gameName],
      limit: 1,
    );
    if (maps.isNotEmpty) {
      return GameRule.fromMap(maps.first);
    }
    _log.warning("Game rule not found in DB for: $gameName");
    return null;
  }

  // --- Methods for Game Draw Info ---

  /// Inserts or updates information about a specific game draw.
  Future<int> upsertGameDrawInfo(GameDrawInfo drawInfo) async {
    final db = await database;
    Map<String, dynamic> dataMap = drawInfo.toMap();
    dataMap['last_updated'] = DateTime.now().toIso8601String();

    _log.fine("Upserting GameDrawInfo: ${dataMap.keys.map((k) => '$k: ${dataMap[k]}').join(', ')}");
    int resultId = await db.insert(
      'game_draw_info',
      dataMap,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _log.info("GameDrawInfo upserted for ${drawInfo.gameName}/${drawInfo.drawDate}. Result ID/Rows affected: $resultId.");
    return resultId;
  }

  /// Retrieves information for a specific game draw.
  /// If drawDate is provided, fetches that specific draw.
  /// If drawDate is null, fetches the information for the latest known draw date for that game.
  Future<GameDrawInfo?> getGameDrawInfo(String gameName, [String? drawDate]) async {
    final db = await database;
    List<Map<String, dynamic>> maps;

    if (drawDate != null) {
      _log.fine("Querying GameDrawInfo for specific date: $gameName / $drawDate");
      maps = await db.query(
        'game_draw_info',
        where: 'game_name = ? AND draw_date = ?',
        whereArgs: [gameName, drawDate],
        limit: 1,
      );
    } else {
      _log.fine("Querying latest GameDrawInfo for game: $gameName");
      try {
        maps = await db.query(
          'game_draw_info',
          where: 'game_name = ?',
          whereArgs: [gameName],
          orderBy: 'draw_date DESC',
          limit: 1,
        );
        _log.fine("Raw query result for latest GameDrawInfo ($gameName): $maps");
      } catch (e, stacktrace) {
        _log.severe("Error querying latest GameDrawInfo for $gameName: $e\nStack: $stacktrace");
        maps = [];
      }
    }

    if (maps.isNotEmpty) {
      _log.fine("Found GameDrawInfo for $gameName (Date: ${drawDate ?? 'Latest'}): ${maps.first}");
      return GameDrawInfo.fromMap(maps.first);
    } else {
      _log.fine("No GameDrawInfo found for $gameName (Date: ${drawDate ?? 'Latest'}). Query returned empty.");
      return null;
    }
  }

  // --- Utility Methods ---

  /// Deletes the entire database file and re-initializes it.
  /// WARNING: This causes complete data loss. Use with extreme caution, typically only during development.
  Future<void> resetDatabase() async {
    try {
      if (_database != null && _database!.isOpen) {
        await _database!.close();
        _log.info("Database closed.");
      }
      _database = null;
      Directory documentsDirectory = await getApplicationDocumentsDirectory();
      String path = "${documentsDirectory.path}/$_databaseName";
      File dbFile = File(path);
      if (await dbFile.exists()) {
        await dbFile.delete();
        _log.info("Database file deleted at path: $path");
      } else {
        _log.info("Database file not found at path: $path (already deleted or never created).");
      }
      _log.info("Re-initializing database...");
      _database = await _initDatabase();
      _log.info("Database reset and re-initialized successfully.");
    } catch (e) {
      _log.severe("Error resetting database: $e");
      rethrow;
    }
  }

  /// Checks if any record in the 'game_results_cache' table has the 'new_draw_flag' set to 1.
  /// Returns true if at least one new result exists, false otherwise.
  Future<bool> hasAnyNewResults() async {
    final db = await database;
    try {
      final count = Sqflite.firstIntValue(await db.query(
        'game_results_cache',
        columns: ['COUNT(*)'],
        where: 'new_draw_flag = ?',
        whereArgs: [1],
      ));
      bool hasNew = (count ?? 0) > 0;
      _log.fine("Checked for any new results (flag=1): Found = $hasNew (Count: ${count ?? 0})");
      return hasNew;
    } catch (e) {
      _log.severe("Error checking for any new results: $e");
      return false;
    }
  }
}