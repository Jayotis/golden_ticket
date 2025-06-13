import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:logging/logging.dart';
import 'package:url_launcher/url_launcher.dart';

// --- Project-Specific Imports ---
import 'logging_utils.dart';
import 'game_selector_screen.dart';
// Import the DatabaseHelper for profile/game activation logic
import 'database_helper.dart';

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
  final _log = Logger('CreateAccountScreen');
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _emailController = TextEditingController();

  // State variable to store the name of the game event selected by the user.
  String? _selectedGameEvent;
  bool _isCreatingAccount = false;

  @override
  void initState() {
    super.initState();
    LoggingUtils.setupLogger(_log);
  }

  /// Navigates to the GameSelectorScreen to allow the user to pick a game event.
  Future<void> _selectGameEvent() async {
    final result = await Navigator.pushNamed(
      context,
      GameSelectorScreen.routeName,
    );
    if (result != null && result is String) {
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
  /// 3. On success, creates a local user profile and adds the selected game as active.
  /// 4. Handles errors and verification.
  Future<void> _createAccount() async {
    if (_selectedGameEvent == null) {
      _showSnackBar('Please select a preferred game.');
      return;
    }
    if (_formKey.currentState!.validate() && !_isCreatingAccount) {
      setState(() {
        _isCreatingAccount = true;
      });

      final url = Uri.https('governance.page', '/wp-json/apigold/v1/register');
      final username = _usernameController.text.trim();
      final email = _emailController.text.trim();

      try {
        final body = {
          'username': username,
          'password': _passwordController.text,
          'email': email,
          'preferred_game': _selectedGameEvent,
        };

        _log.fine("Request Body (before encoding): $body");

        final response = await http.post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: json.encode(body),
        );

        _log.info("Request Body (sent): ${json.encode(body)}");
        _log.info("Response Status Code: ${response.statusCode}");
        _log.info("Response Body: ${response.body}");

        if (!mounted) return;

        final responseData = json.decode(response.body);
        final responseMessage = responseData['message'] ?? 'An error occurred.';

        // Successful account creation
        if (response.statusCode == 200 && responseData['status'] == 'success') {
          _log.info('Account creation successful (API status: success). Message: $responseMessage');
          _showSnackBar(responseMessage);

          // --- NEW: Create local profile and activate selected game ---
          // 1. Extract the user_id from the response if available.
          final userId = int.tryParse(responseData['user_id']?.toString() ?? '');
          if (userId != null) {
            // Create a minimal user profile in the local DB
            await DatabaseHelper().insertOrUpdateUserProfile(userId: userId);
            // Activate the selected game for this user in local DB
            await DatabaseHelper().activateGameForUser(userId, _selectedGameEvent!);
          } else {
            _log.warning('No user_id received from API; skipping local profile creation.');
          }
          // --- END NEW ---

          Navigator.pop(context, username);

          // Check for email verification URL
          final verificationUrl = responseData['data']?['verification_url'];
          if (verificationUrl != null && verificationUrl is String) {
            _launchVerificationUrl(verificationUrl);
          }
        } else {
          _log.warning('Account creation failed. Status: ${response.statusCode}, Body: ${response.body}');
          _showSnackBar(responseMessage);
        }
      } catch (e, stacktrace) {
        _log.severe('Error during account creation process: $e', e, stacktrace);
        if (mounted) {
          _showSnackBar('An unexpected error occurred during account creation.');
        }
      } finally {
        if (mounted) {
          setState(() {
            _isCreatingAccount = false;
          });
        }
      }
    }
  }

  /// Helper function to display a SnackBar message.
  void _showSnackBar(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(text)),
      );
    }
  }

  Future<void> debugPrintActiveGames(int userId) async {
    final db = await DatabaseHelper().database;
    final rows = await db.query('user_active_games', where: 'user_id = ?', whereArgs: [userId]);
    print('DEBUG: user_active_games for user $userId:');
    for (var row in rows) {
      print(row);
    }
  }
  
  /// Attempts to launch a verification URL.
  Future<void> _launchVerificationUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      _log.warning('Could not launch verification URL: $url');
      _showSnackBar('Could not open verification link. Please check your email.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Create Account'),
      ),
      body: Form(
        key: _formKey,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              // Username field with validation
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
                  return null;
                },
              ),
              // Email field with validation
              TextFormField(
                controller: _emailController,
                decoration: const InputDecoration(labelText: 'Email'),
                keyboardType: TextInputType.emailAddress,
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter an email address';
                  }
                  final emailRegex = RegExp(
                      r"^[a-zA-Z0-9.a-zA-Z0-9.!#$%&'*+-/=?^_`{|}~]+@[a-zA-Z0-9]+\.[a-zA-Z]+");
                  if (!emailRegex.hasMatch(value)) {
                    return 'Please enter a valid email address';
                  }
                  return null;
                },
              ),
              // Password field with validation
              TextFormField(
                controller: _passwordController,
                decoration: const InputDecoration(labelText: 'Password'),
                obscureText: true,
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter a password';
                  }
                  if (value.length < 6) {
                    return 'Password must be at least 6 characters';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 20),
              // --- Game Selection UI ---
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      _selectedGameEvent == null
                          ? 'Select Preferred Game (Required):'
                          : 'Selected Game: $_selectedGameEvent',
                      style: const TextStyle(fontSize: 16),
                    ),
                  ),
                  TextButton(
                    onPressed: _selectGameEvent,
                    child: const Text('Select'),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: (_isCreatingAccount || _selectedGameEvent == null) ? null : _createAccount,
                child: _isCreatingAccount
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('Create Account'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _emailController.dispose();
    super.dispose();
  }
}