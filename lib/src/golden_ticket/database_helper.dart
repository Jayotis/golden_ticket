// golden_ticket/database_helper.dart
import 'dart:io'; // Used for File operations (like deleting the database file).
import 'package:path_provider/path_provider.dart'; // Used to find the correct local path for the database file.
import 'package:sqflite/sqflite.dart'; // The main SQFlite package for database operations.
import 'package:sqflite/sqlite_api.dart'; // Import for Batch operations.
import 'ingot_crucible.dart'; // Data model for the user's selected combinations for a draw.
import 'dart:convert'; // Used for encoding/decoding JSON data stored in TEXT columns.
import 'GameResultData.dart'; // Data model for storing cached game results.

import 'game_rules.dart'; // Data model defining the rules for different games.
import 'package:logging/logging.dart'; // Logging framework.
import 'logging_utils.dart'; // Utility for logger setup.

// --- GameDrawInfo Class Definition ---
// Logger specific to the GameDrawInfo class, mainly for parsing warnings.
final _logGameDrawInfo = Logger('GameDrawInfo');
/// Represents information about a specific game draw, often fetched from the API.
/// Includes details like total combinations, user limits, and when the info was last updated.
class GameDrawInfo {
  final String gameName;
  final String drawDate;
  final int? totalCombinations;
  final int? userRequestLimit;
  final int? userCombinationsRequested;
  final String? archiveChecksum; // New field
  final DateTime? lastUpdated;

  GameDrawInfo({
    required this.gameName,
    required this.drawDate,
    this.totalCombinations,
    this.userRequestLimit,
    this.userCombinationsRequested,
    this.archiveChecksum, // New field
    this.lastUpdated,
  });

  Map<String, dynamic> toMap() {
    return {
      'game_name': gameName,
      'draw_date': drawDate,
      'total_combinations': totalCombinations,
      'user_request_limit': userRequestLimit,
      'user_combinations_requested': userCombinationsRequested,
      'archive_checksum': archiveChecksum, // New field
      'last_updated': lastUpdated?.toIso8601String(),
    };
  }

  factory GameDrawInfo.fromMap(Map<String, dynamic> map) {
    return GameDrawInfo(
      gameName: map['game_name'] as String,
      drawDate: map['draw_date'] as String,
      totalCombinations: map['total_combinations'] as int?,
      userRequestLimit: map['user_request_limit'] as int?,
      userCombinationsRequested: map['user_combinations_requested'] as int?,
      archiveChecksum: map['archive_checksum'] as String?, // New field
      lastUpdated: map['last_updated'] != null ? DateTime.parse(map['last_updated']) : null,
    );
  }
  @override
  String toString() {
    return 'GameDrawInfo{gameName: $gameName, drawDate: $drawDate, totalCombinations: $totalCombinations, userRequestLimit: $userRequestLimit, userCombinationsRequested: $userCombinationsRequested, lastUpdated: $lastUpdated}';
  }
}
// --- End GameDrawInfo Class Definition ---


/// A singleton class providing access to the application's SQLite database.
/// Handles database initialization, schema creation, migrations, and CRUD operations.
class DatabaseHelper {
  // --- Singleton Pattern Implementation ---
  // Private internal constructor.
  DatabaseHelper._internal() {
    // Setup logger for the DatabaseHelper instance.
    LoggingUtils.setupLogger(_log);
  }
  // Static private instance.
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  // Public factory constructor returns the single instance.
  factory DatabaseHelper() => _instance;
  // --- End Singleton Pattern ---

  // Logger instance for DatabaseHelper.
  final _log = Logger('DatabaseHelper');

  // Static variable to hold the database instance (lazy initialized).
  static Database? _database;
  // Database version. Increment this number when the schema changes.
  static const int _databaseVersion = 2;
  // Name of the database file.
  static const String _databaseName = "play_cards.db"; // Kept original name despite table rename.

  /// Getter for the database instance.
  /// Initializes the database if it hasn't been already.
  Future<Database> get database async {
    if (_database != null) return _database!;
    // If _database is null, initialize it.
    _database = await _initDatabase();
    return _database!;
  }

  /// Initializes the database: finds the path, opens the connection,
  /// and sets up callbacks for creation and upgrades.
  Future<Database> _initDatabase() async {
    // Get the directory for storing application documents.
    Directory documentsDirectory = await getApplicationDocumentsDirectory();
    // Construct the full path to the database file.
    String path = "${documentsDirectory.path}/$_databaseName";
    _log.info("Database path: $path (Version: $_databaseVersion)");
    // Open the database.
    return await openDatabase(
      path,
      version: _databaseVersion, // Specify the database version.
      onCreate: _onCreate,       // Callback function if the DB file doesn't exist.
      onUpgrade: _onUpgrade,     // Callback function if DB version is lower than _databaseVersion.
    );
  }

  /// Called only when the database file is first created on the device.
  /// Responsible for creating the initial database schema (all tables).
  Future<void> _onCreate(Database db, int version) async {
    _log.info("Creating database schema (version $version)...");
    // Use a helper method to create all tables within a single transaction (Batch).
    await _createAllTables(db);
    _log.info("Database tables created.");
    // Populate the game_rules table with initial data.
    _log.info("Populating game_rules table...");
    await _populateGameRules(db);
    _log.info("game_rules table populated.");
  }

  /// Called when the database version specified during openDatabase is higher
  /// than the version stored in the existing database file.
  /// Handles schema migrations between versions.
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    _log.warning("Upgrading database from version $oldVersion to $newVersion...");

    // --- Migration Logic ---
    // Apply changes incrementally based on the oldVersion.
    if (oldVersion < 2) {
      // Changes introduced in version 2.
      _log.info("Applying schema changes for version 2...");
      try {
        // Rename the 'play_cards' table to 'ingot_crucibles'.
        await db.execute('ALTER TABLE play_cards RENAME TO ingot_crucibles');
        _log.info("Renamed table 'play_cards' to 'ingot_crucibles'.");
        // Add other ALTER TABLE statements or data migration logic for v2 if needed.
      } catch (e) {
        _log.severe("Error applying schema changes for version 2: $e");
        // In a production app, more robust error handling or specific migration
        // steps would be needed. Recreating tables is a last resort due to data loss.
        // Example Fallback (DATA LOSS!):
        // await db.execute('DROP TABLE IF EXISTS play_cards');
        // await db.execute('DROP TABLE IF EXISTS ingot_crucibles');
        // await _createIngotCruciblesTable(db); // Assuming helper takes Database
        // _log.warning("Fallback: Dropped and recreated ingot_crucibles table due to migration error.");
      }
    }
    // Example for future version:
    // if (oldVersion < 3) {
    //   // Apply changes for version 3
    //   await db.execute('ALTER TABLE ...');
    // }
    // --- End Migration Logic ---

    _log.info("Database upgrade complete.");
  }

  /// Helper method to create all database tables using a Batch operation
  /// for better performance during initial creation.
  Future<void> _createAllTables(Database db) async {
    // Create a batch object.
    Batch batch = db.batch();
    // Add CREATE TABLE statements to the batch.
    _createIngotCruciblesTable(batch); // Renamed table.
    _createGameResultsCacheTable(batch);
    _createUserProfilesTable(batch);
    _createUserGameProgressTable(batch);
    _createGameRulesTable(batch);
    _createGameDrawInfoTable(batch);
    _createIngotCollectionTable(batch);
    // Commit the batch - executes all statements in a single transaction.
    await batch.commit(noResult: true);
  }


  // --- Table Creation Methods ---

  /// Defines and creates the 'ingot_crucibles' table schema (formerly 'play_cards').
  /// Stores the user's selected combinations (ingots) for a specific draw.
  void _createIngotCruciblesTable(Batch batch) {
    batch.execute('''
      CREATE TABLE ingot_crucibles(
        id INTEGER PRIMARY KEY AUTOINCREMENT, -- Auto-incrementing primary key.
        name TEXT,                             -- Optional name for the crucible.
        user_id INTEGER,                       -- Foreign key linking to the user.
        submitted_date TEXT NOT NULL,          -- Timestamp of last save/submission (ISO 8601 string).
        status TEXT NOT NULL,                  -- Status ('draft', 'submitted', 'locked').
        combinations TEXT NOT NULL,            -- JSON string representing List<CombinationWithId>.
        draw_date TEXT NOT NULL                -- Target draw date ('yyyy-MM-dd').
      )
    ''');
    _log.fine("Schema: ingot_crucibles defined.");
    // Add an index for faster lookups based on user and draw date.
    batch.execute('CREATE INDEX IF NOT EXISTS idx_crucible_user_draw ON ingot_crucibles (user_id, draw_date)');
    _log.fine("Index: idx_crucible_user_draw defined.");
  }

  /// Defines and creates the 'game_results_cache' table schema.
  /// Stores fetched game results locally to reduce API calls.
  void _createGameResultsCacheTable(Batch batch) {
    batch.execute('''
      CREATE TABLE game_results_cache(
        game_name TEXT NOT NULL,            -- Name of the game.
        draw_date TEXT NOT NULL,            -- Date of the draw ('yyyy-MM-dd').
        last_draw_numbers TEXT,             -- JSON string of winning numbers (List<int>).
        bonus_number INTEGER,               -- Bonus number, if applicable.
        total_combinations INTEGER,         -- Total combinations for the game (informational).
        odds_6_6 REAL,                      -- Odds for matching 6/6 (example).
        odds_5_6_plus REAL,                 -- Odds for matching 5/6 + bonus (example).
        odds_5_6 REAL,                      -- Odds for matching 5/6 (example).
        odds_4_6 REAL,                      -- Odds for matching 4/6 (example).
        odds_3_6 REAL,                      -- Odds for matching 3/6 (example).
        odds_2_6_plus REAL,                 -- Odds for matching 2/6 + bonus (example).
        odds_2_6 REAL,                      -- Odds for matching 2/6 (example).
        odds_any_prize REAL,                -- Overall odds of winning any prize.
        user_score INTEGER,                 -- User's score for this specific draw.
        fetched_at TEXT NOT NULL,           -- Timestamp when this result was fetched (ISO 8601 string).
        new_draw_flag INTEGER DEFAULT 0 NOT NULL, -- Flag (1=new, 0=seen) to indicate unread results.
        win_id TEXT,                        -- Unique identifier for the winning result set (if provided by API).
        archive_password TEXT,              -- Password for result archive (if provided).
        archive_checksum TEXT,              -- Checksum for result archive verification (if provided).
        PRIMARY KEY (game_name, draw_date)  -- Composite primary key.
      )
    ''');
    _log.fine("Schema: game_results_cache defined.");
  }

  /// Defines and creates the 'user_profiles' table schema.
  /// Stores basic user profile information.
  void _createUserProfilesTable(Batch batch) {
    batch.execute('''
      CREATE TABLE user_profiles(
        user_id INTEGER PRIMARY KEY,        -- User ID from the backend, primary key.
        membership_level TEXT,              -- User's membership level (e.g., 'Family').
        global_awards TEXT,                 -- JSON string representing List<String> of global awards.
        global_statistics TEXT,             -- JSON string representing Map<String, dynamic> of global stats.
        last_updated TEXT NOT NULL          -- Timestamp of last update (ISO 8601 string).
      )
    ''');
    _log.fine("Schema: user_profiles defined.");
  }

  /// Defines and creates the 'user_game_progress' table schema.
  /// Stores user-specific progress and stats for each game they participate in.
  void _createUserGameProgressTable(Batch batch) {
    batch.execute('''
      CREATE TABLE user_game_progress(
        user_id INTEGER NOT NULL,           -- Foreign key linking to user_profiles.
        game_name TEXT NOT NULL,            -- Name of the game.
        game_score INTEGER NOT NULL DEFAULT 0, -- User's score for this game.
        game_awards TEXT,                   -- JSON string representing List<String> of game-specific awards.
        game_statistics TEXT,               -- JSON string representing Map<String, dynamic> of game stats.
        membership_level TEXT,              -- User's level at the time of last play (denormalized, optional).
        last_played TEXT,                   -- Timestamp of last interaction with this game (ISO 8601 string).
        PRIMARY KEY (user_id, game_name),   -- Composite primary key.
        FOREIGN KEY (user_id) REFERENCES user_profiles(user_id) ON DELETE CASCADE -- Delete progress if user profile is deleted.
      )
    ''');
    _log.fine("Schema: user_game_progress defined.");
    // Add index for faster lookups by user_id.
    batch.execute('CREATE INDEX IF NOT EXISTS idx_user_game_progress_user ON user_game_progress (user_id)');
    _log.fine("Index: idx_user_game_progress_user defined.");
  }

  /// Defines and creates the 'game_rules' table schema.
  /// Stores the rules and parameters for each supported game.
  void _createGameRulesTable(Batch batch) {
    batch.execute('''
      CREATE TABLE game_rules(
        game_name TEXT PRIMARY KEY NOT NULL, -- Name of the game, primary key.
        total_numbers INTEGER NOT NULL,      -- Total numbers in the pool (e.g., 49).
        regular_balls_drawn INTEGER NOT NULL,-- Number of regular balls drawn (e.g., 6).
        bonus_ball_pool INTEGER NOT NULL,    -- Size of the bonus ball pool (can be same as total_numbers).
        bonus_balls_drawn INTEGER NOT NULL,  -- Number of bonus balls drawn (e.g., 1).
        draw_schedule TEXT,                  -- String describing draw days/times/timezones.
        prize_tier_format TEXT,              -- String describing prize tiers (e.g., 'matches/6+').
        official_odds_json TEXT              -- JSON string storing official odds display strings (Map<String, String>).
      )
    ''');
    _log.fine("Schema: game_rules defined.");
  }

  /// Defines and creates the 'game_draw_info' table schema.
  /// Stores information about specific draws, like limits and dates.
  void _createGameDrawInfoTable(Batch batch) {
    batch.execute('''
      CREATE TABLE game_draw_info(
        game_name TEXT NOT NULL,            -- Name of the game.
        draw_date TEXT NOT NULL,            -- Date of the draw ('yyyy-MM-dd').
        total_combinations INTEGER,         -- Total combinations for the game.
        user_request_limit INTEGER,         -- Max ingots user can request for this draw.
        user_combinations_requested INTEGER,-- Ingots user has requested so far.
        last_updated TEXT,                  -- Timestamp when this info was last updated (ISO 8601 string).
        archive_checksum TEXT,
        PRIMARY KEY (game_name, draw_date)  -- Composite primary key.
      )
    ''');
    _log.fine("Schema: game_draw_info defined.");
  }

  /// Defines and creates the 'ingot_collection' table schema.
  /// Stores the individual combinations (ingots) a user has "smelted" but not yet placed in a crucible.
  void _createIngotCollectionTable(Batch batch) {
    batch.execute('''
      CREATE TABLE ingot_collection(
        ingot_id INTEGER PRIMARY KEY,       -- Unique ID for the ingot (likely from API), primary key.
        user_id INTEGER NOT NULL,           -- User who owns the ingot.
        game_name TEXT NOT NULL,            -- Game the ingot belongs to.
        draw_date TEXT NOT NULL,            -- Draw date the ingot is associated with ('yyyy-MM-dd').
        numbers TEXT NOT NULL,              -- JSON string representing the combination numbers (List<int>).
        added_timestamp TEXT NOT NULL       -- Timestamp when the ingot was added (ISO 8601 string).
      )
    ''');
    // Add index for faster lookups of a user's collection for a specific game/draw.
    batch.execute('CREATE INDEX IF NOT EXISTS idx_ingot_collection_user_game_draw ON ingot_collection (user_id, game_name, draw_date)');
    _log.fine("Schema: ingot_collection defined with index.");
  }
  // --- End Table Creation Methods ---

  /// Populates the 'game_rules' table with initial data defined in GameRules.gameRulesData.
  /// Uses a Batch for efficiency.
  Future<void> _populateGameRules(Database db) async {
    Batch populateBatch = db.batch();
    // Iterate through the predefined game rules.
    for (final rule in GameRules.gameRulesData) {
      _log.fine("Inserting game rule: ${rule.toString()}");
      // Insert each rule into the table. Use 'replace' to handle potential re-runs.
      populateBatch.insert('game_rules', rule.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
    }
    // Execute the batch insertion.
    await populateBatch.commit(noResult: true);
    _log.info("game_rules table populated successfully.");
  }

  // --- CRUD Methods for IngotCrucible ---

  /// Inserts a new IngotCrucible record or replaces an existing one if the ID matches.
  /// Returns the row ID of the inserted/replaced record.
  Future<int> insertIngotCrucible(IngotCrucible crucible) async {
    final db = await database;
    _log.fine("Inserting/Replacing IngotCrucible: ${crucible.toMap()}");
    // Use insert with conflictAlgorithm.replace for upsert behavior based on primary key (id).
    int id = await db.insert(
      'ingot_crucibles', // Use the correct table name.
      crucible.toMap(), // Convert object to map for insertion.
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _log.info("IngotCrucible inserted/replaced with ID: $id");
    return id;
  }

  /// Retrieves a specific IngotCrucible for a given user and draw date.
  /// Returns the IngotCrucible object or null if not found.
  Future<IngotCrucible?> getUserCrucibleForDraw(int userId, String drawDate) async {
    final db = await database;
    // Query the table for matching user_id and draw_date.
    final List<Map<String, dynamic>> maps = await db.query(
      'ingot_crucibles', // Use the correct table name.
      where: 'user_id = ? AND draw_date = ?', // SQL WHERE clause.
      whereArgs: [userId, drawDate], // Arguments for the WHERE clause.
      limit: 1, // Expect only one record per user/draw.
    );

    // If a record is found, convert it from a map to an IngotCrucible object.
    if (maps.isNotEmpty) {
      _log.fine("Found IngotCrucible for user $userId, draw $drawDate: ${maps.first}");
      return IngotCrucible.fromMap(maps.first);
    } else {
      _log.fine("No IngotCrucible found for user $userId, draw $drawDate.");
      return null; // Return null if no record found.
    }
  }

  /// Checks if an IngotCrucible record exists for a given user and draw date.
  /// Returns true if a record exists, false otherwise.
  Future<bool> hasCrucibleForDrawDate(int userId, String drawDate) async {
    final db = await database;
    // Query only for the 'id' column to check existence efficiently.
    final List<Map<String, dynamic>> maps = await db.query(
      'ingot_crucibles', // Use the correct table name.
      columns: ['id'], // Only need one column to check existence.
      where: 'user_id = ? AND draw_date = ?',
      whereArgs: [userId, drawDate],
      limit: 1,
    );
    bool exists = maps.isNotEmpty; // True if the query returned any rows.
    _log.fine("Checked for IngotCrucible existence for user $userId, draw $drawDate: $exists");
    return exists;
  }
  // --- End Ingot Crucible Methods ---


  // --- CRUD Methods for Ingot Collection ---

  /// Adds a new ingot (combination) to the user's collection.
  /// Replaces if an ingot with the same ingotId already exists.
  Future<int> addIngotToCollection({
    required int userId,
    required String gameName,
    required String drawDate,
    required int ingotId, // The unique ID of the ingot from the API.
    required List<int> numbers, // The combination numbers.
  }) async {
    final db = await database;
    // Prepare data map for insertion.
    final data = {
      'ingot_id': ingotId,
      'user_id': userId,
      'game_name': gameName,
      'draw_date': drawDate,
      'numbers': jsonEncode(numbers), // Store numbers list as JSON string.
      'added_timestamp': DateTime.now().toIso8601String(), // Record when added.
    };
    _log.fine("Adding Ingot to Collection: $data");
    try {
      // Insert data, replacing any existing entry with the same ingot_id.
      int id = await db.insert('ingot_collection', data, conflictAlgorithm: ConflictAlgorithm.replace);
      _log.info("Ingot ID $ingotId added/replaced in collection for $userId/$gameName/$drawDate. Result: $id");
      return id; // Returns the row ID (or ingot_id if it's the primary key).
    } catch (e) {
      _log.severe("Error adding ingot $ingotId to collection: $e");
      rethrow; // Rethrow the exception to be handled by the caller.
    }
  }

  /// Retrieves all ingots from the collection for a specific user, game, and draw date.
  /// Returns a list of CombinationWithId objects.
  Future<List<CombinationWithId>> getIngotCollection(int userId, String gameName, String drawDate) async {
    final db = await database;
    List<CombinationWithId> collection = [];
    _log.fine("Getting Ingot Collection for $userId/$gameName/$drawDate");
    try {
      // Query the collection table.
      final List<Map<String, dynamic>> maps = await db.query(
        'ingot_collection',
        where: 'user_id = ? AND game_name = ? AND draw_date = ?',
        whereArgs: [userId, gameName, drawDate],
        orderBy: 'added_timestamp DESC', // Order by most recently added.
      );
      // Convert each map result into a CombinationWithId object.
      for (var map in maps) {
        try {
          // Decode the numbers JSON string.
          final numbersList = jsonDecode(map['numbers'] as String);
          if (numbersList is List) {
            // Create the object and add to the list.
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
      // Delete the row matching the ingotId.
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
      // Delete rows matching the user, game, and draw date.
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
  // --- End Ingot Collection Methods ---


  // --- CRUD Methods for Game Results Cache ---

  /// Inserts or updates a game result in the cache table.
  /// Sets the 'new_draw_flag' based on whether actual draw numbers are present.
  Future<int> insertOrUpdateGameResultCache(GameResultData result) async {
    final db = await database;
    // Convert the GameResultData object to a map.
    Map<String, dynamic> dataMap = result.toMap();
    // Set the new_draw_flag: 1 if actual numbers exist, 0 for placeholders.
    if (result.drawNumbers != null && result.drawNumbers!.isNotEmpty) {
      dataMap['new_draw_flag'] = 1;
      _log.fine("Setting new_draw_flag to 1 for actual results: ${result.gameName}/${result.drawDate}");
    } else {
      dataMap['new_draw_flag'] = 0;
      _log.fine("Setting new_draw_flag to 0 for placeholder: ${result.gameName}/${result.drawDate}");
    }
    // Record the time the data was fetched/cached.
    dataMap['fetched_at'] = DateTime.now().toIso8601String();

    _log.fine("Inserting/Replacing GameResultCache: ${dataMap.keys.map((k) => '$k: ${dataMap[k]}').join(', ')}");
    // Use insert with replace conflict algorithm for upsert behavior based on primary key (game_name, draw_date).
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
    // Query the cache table.
    final List<Map<String, dynamic>> maps = await db.query(
      'game_results_cache',
      where: 'game_name = ? AND draw_date = ?',
      whereArgs: [gameName, drawDate],
      limit: 1, // Expect only one result per game/draw.
    );

    // If found, convert the map to a GameResultData object.
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
    // Update the flag to 0 only if it's currently 1.
    int count = await db.update(
      'game_results_cache',
      {'new_draw_flag': 0}, // Values to update.
      where: 'game_name = ? AND draw_date = ? AND new_draw_flag = ?', // Condition.
      whereArgs: [gameName, drawDate, 1], // Arguments for the condition.
    );
    _log.info("Cleared new_draw_flag for $gameName / $drawDate. Rows affected: $count");
    return count;
  }
  // --- End Game Results Cache Methods ---


  // --- CRUD Methods for User Profiles ---

  /// Inserts or updates a user's profile information.
  Future<int> insertOrUpdateUserProfile({
    required int userId,
    String? membershipLevel,
    List<String>? globalAwards, // Stored as JSON string.
    String? globalStatistics, // Stored as JSON string.
  }) async {
    final db = await database;
    // Prepare data map, encoding lists/maps as JSON.
    final data = {
      'user_id': userId,
      'membership_level': membershipLevel,
      'global_awards': globalAwards != null ? jsonEncode(globalAwards) : null,
      'global_statistics': globalStatistics, // Assuming already a JSON string or compatible.
      'last_updated': DateTime.now().toIso8601String(),
    };
    // Remove null values to avoid inserting NULLs unless intended.
    data.removeWhere((key, value) => value == null);
    _log.fine("Inserting/Replacing UserProfile: $data");
    // Use insert with replace for upsert based on primary key (user_id).
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
    // Query by user_id.
    final List<Map<String, dynamic>> maps = await db.query(
      'user_profiles',
      where: 'user_id = ?',
      whereArgs: [userId],
      limit: 1,
    );
    // Return the map if found.
    if (maps.isNotEmpty) {
      _log.fine("Found UserProfile for user $userId: ${maps.first}");
      return maps.first;
    } else {
      _log.fine("No UserProfile found for user $userId.");
      return null;
    }
  }
  // --- End User Profiles Methods ---


  // --- CRUD Methods for User Game Progress ---

  /// Inserts or updates a user's progress for a specific game.
  /// Merges awards and statistics, adds to score.
  Future<int> upsertUserGameProgress({
    required int userId,
    required String gameName,
    int scoreToAdd = 0,
    List<String>? gameAwardsToAdd, // Stored as JSON list.
    String? gameStatistics, // Stored as JSON map string.
    String? membershipLevel,
  }) async {
    final db = await database;
    // Get existing progress to merge data.
    final existing = await getUserGameProgress(userId, gameName);
    int currentScore = 0;
    List<String> currentAwards = [];
    Map<String, dynamic> currentStats = {};
    // If existing progress found, parse its data.
    if (existing != null) {
      currentScore = existing['game_score'] ?? 0;
      try {
        // Safely decode JSON strings for awards and stats.
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
    // Calculate new score.
    int newScore = currentScore + scoreToAdd;
    // Merge awards (using a Set to ensure uniqueness).
    if (gameAwardsToAdd != null) {
      currentAwards.addAll(gameAwardsToAdd);
      currentAwards = currentAwards.toSet().toList();
    }
    // Merge statistics (assuming new statistics override old ones with the same key).
    if (gameStatistics != null) {
      try {
        currentStats.addAll(jsonDecode(gameStatistics));
      } catch (e) {
        _log.warning("Error decoding new gameStatistics JSON for $userId/$gameName: $e");
      }
    }
    // Prepare data map for upsert.
    final data = {
      'user_id': userId,
      'game_name': gameName,
      'game_score': newScore,
      'game_awards': jsonEncode(currentAwards), // Encode merged awards.
      'game_statistics': jsonEncode(currentStats), // Encode merged stats.
      'membership_level': membershipLevel,
      'last_played': DateTime.now().toIso8601String(), // Update last played timestamp.
    };
    // Remove null values except for score/awards/stats which might be intentionally empty/zero.
    data.removeWhere((key, value) => key != 'game_score' && key != 'game_awards' && key != 'game_statistics' && value == null);
    _log.fine("Upserting UserGameProgress: $data");
    // Use insert with replace for upsert based on primary key (user_id, game_name).
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
    // Query by user_id and game_name.
    final List<Map<String, dynamic>> maps = await db.query(
      'user_game_progress',
      where: 'user_id = ? AND game_name = ?',
      whereArgs: [userId, gameName],
      limit: 1,
    );
    // Return the map if found.
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
    // Query by user_id, order by game name.
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
    // Use a raw SQL query with SUM aggregation.
    final List<Map<String, dynamic>> result = await db.rawQuery(
      'SELECT SUM(game_score) as total_score FROM user_game_progress WHERE user_id = ?',
      [userId],
    );
    // Extract the sum value, defaulting to 0 if null.
    int totalScore = Sqflite.firstIntValue(result) ?? 0;
    _log.fine("Calculated total score for user $userId: $totalScore");
    return totalScore;
  }
  // --- End User Game Progress Methods ---


  // --- Methods for Game Rules ---

  /// Retrieves the rules for a specific game by its name.
  /// Returns a GameRule object or null if not found.
  Future<GameRule?> getGameRule(String gameName) async {
    final db = await database;
    // Query the game_rules table by game_name.
    final List<Map<String, dynamic>> maps = await db.query(
      'game_rules',
      columns: GameRule.columns, // Specify columns defined in the GameRule model.
      where: 'game_name = ?',
      whereArgs: [gameName],
      limit: 1,
    );
    // If found, convert the map to a GameRule object.
    if (maps.isNotEmpty) {
      return GameRule.fromMap(maps.first);
    }
    _log.warning("Game rule not found in DB for: $gameName");
    return null;
  }
  // --- End Game Rules Methods ---


  // --- Methods for Game Draw Info ---

  /// Inserts or updates information about a specific game draw.
  Future<int> upsertGameDrawInfo(GameDrawInfo drawInfo) async {
    final db = await database;
    // Convert object to map.
    Map<String, dynamic> dataMap = drawInfo.toMap();
    // Set the last_updated timestamp.
    dataMap['last_updated'] = DateTime.now().toIso8601String();

    _log.fine("Upserting GameDrawInfo: ${dataMap.keys.map((k) => '$k: ${dataMap[k]}').join(', ')}");
    // Use insert with replace for upsert based on primary key (game_name, draw_date).
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
      // Fetch info for a specific date.
      _log.fine("Querying GameDrawInfo for specific date: $gameName / $drawDate");
      maps = await db.query(
        'game_draw_info',
        where: 'game_name = ? AND draw_date = ?',
        whereArgs: [gameName, drawDate],
        limit: 1,
      );
    } else {
      // Fetch the latest info for the game by ordering by date descending.
      _log.fine("Querying latest GameDrawInfo for game: $gameName");
      try {
        maps = await db.query(
          'game_draw_info',
          where: 'game_name = ?',
          whereArgs: [gameName],
          orderBy: 'draw_date DESC', // Get the most recent date first.
          limit: 1,
        );
        _log.fine("Raw query result for latest GameDrawInfo ($gameName): $maps");
      } catch (e, stacktrace) {
        _log.severe("Error querying latest GameDrawInfo for $gameName: $e\nStack: $stacktrace");
        maps = []; // Return empty list on error.
      }
    }

    // If found, convert map to GameDrawInfo object.
    if (maps.isNotEmpty) {
      _log.fine("Found GameDrawInfo for $gameName (Date: ${drawDate ?? 'Latest'}): ${maps.first}");
      return GameDrawInfo.fromMap(maps.first);
    } else {
      _log.fine("No GameDrawInfo found for $gameName (Date: ${drawDate ?? 'Latest'}). Query returned empty.");
      return null;
    }
  }
  // --- End Game Draw Info Methods ---


  // --- Utility Methods ---

  /// Deletes the entire database file and re-initializes it.
  /// WARNING: This causes complete data loss. Use with extreme caution, typically only during development.
  Future<void> resetDatabase() async {
    try {
      // Close the database if it's open.
      if (_database != null && _database!.isOpen) {
        await _database!.close();
        _log.info("Database closed.");
      }
      _database = null; // Clear the static instance.
      // Get the path and delete the file.
      Directory documentsDirectory = await getApplicationDocumentsDirectory();
      String path = "${documentsDirectory.path}/$_databaseName";
      File dbFile = File(path);
      if (await dbFile.exists()) {
        await dbFile.delete();
        _log.info("Database file deleted at path: $path");
      } else {
        _log.info("Database file not found at path: $path (already deleted or never created).");
      }
      // Re-initialize the database, triggering onCreate.
      _log.info("Re-initializing database...");
      _database = await _initDatabase();
      _log.info("Database reset and re-initialized successfully.");
    } catch (e) {
      _log.severe("Error resetting database: $e");
      rethrow; // Rethrow exception after logging.
    }
  }

  /// Checks if any record in the 'game_results_cache' table has the 'new_draw_flag' set to 1.
  /// Returns true if at least one new result exists, false otherwise.
  Future<bool> hasAnyNewResults() async {
    final db = await database;
    try {
      // Query the count of rows where the flag is 1.
      final count = Sqflite.firstIntValue(await db.query(
        'game_results_cache',
        columns: ['COUNT(*)'], // Only need the count.
        where: 'new_draw_flag = ?',
        whereArgs: [1],
      ));
      bool hasNew = (count ?? 0) > 0; // True if count is greater than 0.
      _log.fine("Checked for any new results (flag=1): Found = $hasNew (Count: ${count ?? 0})");
      return hasNew;
    } catch (e) {
      _log.severe("Error checking for any new results: $e");
      return false; // Return false on error.
    }
  }
// --- End Utility Methods ---

} // End of DatabaseHelper class
