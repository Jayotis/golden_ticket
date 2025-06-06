import 'package:flutter/material.dart';
// Import the http package for making API calls.
import 'package:http/http.dart' as http;
// Import dart:convert for JSON encoding/decoding.
import 'dart:convert';
// Import logging framework.
import 'package:logging/logging.dart';
// Import url_launcher for opening external URLs (like email verification links).
import 'package:url_launcher/url_launcher.dart';


// --- Project-Specific Imports ---
// Import utility for setting up loggers.
import 'logging_utils.dart';
// Import the screen used for selecting a game event.
import 'game_selector_screen.dart';


// DatabaseHelper import is currently commented out (DB setup moved to sign-in).
// import 'database_helper.dart';
// AuthState import is currently commented out (not directly needed for account creation logic here).
// import 'auth/auth_state.dart';

/// A StatefulWidget representing the Create Account screen.
/// Collects user details for registration.
class CreateAccountScreen extends StatefulWidget {
  const CreateAccountScreen({super.key});

  // Route name for navigation.
  static const routeName = '/create-account';

  @override
  CreateAccountScreenState createState() => CreateAccountScreenState();
}

/// The State class for the CreateAccountScreen widget.
/// Manages the form state, input controllers, and account creation process.
class CreateAccountScreenState extends State<CreateAccountScreen> {
  // Logger for this specific screen.
  final _log = Logger('CreateAccountScreen');
  // GlobalKey to manage the Form state and validation.
  final _formKey = GlobalKey<FormState>();
  // Text editing controllers for each input field.
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _emailController = TextEditingController();
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();

  // State variable to store the name of the game event selected by the user.
  // Starts as null; selection is mandatory before creating the account.
  String? _selectedGameEvent;
  // Flag to indicate if an account creation API call is in progress.
  // Used to disable the button and show a loading indicator.
  bool _isCreatingAccount = false;

  @override
  void initState() {
    super.initState();
    // Configure the logger for this screen.
    LoggingUtils.setupLogger(_log);
    // Initial game selection is no longer pre-filled; user must explicitly select.
  }

  /// Navigates to the GameSelectorScreen to allow the user to pick a game event.
  /// Updates the state with the selected game name upon return.
  Future<void> _selectGameEvent() async {
    // Navigate to the GameSelectorScreen using its defined route name.
    // `await` pauses execution until the GameSelectorScreen is popped.
    final result = await Navigator.pushNamed(
      context,
      GameSelectorScreen.routeName,
    );

    // Check if a result was returned (i.e., the user confirmed a selection)
    // and if the result is of the expected type (String).
    if (result != null && result is String) {
      // Update the state to store the selected game event name.
      setState(() {
        _selectedGameEvent = result;
      });
      _log.info('Selected game event: $_selectedGameEvent');
    } else {
      _log.info('No game event selected or invalid result type returned.');
    }
  }


  /// Handles the account creation process:
  /// 1. Validates the form and checks for game selection.
  /// 2. Makes an API call to the /register endpoint.
  /// 3. Handles the API response (success or failure).
  /// 4. Navigates back or shows errors accordingly.
  /// 5. Handles optional email verification link launching.
  Future<void> _createAccount() async {
    // --- Validation Step 1: Check if a game has been selected ---
    if (_selectedGameEvent == null) {
      _showSnackBar('Please select a preferred game.'); // Show error if no game selected.
      return; // Stop the process.
    }
    // --- End Validation Step 1 ---

    // --- Validation Step 2: Validate the form fields ---
    // Also check if an account creation process is already running.
    if (_formKey.currentState!.validate() && !_isCreatingAccount) {
      // Set the flag to indicate process start (disables button, shows loading).
      setState(() {
        _isCreatingAccount = true;
      });

      // Define the API endpoint for registration.
      final url = Uri.https('governance.page', '/wp-json/apigold/v1/register');

      // Store username for potential use after success (e.g., passing back to sign-in).
      final username = _usernameController.text.trim();

      try {
        // Prepare the request body with user input, trimming whitespace.
        final body = {
          'username': username,
          'password': _passwordController.text,
          'email': _emailController.text.trim(),
          'first_name': _firstNameController.text.trim(),
          'last_name': _lastNameController.text.trim(),
          // Optionally include 'preferred_game': _selectedGameEvent if the API requires it.
        };

        _log.fine("Request Body (before encoding): $body");

        // Make the POST request to the registration API.
        final response = await http.post(
          url,
          headers: { 'Content-Type': 'application/json' }, // Set content type header.
          body: json.encode(body), // Encode the body map as a JSON string.
        );

        _log.info("Request Body (sent): ${json.encode(body)}");
        _log.info("Response Status Code: ${response.statusCode}");
        _log.info("Response Body: ${response.body}");

        // After await, check if the widget is still mounted.
        if (!mounted) return;

        // Decode the JSON response from the API.
        final responseData = json.decode(response.body);
        // Extract the message from the response, providing a default error message.
        final responseMessage = responseData['message'] ?? 'An error occurred.';

        // Check for successful account creation (HTTP 200 and 'status' == 'success').
        if (response.statusCode == 200 && responseData['status'] == 'success') {
          _log.info('Account creation successful (API status: success). Message: $responseMessage');
          _showSnackBar(responseMessage); // Show the success message from the server.

          // Navigate back to the previous screen (likely SignInScreen), passing the created username.
          // Note: SignInScreen's prefill logic using this username was removed, but pop still occurs.
          Navigator.pop(context, username);

          // Check if the response includes an email verification URL.
          final verificationUrl = responseData['data']?['verification_url'];
          if (verificationUrl != null && verificationUrl is String) {
            // If a URL is provided, attempt to launch it.
            _launchVerificationUrl(verificationUrl);
          }

        } else {
          // Handle account creation failure (non-200 status or 'status' != 'success').
          _log.warning('Account creation failed. Status: ${response.statusCode}, Body: ${response.body}');
          _showSnackBar(responseMessage); // Show the error message from the server.
        }

      } catch (e, stacktrace) { // Catch any exceptions during the process.
        _log.severe('Error during account creation process: $e', e, stacktrace); // Log error and stacktrace.
        if (mounted) {
          _showSnackBar('An unexpected error occurred during account creation.');
        }
      } finally {
        // This block executes whether the try block succeeded or failed.
        // Ensure the loading state is reset.
        if(mounted) {
          setState(() {
            _isCreatingAccount = false; // Re-enable the button.
          });
        }
      }
    }
  }

  /// Helper function to display a SnackBar message.
  void _showSnackBar(String text) {
    if (mounted) { // Check if the widget is still in the tree.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(text)),
      );
    }
  }

  /// Attempts to launch the provided URL (typically an email verification link)
  /// using the url_launcher package. Prefers opening in an external application (browser/email client).
  Future<void> _launchVerificationUrl(String url) async {
    final uri = Uri.parse(url);
    // Check if the URL can be launched.
    if (await canLaunchUrl(uri)) {
      // Launch the URL, preferring an external application.
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      // Log and show an error if the URL cannot be launched.
      _log.warning('Could not launch verification URL: $url');
      _showSnackBar('Could not open verification link. Please check your email.');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Build the UI for the Create Account screen.
    return Scaffold(
      appBar: AppBar(
        title: const Text('Create Account'),
      ),
      // Use a Form widget to enable validation.
      body: Form(
        key: _formKey, // Associate the GlobalKey with the Form.
        // Use SingleChildScrollView to prevent overflow on smaller screens.
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              // Username field with validation.
              TextFormField(
                controller: _usernameController,
                decoration: const InputDecoration(labelText: 'Username'),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter a username';
                  }
                  if (value.length < 4) {
                    return 'Username must be at least 4 characters';
                  }
                  return null; // Return null if validation passes.
                },
              ),
              // Email field with validation.
              TextFormField(
                controller: _emailController,
                decoration: const InputDecoration(labelText: 'Email'),
                keyboardType: TextInputType.emailAddress, // Use email keyboard type.
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter an email address';
                  }
                  // Basic email format validation using RegExp.
                  final emailRegex = RegExp(r"^[a-zA-Z0-9.a-zA-Z0-9.!#$%&'*+-/=?^_`{|}~]+@[a-zA-Z0-9]+\.[a-zA-Z]+");
                  if (!emailRegex.hasMatch(value)) {
                    return 'Please enter a valid email address';
                  }
                  return null; // Return null if validation passes.
                },
              ),
              // First Name field with validation.
              TextFormField(
                controller: _firstNameController,
                decoration: const InputDecoration(labelText: 'First Name'),
                textCapitalization: TextCapitalization.words, // Capitalize first letter of each word.
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter your first name';
                  }
                  return null;
                },
              ),
              // Last Name field with validation.
              TextFormField(
                controller: _lastNameController,
                decoration: const InputDecoration(labelText: 'Last Name'),
                textCapitalization: TextCapitalization.words, // Capitalize first letter of each word.
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter your last name';
                  }
                  return null;
                },
              ),
              // Password field with validation.
              TextFormField(
                controller: _passwordController,
                decoration: const InputDecoration(labelText: 'Password'),
                obscureText: true, // Hide password characters.
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter a password';
                  }
                  if (value.length < 6) { // Example minimum length validation.
                    return 'Password must be at least 6 characters';
                  }
                  return null; // Return null if validation passes.
                },
              ),
              const SizedBox(height: 20), // Spacing.

              // --- Game Selection UI ---
              // Row to display selected game and provide a button to select one.
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Display the currently selected game or a prompt to select one.
                  Expanded( // Allow text to wrap if needed.
                    child: Text(
                      _selectedGameEvent == null
                          ? 'Select Preferred Game (Required):' // Prompt if no game selected.
                          : 'Selected Game: $_selectedGameEvent', // Show selected game.
                      style: const TextStyle(fontSize: 16),
                    ),
                  ),
                  // Button to trigger the game selection process.
                  TextButton(
                    onPressed: _selectGameEvent, // Call the selection function.
                    child: const Text('Select'),
                  ),
                ],
              ),
              // --- End Game Selection UI ---

              const SizedBox(height: 20), // Spacing.

              // Create Account button.
              ElevatedButton(
                // Disable the button if account creation is in progress.
                onPressed: _isCreatingAccount ? null : _createAccount,
                // Conditionally display a loading indicator or the button text.
                child: _isCreatingAccount
                    ? const SizedBox( // Show a small circular progress indicator.
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)
                )
                    : const Text('Create Account'), // Show button text.
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    // Dispose of the TextEditingControllers to free up resources.
    _usernameController.dispose();
    _passwordController.dispose();
    _emailController.dispose();
    _firstNameController.dispose();
    _lastNameController.dispose();
    super.dispose();
  }
}