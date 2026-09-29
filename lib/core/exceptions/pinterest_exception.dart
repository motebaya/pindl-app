/// Base exception for Pinterest-related errors
class PinterestException implements Exception {
  final String message;
  final String? code;
  final dynamic originalError;

  PinterestException(this.message, {this.code, this.originalError});

  @override
  String toString() => 'PinterestException: $message${code != null ? ' (code: $code)' : ''}';
}

/// Exception when extraction fails
class ExtractionException extends PinterestException {
  ExtractionException(super.message, {super.code, super.originalError});
}

/// Exception when parsing fails
class ParseException extends PinterestException {
  ParseException(super.message, {super.code, super.originalError});
}

/// Exception when the requested pin does not exist (deleted / never existed).
/// Extends [ParseException] so existing catch sites keep working (plan 01).
class PinNotFoundException extends ParseException {
  PinNotFoundException(super.message, {super.code, super.originalError});
}

/// Exception when a pin exists but carries no downloadable media.
class NoMediaException extends ParseException {
  NoMediaException(super.message, {super.code, super.originalError});
}

/// Exception when the Pinterest page structure no longer matches the parser
/// (relay payload missing entirely) — the app likely needs an update.
class SourceChangedException extends ParseException {
  SourceChangedException(super.message, {super.code, super.originalError});
}

/// Exception when network request fails
class NetworkException extends PinterestException {
  final int? statusCode;

  NetworkException(super.message, {this.statusCode, super.code, super.originalError});

  @override
  String toString() =>
      'NetworkException: $message${statusCode != null ? ' (status: $statusCode)' : ''}';
}

/// Exception when validation fails
class ValidationException extends PinterestException {
  ValidationException(super.message, {super.code, super.originalError});
}

/// Exception when download fails
class DownloadException extends PinterestException {
  final String? filePath;

  DownloadException(super.message, {this.filePath, super.code, super.originalError});
}

/// Exception when user cancels an operation
class CancelledException extends PinterestException {
  CancelledException([super.message = 'Operation cancelled by user']);
}
