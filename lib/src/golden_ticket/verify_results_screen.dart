import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:logging/logging.dart';
import 'logging_utils.dart';

class VerifyResultsScreen extends StatefulWidget {
  const VerifyResultsScreen({super.key});

  static const routeName = '/verify-results';

  @override
  VerifyResultsScreenState createState() => VerifyResultsScreenState();
}

class VerifyResultsScreenState extends State<VerifyResultsScreen> {
  final _log = Logger('VerifyResultsScreen'); // Create a logger for this screen

  @override
  void initState() {
    super.initState();
    LoggingUtils.setupLogger(_log); // Configure the logger
  }

  Future<void> _verifyResults() async {
    // Implement API call to /apigold/verify
    // You'll likely need to send the checksum and other data in the request body
    final url = Uri.https(
        'the.governance.page', '/wp-json/apigold/verify'); // Using HTTPS
    try {
      final response = await http.post(
        url,
        body: {
          // Your verification data
        },
      );

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body);
        // Handle successful verification
        _log.info('Verification result: $responseData'); // Use the logger
      } else {
        _log.warning('Verification failed: ${response.body}'); // Use the logger
      }
    } catch (e) {
      _log.severe('Error during verification: $e'); // Use the logger
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Verify Results'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('Verify your results here.'),
            ElevatedButton(
              onPressed: _verifyResults,
              child: const Text('Verify'),
            ),
          ],
        ),
      ),
    );
  }
}