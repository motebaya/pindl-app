import '../../core/exceptions/pinterest_exception.dart';
import '../../core/network/media_hosts.dart';

/// UI mapping layer (plan ui-ux/02): human copy per typed exception.
///
/// Full diagnostics belong to the console/LogService only — user-facing
/// surfaces (state.error, history rows) must use [userMessage]. The
/// mapping test asserts no raw exception internals leak through.
String userMessage(Object error) {
  if (error is PinNotFoundException) {
    return "This pin was deleted or doesn't exist";
  }
  if (error is NoMediaException) {
    return 'No downloadable media found';
  }
  if (error is SourceChangedException) {
    return "Pinterest's page structure changed — try updating the app";
  }
  if (error is CancelledException) {
    return 'Cancelled'; // UI may suppress entirely; history keeps one word
  }
  if (error is NetworkException) {
    return _networkMessage(error.statusCode);
  }
  if (error is DownloadException) {
    return _downloadMessage(error);
  }
  if (error is ParseException) {
    return 'Could not read this pin — see console for details';
  }
  if (error is ValidationException) {
    return 'Invalid input — check the URL or username';
  }
  if (error is ExtractionException) {
    return 'Could not extract this content — see console for details';
  }
  return 'Something went wrong — see console for details';
}

String _networkMessage(int? statusCode) {
  switch (statusCode) {
    case 404:
      return 'Not found on Pinterest (404)';
    case 403:
      return 'Access denied by Pinterest (403)';
    case 429:
      return 'Pinterest is rate-limiting requests — try again shortly (429)';
    default:
      if (statusCode != null && statusCode >= 500) {
        return 'Pinterest server error — try again ($statusCode)';
      }
      return 'Network problem — check your connection';
  }
}

String _downloadMessage(DownloadException e) {
  final m = e.message;
  if (m.contains('already exists')) return 'File already exists';
  if (m.startsWith('validation failed:')) {
    final reason = m.substring('validation failed:'.length).trim();
    switch (reason) {
      case 'downloaded content is a document, not media':
        return 'Downloaded content was a web page, not media';
      case 'undersized content':
        return 'Downloaded file was incomplete (too small)';
      default:
        return 'Downloaded content failed validation — see console';
    }
  }
  if (m.contains(MediaHosts.rejectionReason)) {
    return 'Blocked download from an unexpected host';
  }
  return 'Download failed — see console for details';
}
