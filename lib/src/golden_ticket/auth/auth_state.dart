// lib/state/auth_state.dart

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../game_draw_data.dart'; // Ensure this path is correct
import 'package:logging/logging.dart';

// --- Imports for Version Check ---
import 'package:version/version.dart';
import 'package:package_info_plus/package_info_plus.dart';
// --------------------------------

class AuthState with ChangeNotifier {
  final _log = Logger('AuthState');

  // --- Private State Variables ---
  bool _signedIn = false;
  String _accountStatus = '';
  String _membershipLevel = '';
  String _userId = '';
  String _authToken = '';
  List<GameDrawData> _gameDrawData = [];
  // --- New State Variable for Version Check ---
  bool _requiresUpdate = false;

  // --- SharedPreferences Keys ---
  static const String _prefsSignedInKey = 'signed_in';
  static const String _prefsAccountStatusKey = 'account_status';
  // ... other keys ...
  static const String _prefsMembershipLevelKey = 'membership_level';
  static const String _prefsUserIdKey = 'user_id';
  static const String _prefsAuthTokenKey = 'auth_token';
  static const String _prefsApiKeyKey = 'api_key';


  // --- Public Getters ---
  bool get signedIn => _signedIn;
  String get accountStatus => _accountStatus;
  String get membershipLevel => _membershipLevel;
  String get userId => _userId;
  String get authToken => _authToken;
  List<GameDrawData> get gameDrawData => _gameDrawData;
  bool get isSignedIn => _signedIn;
  // --- New Getter for Version Check ---
  bool get requiresUpdate => _requiresUpdate;


  /// Updates the authentication state variables with new values AFTER a successful sign-in response.
  /// Performs an app version check before fully setting the signed-in state.
  /// Notifies listeners about the change.
  Future<void> setSignInStatus({ // Made async to await PackageInfo
    required bool signedIn,
    required String accountStatus,
    required String membershipLevel,
    required String userId,
    required String authToken,
    required List<GameDrawData> gameDrawData,
    required String minimumRequiredVersionStr, // Get this from your sign-in response
  }) async { // Made async
    _log.info('Processing sign-in status: signedIn=$signedIn, userId=$userId, status=$accountStatus, level=$membershipLevel, hasToken=${authToken.isNotEmpty}');

    // --- Perform Version Check ---
    bool isCompatible = true; // Assume compatible by default
    try {
      // Get current app version
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersionStr = packageInfo.version;
      _log.fine("Current app version: $currentVersionStr");
      _log.fine("Minimum required version from server: $minimumRequiredVersionStr");


      // Parse versions
      final currentVersion = Version.parse(currentVersionStr);
      final minimumRequiredVersion = Version.parse(minimumRequiredVersionStr);

      // Compare versions
      isCompatible = currentVersion >= minimumRequiredVersion;
      _log.info("Version check result: isCompatible = $isCompatible");

    } catch (e, stacktrace) {
      _log.severe("Error during app version check: $e", e, stacktrace);
      // If check fails, assume compatible to avoid blocking user due to check error
      isCompatible = true;
    }

    // Update the requiresUpdate flag
    _requiresUpdate = !isCompatible;
    // --- End Version Check ---


    // Update internal state variables ONLY if signedIn is true
    // (We still set the _requiresUpdate flag regardless)
    if (signedIn) {
      _signedIn = signedIn;
      _accountStatus = accountStatus;
      _membershipLevel = membershipLevel;
      _userId = userId;
      _authToken = authToken;
      _gameDrawData = gameDrawData; // Assigns the passed data
    } else {
      // If sign-in is false, ensure local state reflects signed-out status
      // This case might not be typical if this method is only called on *successful* API login
      _signedIn = false;
      _accountStatus = '';
      _membershipLevel = '';
      _userId = '';
      _authToken = '';
      _gameDrawData = [];
    }

    // Notify listeners about the state change (including potential update requirement)
    notifyListeners();

    // Save the updated state to persistent storage (only if signed in)
    if (_signedIn) {
      await _saveToSharedPreferences();
    } else {
      // If the call was somehow for a sign-out, clear prefs
      await signOut(); // Or just clear relevant keys if signOut has side effects you want to avoid here
    }
  }


  /// Saves the current values of the authentication state variables to SharedPreferences.
  Future<void> _saveToSharedPreferences() async {
    _log.info('Attempting to save auth state to SharedPreferences...');
    try {
      final prefs = await SharedPreferences.getInstance();
      _log.fine('Saving $_prefsSignedInKey = $_signedIn');
      await prefs.setBool(_prefsSignedInKey, _signedIn);
      _log.fine('Saving $_prefsAccountStatusKey = $_accountStatus');
      await prefs.setString(_prefsAccountStatusKey, _accountStatus);
      _log.fine('Saving $_prefsMembershipLevelKey = $_membershipLevel');
      await prefs.setString(_prefsMembershipLevelKey, _membershipLevel);
      _log.fine('Saving $_prefsUserIdKey = $_userId');
      await prefs.setString(_prefsUserIdKey, _userId);
      _log.fine('Saving $_prefsAuthTokenKey = ${_authToken.isNotEmpty ? "********" : "empty"}');
      await prefs.setString(_prefsAuthTokenKey, _authToken);
      _log.info("Auth state save attempt finished.");
    } catch (e, stacktrace) {
      _log.severe("Error saving auth state to SharedPreferences: $e", e, stacktrace);
    }
  }

  /// Loads the persisted authentication state from SharedPreferences.
  Future<void> init() async {
    _log.info('Initializing AuthState from SharedPreferences...');
    try {
      final prefs = await SharedPreferences.getInstance();

      // Load persisted state...
      final bool? storedSignedIn = prefs.getBool(_prefsSignedInKey);
      _log.fine('Read $_prefsSignedInKey = $storedSignedIn');
      _signedIn = storedSignedIn ?? false;

      _accountStatus = prefs.getString(_prefsAccountStatusKey) ?? '';
      _log.fine('Read $_prefsAccountStatusKey = $_accountStatus');

      _membershipLevel = prefs.getString(_prefsMembershipLevelKey) ?? '';
      _log.fine('Read $_prefsMembershipLevelKey = $_membershipLevel');

      _userId = prefs.getString(_prefsUserIdKey) ?? '';
      _log.fine('Read $_prefsUserIdKey = $_userId');

      _authToken = prefs.getString(_prefsAuthTokenKey) ?? '';
      _log.fine('Read $_prefsAuthTokenKey = ${_authToken.isNotEmpty ? "********" : "empty"}');

      // Reset update flag on init - the check runs during setSignInStatus
      _requiresUpdate = false;

      _log.info("AuthState initialized. Final state: signedIn=$_signedIn, userId=$_userId, status=$_accountStatus, level=$_membershipLevel, hasToken=${_authToken.isNotEmpty}");
      notifyListeners();
    } catch (e, stacktrace) {
      _log.severe("Error initializing auth state from SharedPreferences: $e", e, stacktrace);
      // Reset to default signed-out state on error
      _signedIn = false;
      _accountStatus = '';
      _membershipLevel = '';
      _userId = '';
      _authToken = '';
      _gameDrawData = [];
      _requiresUpdate = false; // Ensure reset on error too
      notifyListeners();
    }
  }


  /// Saves a separate API key to SharedPreferences.
  Future<void> setApiKey(String apiKey) async {

    _log.fine('Saving API key to SharedPreferences.');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsApiKeyKey, apiKey);
  }

  /// Clears the current authentication state and removes the persisted state.
  Future<void> signOut() async {
    _log.info('Signing out and clearing auth state...');
    // Reset internal state variables
    _signedIn = false;
    _accountStatus = '';
    _membershipLevel = '';
    _userId = '';
    _authToken = '';
    _gameDrawData = [];
    _requiresUpdate = false; // Reset update flag on sign out

    // Notify listeners
    notifyListeners();

    // Remove keys from SharedPreferences
    try {
      final prefs = await SharedPreferences.getInstance();
      _log.fine('Removing auth keys from SharedPreferences...');
      await prefs.remove(_prefsSignedInKey);
      await prefs.remove(_prefsAccountStatusKey);
      await prefs.remove(_prefsMembershipLevelKey);
      await prefs.remove(_prefsUserIdKey);
      await prefs.remove(_prefsAuthTokenKey);
      // await prefs.remove(_prefsGameDrawDataKey);
      _log.info("Auth state cleared on sign out.");
    } catch(e, stacktrace) {
      _log.severe('Error clearing SharedPreferences on sign out: $e', e, stacktrace);
    }
  }

  /// Updates the account status to 'active'.
  Future<void> markEmailAsVerified() async {
    _log.info("Marking email as verified. Updating account status to 'active'.");
    if (_signedIn) {
      _accountStatus = 'active';
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_prefsAccountStatusKey, _accountStatus);
        _log.fine('Saved $_prefsAccountStatusKey = $_accountStatus');
        notifyListeners();
      } catch (e, stacktrace) {
        _log.severe('Error saving verified account status: $e', e, stacktrace);
      }
    } else {
      _log.warning("Attempted to mark email as verified, but user is not signed in.");
    }
  }
}
