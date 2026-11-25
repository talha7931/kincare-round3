import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kincare_android/auth_network_diagnostics.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('auth network diagnostic classification', () {
    test('distinguishes socket DNS lookup failures', () {
      expect(
        AuthNetworkDiagnostics.classify(SocketException(
            'Failed host lookup: zlnftsomgkwbwoommtfd.supabase.co')),
        NetworkFailureCategory.dnsLookupFailure,
      );
      expect(
        AuthNetworkDiagnostics.classify(AuthRetryableFetchException(
            message:
                'SocketException: Failed host lookup: zlnftsomgkwbwoommtfd.supabase.co')),
        NetworkFailureCategory.dnsLookupFailure,
      );
    });

    test('distinguishes connection failures and timeouts', () {
      expect(
        AuthNetworkDiagnostics.classify(SocketException('Connection refused')),
        NetworkFailureCategory.connectionFailure,
      );
      expect(
        AuthNetworkDiagnostics.classify(
            AuthRetryableFetchException(message: 'Connection reset')),
        NetworkFailureCategory.connectionFailure,
      );
      expect(
        AuthNetworkDiagnostics.classify(
            TimeoutException('operation timed out')),
        NetworkFailureCategory.timeout,
      );
      expect(
        AuthNetworkDiagnostics.classify(
            AuthRetryableFetchException(message: 'Socket timed out')),
        NetworkFailureCategory.timeout,
      );
    });

    test('distinguishes API responses, auth errors and missing configuration',
        () {
      expect(
        AuthNetworkDiagnostics.classify(PostgrestException(
            message: 'API rejected the request', code: '400')),
        NetworkFailureCategory.httpApiResponse,
      );
      expect(
        AuthNetworkDiagnostics.classify(AuthRetryableFetchException(
            message: 'service unavailable', statusCode: '503')),
        NetworkFailureCategory.httpApiResponse,
      );
      expect(
        AuthNetworkDiagnostics.classify(AuthApiException('Invalid credentials',
            statusCode: '401', code: 'invalid_credentials')),
        NetworkFailureCategory.authException,
      );
      expect(
        AuthNetworkDiagnostics.classify(
            const MissingSupabaseConfigurationException()),
        NetworkFailureCategory.missingConfiguration,
      );
    });

    test('safe log output excludes exception text and supplied secrets', () {
      const phone = '+15550001111';
      const password = 'do-not-log-this-password';
      const key = 'sb_publishable_do-not-log-this-key';
      final line = AuthNetworkDiagnostics.safeLogLine(
        operation: 'email_sign_in',
        error: AuthApiException(
          'phone=$phone password=$password key=$key',
          statusCode: '400',
          code: 'invalid_credentials',
        ),
        host: 'zlnftsomgkwbwoommtfd.supabase.co',
      );

      expect(line, contains('category=auth_exception'));
      expect(line, contains('http_status=400'));
      expect(line, contains('zlnftsomgkwbwoommtfd.supabase.co'));
      expect(line, isNot(contains(phone)));
      expect(line, isNot(contains(password)));
      expect(line, isNot(contains(key)));
      expect(line, isNot(contains('invalid_credentials')));
    });
  });
}
