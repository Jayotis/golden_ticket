import 'dart:convert'; // For json encoding/decoding if using payload
import 'dart:io'; // For platform checks

// Note: logging_utils.dart was imported twice, removed duplicate below
import 'package:firebase_core/firebase_core.dart'; // Needed for background handler re-init
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart'; // For kDebugMode (optional)
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:golden_ticket/src/golden_ticket/logging_utils.dart'; // Your logging import
import 'package:http/http.dart' as http; // For sending token to server

// Keep firebase_options import if needed by background handler's initializeApp
// import 'firebase_options.dart';

// --- Notification Channel Definition ---
// Define channel constants clearly at the top
const String channelId = 'golden_ticket_channel_id';
const String channelName = 'Golden Ticket Notifications';
const String channelDescription = 'Notifications for Golden Ticket game events and updates.';

// --- Flutter Local Notifications Plugin Instance ---
// Needs to be static or globally accessible to be used by the top-level background handler
// Initialized within setupFlutterNotifications
late FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin;

// Note: The actual background handler function (@pragma('vm:entry-point') _firebaseMessagingBackgroundHandler)
// should reside in main.dart as a top-level function.

class PushNotificationService {
  final FirebaseMessaging _firebaseMessaging = FirebaseMessaging.instance;

  // --- Static Setup Method ---
  // This method initializes the flutter_local_notifications plugin and creates the Android channel.
  // It MUST be called once during app startup (in main.dart) and potentially again
  // at the beginning of the background handler isolate to ensure initialization.
  static Future<void> setupFlutterNotifications() async {
    logThis("Setting up Flutter Local Notifications...");
    // Create the plugin instance
    flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

    // --- Android Channel Setup ---
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      channelId, // id
      channelName, // name
      description: channelDescription, // description
      importance: Importance.max, // Max importance ensures visibility
      // priority: Priority.high, // <-- REMOVED: Priority is not set on channel
      enableVibration: true, // Optional: enable vibration
    );

    // Create the channel on the device (does nothing on iOS/macOS)
    // This is idempotent, safe to call multiple times.
    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
    logThis("Android Notification Channel created/updated.");

    // --- Initialization Settings for flutter_local_notifications ---
    // Provide the app icon for Android notifications
    // Ensure '@mipmap/ic_launcher' corresponds to your actual launcher icon path
    const AndroidInitializationSettings initializationSettingsAndroid =
    AndroidInitializationSettings('@mipmap/ic_launcher');

    // Basic iOS/macOS initialization settings. Permissions are requested separately.
    const DarwinInitializationSettings initializationSettingsIOS = DarwinInitializationSettings(
      requestAlertPermission: false, // Permissions requested via FirebaseMessaging.requestPermission()
      requestBadgePermission: false,
      requestSoundPermission: false,
      // onDidReceiveLocalNotification: onDidReceiveLocalNotification, // <-- REMOVED: Deprecated
    );
    const DarwinInitializationSettings initializationSettingsMacOS = DarwinInitializationSettings( // If supporting macOS
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );

    const InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsIOS,
      macOS: initializationSettingsMacOS, // If supporting macOS
    );

    // Initialize the plugin
    await flutterLocalNotificationsPlugin.initialize(
      initializationSettings,
      // Callback for when a notification is tapped (foreground or background)
      onDidReceiveNotificationResponse: _onDidReceiveNotificationResponse,
      // onDidReceiveLocalNotification: onDidReceiveLocalNotification, // <-- REMOVED: Deprecated
    );
    logThis("Flutter Local Notifications Initialized.");
  }

  // --- Static Notification Display Method ---
  // This method displays the notification using the configured plugin.
  // It's static so it can be called from the top-level background handler.
  static void showFlutterNotification(RemoteMessage message) {
    logThis("Attempting to show Flutter notification for message: ${message.messageId}");
    RemoteNotification? notification = message.notification; // Standard FCM notification part
    Map<String, dynamic> data = message.data; // Custom data payload

    // --- Extract Title and Body ---
    // IMPORTANT: Prioritize data payload keys ('title', 'body') as the PHP backend sends data-only messages.
    // Fallback to standard notification fields if data keys are missing.
    String? title = data['title'] ?? notification?.title;
    String? body = data['body'] ?? notification?.body;

    logThis("Extracted Title: $title, Body: $body");

    // Ensure we have content to display
    if (title != null && body != null) {
      logThis("Proceeding to show notification via flutterLocalNotificationsPlugin.");
      // Use a unique ID for the notification. Hashcode is simple, but consider using an ID from `data` if available.
      int notificationId = notification.hashCode; // Or: int.tryParse(data['notification_id'] ?? '') ?? notification.hashCode;

      // Prepare style information if needed
      final BigTextStyleInformation? bigTextStyleInformation = body.isNotEmpty
          ? BigTextStyleInformation(body) // Use BigTextStyle to show more text
          : null;

      flutterLocalNotificationsPlugin.show(
        notificationId,
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            channelId, // Use the same channel ID created in setup
            channelName,
            channelDescription: channelDescription,
            icon: '@mipmap/ic_launcher', // Ensure this icon exists
            importance: Importance.max, // Match channel importance
            priority: Priority.high, // High priority for Android 7.1 and lower
            tag: data['tag'], // Optional: Group notifications using a tag from data
            styleInformation: bigTextStyleInformation, // Optional: Show more text
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true, // Show alert notification on iOS
            presentBadge: true, // Update app badge count (requires setup)
            presentSound: true, // Play notification sound
            subtitle: data['subtitle'], // Optional subtitle from data
            categoryIdentifier: data['categoryIdentifier'], // Optional: For notification actions
          ),
          macOS: DarwinNotificationDetails( // If supporting macOS
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
            subtitle: data['subtitle'],
            categoryIdentifier: data['categoryIdentifier'],
          ),
        ),
        // Optional: Pass data payload to the tap handler (_onDidReceiveNotificationResponse)
        payload: jsonEncode(message.data),
      );
      logThis("flutterLocalNotificationsPlugin.show() called for ID: $notificationId.");
    } else {
      logThis("Notification show skipped: Title or Body is null after checking data and notification payloads.");
    }
  }

  // --- Instance Initialization Method ---
  // Sets up foreground listeners and gets the initial token.
  Future<void> initialize() async {
    logThis("Initializing PushNotificationService instance...");

    // Request permissions (iOS and Android 13+)
    // This should ideally happen at a logical point in your app flow,
    // but initializing here is common.
    NotificationSettings settings = await _firebaseMessaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false, // Set to true for quieter iOS permissions initially
    );
    logThis('Notification permission status: ${settings.authorizationStatus}');
    // You might want to check settings.authorizationStatus and guide the user if denied.

    // --- Configure Listener Callbacks ---

    // Listen for messages received while the app is in the foreground
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      logThis('Foreground message received: ${message.messageId}');
      logThis('Foreground Message data: ${message.data}');
      if (message.notification != null) {
        logThis('Foreground Message also contained a notification payload: ${message.notification?.title}');
      }

      // IMPORTANT: For foreground messages on Android & iOS, FCM does NOT automatically
      // display a notification. We MUST call our display method here.
      showFlutterNotification(message);

    }, onError: (error) {
      logThis("Error in onMessage listener: $error");
    });

    // Listen for when a notification message (sent via FCM) is tapped by the user
    // when the app is in the background (but not terminated).
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      logThis('Notification tapped (app opened from background): ${message.messageId}');
      logThis('onMessageOpenedApp data: ${message.data}');
      // Usually, you navigate based on the message data here.
      // We pass the full data payload via the local notification's 'payload'
      // so _onDidReceiveNotificationResponse can handle navigation consistently.
      // No need to call showFlutterNotification here, as the tap action itself is the event.
      _handleNotificationTap(message.data); // Optional: Centralized tap handling

    }, onError: (error) {
      logThis("Error in onMessageOpenedApp listener: $error");
    });

    // Check if the app was opened from a terminated state via a notification tap
    RemoteMessage? initialMessage = await _firebaseMessaging.getInitialMessage();
    if (initialMessage != null) {
      logThis('App opened from terminated state via notification: ${initialMessage.messageId}');
      logThis('Initial Message data: ${initialMessage.data}');
      // Handle navigation based on the initial message data
      _handleNotificationTap(initialMessage.data); // Optional: Centralized tap handling
    }

    // --- Token Management ---
    // Listen for token refreshes (existing logic)
    _firebaseMessaging.onTokenRefresh.listen((String token) async { // Made async
      logThis("New FCM Token (Refreshed): $token");
      // Fetch current user details before sending
      String? userId = await _getCurrentUserId(); // <-- ADDED user fetch (Placeholder)
      String? authToken = await _getCurrentAuthToken(); // <-- ADDED token fetch (Placeholder)
      if (userId != null) {
        // Now calling with 3 args
        sendTokenToServer(userId, token, authToken);
      } else {
        logThis("User not logged in during token refresh, cannot update token on server.");
      }
    });

    // Get the initial token and send it (existing logic)
    await getTokenAndSend(); // Calls internal sendTokenToServer

    logThis("PushNotificationService Instance Initialized.");
  }


  // --- Static Callback for Notification Taps ---
  // This is triggered by flutter_local_notifications when a notification created by it is tapped.
  static void _onDidReceiveNotificationResponse(NotificationResponse notificationResponse) {
    final String? payload = notificationResponse.payload;
    logThis("Local notification tapped with payload: $payload");
    if (payload != null && payload.isNotEmpty) {
      try {
        Map<String, dynamic> data = jsonDecode(payload);
        logThis("Decoded tap payload data: $data");
        // Handle navigation or action based on the decoded data
        _handleNotificationTap(data);
      } catch (e) {
        logThis("Error decoding notification payload: $e");
      }
    } else {
      logThis("Notification tapped without a payload.");
      // Handle tap without specific data if necessary
    }
  }

  // --- Centralized Tap Handling Logic ---
  // Optional: Consolidate navigation/action logic here
  static void _handleNotificationTap(Map<String, dynamic> data) {
    logThis("Handling notification tap with data: $data");
    // Example: Check for a specific key in the data to decide where to navigate
    String? screen = data['navigate_to'];
    if (screen == 'results') {
      // Use a global navigator key or other navigation method
      // navigatorKey.currentState?.pushNamed('/results', arguments: data);
      logThis("Navigation action triggered for 'results' screen based on data.");
    } else {
      logThis("No specific navigation action found in data or action not implemented for: $screen");
    }
  }


  // --- Token Methods ---

  Future<String?> getToken() async {
    // Your existing getToken logic...
    try {
      String? token;
      if (Platform.isIOS || Platform.isMacOS) {
        logThis("Requesting APNS token...");
        String? apnsToken = await _firebaseMessaging.getAPNSToken();
        logThis("APNS Token: $apnsToken");
        // Add retry logic if needed as before
      }
      logThis("Requesting FCM token...");
      token = await _firebaseMessaging.getToken();
      logThis("FCM Token: $token");
      return token;
    } catch (e) {
      logThis("Error getting FCM token: $e");
      return null;
    }
  }

  // Modified to fetch user details before sending token
  Future<void> getTokenAndSend() async {
    String? token = await getToken();
    if (token != null) {
      // Fetch current user details before sending
      String? userId = await _getCurrentUserId(); // <-- ADDED user fetch (Placeholder)
      String? authToken = await _getCurrentAuthToken(); // <-- ADDED token fetch (Placeholder)
      if (userId != null) {
        // Now calling with 3 args
        await sendTokenToServer(userId, token, authToken);
      } else {
        logThis("User not logged in on initial token fetch, cannot send token to server yet.");
      }
    } else {
      logThis("Failed to get token, cannot send to server.");
    }
  }

  // Modified to accept userId and potentially authToken if needed for headers
  Future<void> sendTokenToServer(String userId, String token, String? authToken) async {
    // Use the passed-in userId
    if (userId.isEmpty) {
      logThis("User ID is empty. Cannot send token to server.");
      return;
    }

    // --- Determine Device Type ---
    String deviceType = 'unknown';
    if (Platform.isAndroid) {
      deviceType = 'android';
    } else if (Platform.isIOS) {
      // Consider adding Platform.isMacOS etc. if needed
      deviceType = 'ios';
    }
    logThis("Device Type detected: $deviceType");
    // --- End Determine Device Type ---


    // Ensure this URL points to your registration endpoint
    final url = Uri.parse('https://governance.page/wp-json/apigold/v1/device/register');
    logThis("Sending token for User ID: $userId to $url");

    // --- Prepare Headers ---
    // Include auth token required by the API endpoint
    final headers = {
      'Content-Type': 'application/json',

      if (authToken != null && authToken.isNotEmpty)
        'Authorization': 'Bearer $authToken',

    };
    logThis("Sending request with headers: $headers"); // Log headers (excluding sensitive token in production)
    // --- End Prepare Headers ---

    try {
      final response = await http.post(
        url,
        headers: headers, // Use headers map
        body: jsonEncode({
          'user_id': userId,
          'fcm_token': token,
          'device_type': deviceType, // <-- ADDED THIS FIELD
        }),
      );
      // Your existing response handling...
      if (response.statusCode == 200) {
        logThis('Token successfully sent to server: ${response.body}');
      } else {
        logThis('Failed to send token to server. Status code: ${response.statusCode}, Body: ${response.body}');
      }
    } catch (e) {
      logThis('Error sending token to server: $e');
    }
  }

  // --- Placeholder Methods - IMPLEMENT THESE ---
  // You need to implement these methods to retrieve the current user's data
  // possibly from AuthState, SharedPreferences, FlutterSecureStorage etc.
  // They are needed for token refreshes or initial fetches when the user might already be logged in.
  Future<String?> _getCurrentUserId() async {
    logThis("Placeholder: Attempting to get current user ID.");
    // Example: Replace with your actual logic using a state management solution
    // or secure storage to access logged-in user data without context.
    // final storedUserId = await SecureStorageService.getUserId();
    // return storedUserId;
    print("WARNING: _getCurrentUserId() needs implementation!"); // Reminder log
    return null; // Return null if not logged in or implementation pending
  }

  Future<String?> _getCurrentAuthToken() async {
    logThis("Placeholder: Attempting to get current auth token.");
    // Example: Replace with your actual logic
    // final storedAuthToken = await SecureStorageService.getAuthToken();
    // return storedAuthToken;
    print("WARNING: _getCurrentAuthToken() needs implementation!"); // Reminder log
    return null; // Return null if not logged in or implementation pending
  }

// --- Deprecated method removed ---
// static Future onDidReceiveLocalNotification(...) removed as it's deprecated and unused.
}
