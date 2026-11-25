import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:supabase_flutter/supabase_flutter.dart';

enum NetworkFailureCategory {
  dnsLookupFailure,
  connectionFailure,
  timeout,
  httpApiResponse,
  authException,
  missingConfiguration,
  unexpected,
}

class MissingSupabaseConfigurationException implements Exception {
  const MissingSupabaseConfigurationException();

  @override
  String toString() =>
      'Missing SUPABASE_URL or SUPABASE_PUBLISHABLE_KEY dart-define values.';
}

/// Emits only fixed operation names, a host, error category, and safe codes.
/// Raw exception messages, request bodies, credentials and user input are
/// deliberately excluded.
class AuthNetworkDiagnostics {
  AuthNetworkDiagnostics._();

  static NetworkFailureCategory classify(Object error) {
    if (error is MissingSupabaseConfigurationException) {
      return NetworkFailureCategory.missingConfiguration;
    }
    if (error is TimeoutException) return NetworkFailureCategory.timeout;
    if (error is SocketException) return _classifySocket(error);
    if (error is AuthUnknownException) {
      if (error.statusCode != null) {
        return NetworkFailureCategory.httpApiResponse;
      }
      return classify(error.originalError);
    }
    if (error is AuthRetryableFetchException) {
      if (error.statusCode != null) {
        return NetworkFailureCategory.httpApiResponse;
      }
      return _classifyTransportText(error.message);
    }
    if (error is AuthException) return NetworkFailureCategory.authException;
    if (error is PostgrestException) {
      return NetworkFailureCategory.httpApiResponse;
    }
    if (error is StorageException) {
      return NetworkFailureCategory.httpApiResponse;
    }
    if (error is HttpException) {
      if (_looksLikeTimeout(error.message)) {
        return NetworkFailureCategory.timeout;
      }
      return NetworkFailureCategory.connectionFailure;
    }
    // PostgREST may surface package:http ClientException directly. Avoid a
    // separate dependency import for this type check.
    if (error.runtimeType.toString() == 'ClientException') {
      return _classifyTransportText(error.toString());
    }
    return NetworkFailureCategory.unexpected;
  }

  static NetworkFailureCategory _classifySocket(SocketException error) {
    final details = '${error.message} ${error.osError?.message ?? ''}';
    return _classifyTransportText(details);
  }

  static NetworkFailureCategory _classifyTransportText(String details) {
    if (_looksLikeDnsFailure(details)) {
      return NetworkFailureCategory.dnsLookupFailure;
    }
    if (_looksLikeTimeout(details)) return NetworkFailureCategory.timeout;
    return NetworkFailureCategory.connectionFailure;
  }

  static bool _looksLikeDnsFailure(String message) {
    final value = message.toLowerCase();
    return value.contains('failed host lookup') ||
        value.contains('no address associated with hostname') ||
        value.contains('name or service not known') ||
        value.contains('nodename nor servname provided') ||
        value.contains('temporary failure in name resolution') ||
        value.contains('no such host');
  }

  static bool _looksLikeTimeout(String message) {
    final value = message.toLowerCase();
    return value.contains('timeout') || value.contains('timed out');
  }

  static String safeLogLine({
    required String operation,
    required Object error,
    required String host,
  }) {
    final fields = <String>[
      'operation=$operation',
      'category=${_categoryName(classify(error))}',
      'host=${_safeHost(host)}',
      'exception=${error.runtimeType}',
    ];
    if (error is SocketException && error.osError?.errorCode != null) {
      fields.add('os_code=${error.osError!.errorCode}');
    }
    if (error is AuthException && error.statusCode != null) {
      fields.add('http_status=${_safeStatus(error.statusCode!)}');
    } else if (error is PostgrestException &&
        int.tryParse(error.code ?? '') != null) {
      fields.add('http_status=${error.code}');
    } else if (error is StorageException && error.statusCode != null) {
      fields.add('http_status=${_safeStatus(error.statusCode!)}');
    }
    return fields.join(' ');
  }

  static void logFailure({
    required String operation,
    required Object error,
    required String host,
  }) {
    debugPrint(
      '[kincare.network] '
      '${safeLogLine(operation: operation, error: error, host: host)}',
    );
  }

  static void logMissingConfiguration({
    required bool urlMissing,
    required bool publishableKeyMissing,
  }) {
    debugPrint(
      '[kincare.network] operation=supabase_initialize '
      'category=missing_configuration '
      'url_missing=$urlMissing '
      'publishable_key_missing=$publishableKeyMissing',
    );
  }

  static void logConfigurationReady({required String host}) {
    debugPrint(
      '[kincare.network] operation=supabase_initialize '
      'category=configuration_ready '
      'host=${_safeHost(host)} publishable_key_configured=true',
    );
  }

  static String _safeStatus(String value) =>
      RegExp(r'^\d{3}$').hasMatch(value) ? value : 'unavailable';

  static String _safeHost(String value) {
    final host = value.trim().toLowerCase();
    if (host.isEmpty || !RegExp(r'^[a-z0-9.-]+$').hasMatch(host)) {
      return 'unavailable';
    }
    return host;
  }

  static String _categoryName(NetworkFailureCategory category) =>
      switch (category) {
        NetworkFailureCategory.dnsLookupFailure => 'dns_lookup_failure',
        NetworkFailureCategory.connectionFailure => 'connection_failure',
        NetworkFailureCategory.timeout => 'timeout',
        NetworkFailureCategory.httpApiResponse => 'http_api_response',
        NetworkFailureCategory.authException => 'auth_exception',
        NetworkFailureCategory.missingConfiguration => 'missing_configuration',
        NetworkFailureCategory.unexpected => 'unexpected',
      };
}
