import 'package:flutter/material.dart';
// Import the http package for making API calls.
import 'package:http/http.dart' as http;
// Import dart:convert for JSON encoding/decoding.
import 'dart:convert';
// Import Provider for accessing shared state like AuthState.
import 'package:provider/provider.dart';
// Import dart:async for handling asynchronous operations like TimeoutException.
import 'dart:async';
// Import logging framework.
import 'package:logging/logging.dart';

// --- Project-Specific Imports ---
// Import the authentication state management class.
import 'auth/auth_state.dart'; // Ensure this path is correct
// Import utility for setting up loggers.
import 'logging_utils.dart'; // Ensure this path is correct
// Import named route constants.
import 'routes.dart'; // Ensure this path is correct
// Import the database helper for local profile/progress updates upon sign-in.
import 'database_helper.dart'; // Ensure this path is correct
// Import the push notification service.
import '../../push_notification_service.dart'; // Ensure this path is correct

/// A StatefulWidget representing the Sign In screen.
/// Allows users to enter their credentials and attempt to log in.
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  // Route name used for navigation to this screen.
  static const routeName = '/sign-in';

  @override
  SignInScreenState createState() => SignInScreenState();
}

/// The State class for the SignInScreen widget. Manages the screen's state,
/// including input controllers and the sign-in process status.
class SignInScreenState extends State<SignInScreen> {
  // Logger instance for logging events specific to this screen.
  final _log = Logger('SignInScreen');
  // Text editing controllers to manage the input fields.
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  // Boolean flag to track if a sign-in attempt is currently in progress.
  // Used to disable buttons and show a loading indicator.
  bool _isSigningIn = false;

  // Get an instance of the push notification service
  // Consider using Provider or GetIt for better dependency injection in larger apps
  final PushNotificationService _pushNotificationService = PushNotificationService();

  @override
  void initState() {
    super.initState();
    // Initialize the logger for this screen when the state is created.
    LoggingUtils.setupLogger(_log);
  }

  /// Attempts to sign the user in by:
  /// 1. Validating input.
  /// 2. Calling the backend login API.
  /// 3. Handling the API response (success or failure).
  /// 4. Updating the global AuthState (including version check).
  /// 5. Updating local database records (profile, game progress).
  /// 6. Getting/Sending the FCM token.
  /// 7. Navigating the user accordingly.
  Future<void> _signIn() async {
    // Exit if the widget is no longer mounted or if a sign-in is already happening.
    if (!mounted || _isSigningIn) return;

    // Update the UI to show the loading state.
    setState(() {
      _isSigningIn = true;
    });

    // Retrieve username and password from the text controllers.
    final username = _usernameController.text.trim();
    final password = _passwordController.text;

    // Validate that both username and password fields are filled.
    if (username.isEmpty || password.isEmpty) {
      _showSnackBar('Please enter both username and password.');
      // Reset loading state and exit.
      setState(() => _isSigningIn = false);
      return;
    }

    // Construct the URL for the login API endpoint.
    final url = Uri.https('governance.page', '/wp-json/apigold/v1/login');

    try {
      _log.info("Attempting sign in for user: $username");
      // Perform the POST request to the login API endpoint.
      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json', // Specify JSON content type.
        },
        body: jsonEncode({ // Send username and password in the request body as JSON.
          'username': username,
          'password': password,
        }),
      ).timeout(const Duration(seconds: 15)); // Apply a 15-second timeout.

      // After the await, check if the widget is still mounted before proceeding.
      if (!mounted) return;

      // Decode the JSON response from the API.
      final responseData = json.decode(response.body);

      // Check for a successful response (HTTP 200) and a success code within the response body.
      if (response.statusCode == 200 && responseData['code'] == 'success') {
        _log.info('Sign in successful: $responseData');

        // Extract the user data payload from the response.
        final data = responseData['data'];
        // Ensure the data payload exists and is a Map.
        if (data == null || data is! Map) {
          _log.severe('Sign in response missing or invalid "data" field.');
          _showSnackBar('Sign in failed: Invalid response from server.');
          setState(() => _isSigningIn = false);
          return;
        }

        // Extract specific user details from the data payload.
        final userId = data['user_id'];
        final accountStatus = data['account_status'];
        final membershipLevel = data['membership_level'];
        final authToken = data['auth_token'];
        final minimumRequiredVersionStr = data['app_version'];
        _log.fine("Extracted minimum required version from API: $minimumRequiredVersionStr");


        // --- Validate Extracted Data ---
        if (userId == null || userId is! int ||
            accountStatus == null || accountStatus is! String || accountStatus.isEmpty ||
            membershipLevel == null || membershipLevel is! String || membershipLevel.isEmpty ||
            authToken == null || authToken is! String || authToken.isEmpty ||
            minimumRequiredVersionStr == null || minimumRequiredVersionStr is! String || minimumRequiredVersionStr.isEmpty)
        {
          _log.severe('Sign in response data invalid.');
          _showSnackBar('Sign in failed: Invalid response data.');
          setState(() => _isSigningIn = false);
          return;
        }
        final String userIdStr = userId.toString(); // Use String for consistency
        // --- End Data Validation ---


        // --- Update AuthState (now async and includes version) ---
        final authState = context.read<AuthState>();
        await authState.setSignInStatus(
          signedIn: true,
          accountStatus: accountStatus,
          membershipLevel: membershipLevel,
          userId: userIdStr, // Pass String userId
          authToken: authToken,
          gameDrawData: [], // Placeholder for game draw data.
          minimumRequiredVersionStr: minimumRequiredVersionStr, // Pass the extracted version
        );
        _log.info("AuthState updated. Requires update flag set to: ${authState.requiresUpdate}");


        // --- Update Local Database ---
        try {
          final dbHelper = DatabaseHelper();
          await dbHelper.insertOrUpdateUserProfile(
              userId: userId,
              membershipLevel: membershipLevel,
              globalAwards: [], // Initialize empty lists/maps as needed.
              globalStatistics: '{}'
          );
          _log.info('Local user profile created/updated for user ID: $userId upon sign-in.');

          const String defaultGameName = "lotto649";
          final existingProgress = await dbHelper.getUserGameProgress(userId, defaultGameName);
          if (existingProgress == null) {
            await dbHelper.upsertUserGameProgress(
                userId: userId,
                gameName: defaultGameName,
                scoreToAdd: 0,
                gameAwardsToAdd: [],
                gameStatistics: '{}'
            );
            _log.info('Added default game progress ($defaultGameName) for user ID: $userId upon sign-in.');
          }
        } catch (dbError) {
          _log.severe('Error setting up local profile/progress for user ID $userId during sign-in: $dbError');
          _showSnackBar('Warning: Could not update local profile/game data.');
        }
        _log.info('Local profile/progress updated.');
        // --- End Local Database Updates ---


        // ******** GET AND SEND FCM TOKEN ********
        try {
          _log.info("Attempting to get/send FCM token after login...");
          // Get the token using the service instance
          String? fcmToken = await _pushNotificationService.getToken();

          if (fcmToken != null) {
            // Send the token to your backend API using the function we defined in push_notification_service.dart
            // Pass the necessary details from the successful login
            await _pushNotificationService.sendTokenToServer(userIdStr, fcmToken, authToken);
          } else {
            _log.warning("Could not get FCM token after login to send to server.");
            // Optionally inform the user, but don't block login
            _showSnackBar("Push notifications might not be enabled.");
          }
        } catch (e) {
          _log.severe("Error getting or sending FCM token after login: $e");
          // Handle error, but don't block login flow
          _showSnackBar("Error setting up push notifications.");
        }
        // ******** END FCM TOKEN HANDLING ********


        // Navigate to the main application screen after successful sign-in.
        _navigateToHomeScreen();

      } else {
        // Handle cases where the API call was technically successful (e.g., status 200)
        // but the response indicates a logical failure (e.g., wrong password).
        final errorMessage = responseData['message'] ?? 'Sign in failed.';
        _log.warning('Failed to sign in. Status: ${response.statusCode}, Message: $errorMessage');
        _showSnackBar(errorMessage); // Display the error message from the API.
      }
    } on TimeoutException {
      // Handle network timeouts during the API call.
      _log.warning('Sign in timed out.');
      if (mounted) _showSnackBar('Sign in request timed out. Please try again.');
    } catch (e, stacktrace) {
      // Handle any other exceptions during the sign-in process (e.g., network errors, JSON parsing errors).
      _log.severe('Error signing in: $e', e, stacktrace);
      if (mounted) _showSnackBar('An unexpected error occurred during sign in.');
    } finally {
      // This block always executes, regardless of success or failure.
      // Reset the loading state.
      if (mounted) {
        setState(() {
          _isSigningIn = false;
        });
      }
    }
  }

  /// Navigates the user to the Create Account screen.
  Future<void> _navigateToCreateAccount() async {
    // Use named routes for navigation.
    Navigator.pushNamed(context, Routes.createAccount);
    _log.info("Navigated to Create Account screen.");
  }

  /// Navigates the user to the main application screen (usually after login)
  /// and removes all previous routes from the navigation stack, preventing
  /// the user from navigating back to the login screen.
  void _navigateToHomeScreen() {
    if (mounted) {
      Navigator.pushNamedAndRemoveUntil(
        context,
        Routes.main, // The route name of the main screen.
            (Route<dynamic> route) => false, // This predicate removes all routes below the new route.
      );
    }
  }

  /// A utility function to display a short message at the bottom of the screen.
  void _showSnackBar(String text) {
    // Ensure the widget is still mounted before trying to show the SnackBar.
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(text)),
      );
    }
  }

  @override
  void dispose() {
    // Clean up the text editing controllers when the widget state is disposed
    // to prevent memory leaks.
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Defines the visual structure of the Sign In screen.
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sign In'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0), // Add padding around the content.
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center, // Center the column vertically.
          children: [
            // Text field for username or email input.
            TextField(
              controller: _usernameController,
              decoration: const InputDecoration(labelText: 'Username or Email'),
              keyboardType: TextInputType.emailAddress, // Suggest email keyboard.
              textInputAction: TextInputAction.next, // Show 'next' button on keyboard.
            ),
            // Text field for password input.
            TextField(
              controller: _passwordController,
              decoration: const InputDecoration(labelText: 'Password'),
              obscureText: true, // Hide the entered text.
              textInputAction: TextInputAction.done, // Show 'done' button on keyboard.
              onSubmitted: (_) => _signIn(), // Trigger sign-in when 'done' is pressed.
            ),
            const SizedBox(height: 20), // Vertical spacing.
            // The main Sign In button.
            ElevatedButton(
              // Disable the button if a sign-in is in progress (_isSigningIn is true).
              onPressed: _isSigningIn ? null : _signIn,
              // Conditionally display either a loading indicator or the button text.
              child: _isSigningIn
                  ? const SizedBox( // Show a small circular progress indicator.
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)
              )
                  : const Text('Sign In'), // Show the button text.
            ),
            const SizedBox(height: 16), // Vertical spacing.
            // Text button to navigate to the account creation screen.
            TextButton(
              // Disable the button if a sign-in is in progress.
              onPressed: _isSigningIn ? null : _navigateToCreateAccount,
              child: const Text('Create Free Account'),
            ),
          ],
        ),
      ),
    );
  }
}
