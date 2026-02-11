import 'package:dio/dio.dart';

/// HLS playlist parsing service
/// Ported from Node.js HLS.js
/// 
/// Responsibilities:
/// - Fetch and parse HLS master playlists (.m3u8)
/// - Select best video variant (highest resolution/bandwidth)
/// - Select best audio track
class HlsService {
  final Dio _dio;
  
  HlsService({Dio? dio}) : _dio = dio ?? Dio();
  
  /// Fetch and parse an HLS master playlist
  /// Returns the best video variant URL and optional audio URL
  Future<HlsParseResult> fetchAndParse(String masterPlaylistUrl) async {
    try {
      // Fetch the master playlist as text
      final response = await _dio.get<String>(
        masterPlaylistUrl,
        options: Options(responseType: ResponseType.plain),
      );
      
      final playlistContent = response.data;
      if (playlistContent == null || playlistContent.isEmpty) {
        return HlsParseResult.error('Empty playlist content');
      }
      
      // Parse the playlist
      final parsed = _parseM3u8(playlistContent);
      
      if (parsed.variants.isEmpty) {
        return HlsParseResult.error('No variants found in master playlist');
      }
      
      // Get best variant (highest resolution, fallback to highest bandwidth)
      final bestVariant = _selectBestVariant(parsed.variants);
      
      // Build absolute URL for the variant
      final baseUrl = _getBaseUrl(masterPlaylistUrl);
      final variantUrl = _buildAbsoluteUrl(baseUrl, bestVariant.uri);
      
      // Get best audio if available
      String? audioUrl;
      if (parsed.audioTracks.isNotEmpty) {
        final bestAudio = _selectBestAudio(parsed.audioTracks, bestVariant.audioGroupId);
        if (bestAudio != null && bestAudio.uri != null) {
          audioUrl = _buildAbsoluteUrl(baseUrl, bestAudio.uri!);
        }
      }
      
      return HlsParseResult.success(
        videoVariantUrl: variantUrl,
        audioUrl: audioUrl,
        width: bestVariant.width,
        height: bestVariant.height,
        bandwidth: bestVariant.bandwidth,
      );
    } on DioException catch (e) {
      return HlsParseResult.error('Failed to fetch playlist: ${e.message}');
    } catch (e) {
      return HlsParseResult.error('Failed to parse playlist: $e');
    }
  }
  
  /// Parse M3U8 playlist content
  _ParsedPlaylist _parseM3u8(String content) {
    final lines = content.split('\n').map((l) => l.trim()).toList();
    final variants = <_HlsVariant>[];
    final audioTracks = <_HlsAudioTrack>[];
    
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      
      // Parse #EXT-X-STREAM-INF (video variants)
      if (line.startsWith('#EXT-X-STREAM-INF:')) {
        final attributes = _parseAttributes(line.substring('#EXT-X-STREAM-INF:'.length));
        
        // Get next non-empty line as URI
        String? uri;
        for (var j = i + 1; j < lines.length; j++) {
          if (lines[j].isNotEmpty && !lines[j].startsWith('#')) {
            uri = lines[j];
            break;
          }
        }
        
        if (uri != null) {
          final resolution = attributes['RESOLUTION'];
          int? width, height;
          if (resolution != null && resolution.contains('x')) {
            final parts = resolution.split('x');
            width = int.tryParse(parts[0]);
            height = int.tryParse(parts[1]);
          }
          
          variants.add(_HlsVariant(
            uri: uri,
            bandwidth: int.tryParse(attributes['BANDWIDTH'] ?? '') ?? 0,
            width: width,
            height: height,
            audioGroupId: attributes['AUDIO'],
          ));
        }
      }
      
      // Parse #EXT-X-MEDIA (audio tracks)
      if (line.startsWith('#EXT-X-MEDIA:')) {
        final attributes = _parseAttributes(line.substring('#EXT-X-MEDIA:'.length));
        
        if (attributes['TYPE'] == 'AUDIO') {
          audioTracks.add(_HlsAudioTrack(
            groupId: attributes['GROUP-ID']?.replaceAll('"', ''),
            name: attributes['NAME']?.replaceAll('"', ''),
            uri: attributes['URI']?.replaceAll('"', ''),
            language: attributes['LANGUAGE']?.replaceAll('"', ''),
            isDefault: attributes['DEFAULT'] == 'YES',
          ));
        }
      }
    }
    
    return _ParsedPlaylist(variants: variants, audioTracks: audioTracks);
  }
  
  /// Parse key=value attributes from M3U8 line
  Map<String, String> _parseAttributes(String attributeString) {
    final result = <String, String>{};
    final regex = RegExp(r'([A-Z\-]+)=("[^"]*"|[^,]*)');
    
    for (final match in regex.allMatches(attributeString)) {
      final key = match.group(1)!;
      var value = match.group(2)!;
      // Remove quotes if present
      if (value.startsWith('"') && value.endsWith('"')) {
        value = value.substring(1, value.length - 1);
      }
      result[key] = value;
    }
    
    return result;
  }
  
  /// Select best variant (highest resolution, fallback to highest bandwidth)
  /// Matches Node.js HLS.js getBestVariant logic
  _HlsVariant _selectBestVariant(List<_HlsVariant> variants) {
    final sorted = List<_HlsVariant>.from(variants);
    sorted.sort((a, b) {
      // First compare by resolution (width * height)
      final aPixels = (a.width ?? 0) * (a.height ?? 0);
      final bPixels = (b.width ?? 0) * (b.height ?? 0);
      if (bPixels != aPixels) {
        return bPixels - aPixels;  // Descending
      }
      // Fallback to bandwidth
      return b.bandwidth - a.bandwidth;  // Descending
    });
    
    return sorted.first;
  }
  
  /// Select best audio track matching the audio group ID
  /// Matches Node.js HLS.js getBestAudio logic
  _HlsAudioTrack? _selectBestAudio(List<_HlsAudioTrack> audioTracks, String? audioGroupId) {
    if (audioTracks.isEmpty) return null;
    
    // Try to find matching group ID
    if (audioGroupId != null) {
      final matching = audioTracks.where((t) => t.groupId == audioGroupId).toList();
      if (matching.isNotEmpty) {
        // Prefer default track, else first
        return matching.firstWhere((t) => t.isDefault, orElse: () => matching.first);
      }
    }
    
    // Fallback to first audio track
    return audioTracks.first;
  }
  
  /// Get base URL (directory) from a URL
  String _getBaseUrl(String url) {
    final uri = Uri.parse(url);
    final segments = uri.pathSegments.toList();
    if (segments.isNotEmpty) {
      segments.removeLast();  // Remove filename
    }
    return uri.replace(pathSegments: segments).toString();
  }
  
  /// Build absolute URL from base and relative URI
  String _buildAbsoluteUrl(String baseUrl, String relativeUri) {
    if (relativeUri.startsWith('http://') || relativeUri.startsWith('https://')) {
      return relativeUri;  // Already absolute
    }
    
    // Handle relative paths
    if (baseUrl.endsWith('/')) {
      return '$baseUrl$relativeUri';
    }
    return '$baseUrl/$relativeUri';
  }
}

/// Internal class for parsed playlist
class _ParsedPlaylist {
  final List<_HlsVariant> variants;
  final List<_HlsAudioTrack> audioTracks;
  
  _ParsedPlaylist({required this.variants, required this.audioTracks});
}

/// Internal class for HLS variant
class _HlsVariant {
  final String uri;
  final int bandwidth;
  final int? width;
  final int? height;
  final String? audioGroupId;
  
  _HlsVariant({
    required this.uri,
    required this.bandwidth,
    this.width,
    this.height,
    this.audioGroupId,
  });
}

/// Internal class for HLS audio track
class _HlsAudioTrack {
  final String? groupId;
  final String? name;
  final String? uri;
  final String? language;
  final bool isDefault;
  
  _HlsAudioTrack({
    this.groupId,
    this.name,
    this.uri,
    this.language,
    this.isDefault = false,
  });
}

/// Result of HLS parsing
class HlsParseResult {
  final bool success;
  final String? videoVariantUrl;
  final String? audioUrl;
  final int? width;
  final int? height;
  final int? bandwidth;
  final String? errorMessage;
  
  HlsParseResult._({
    required this.success,
    this.videoVariantUrl,
    this.audioUrl,
    this.width,
    this.height,
    this.bandwidth,
    this.errorMessage,
  });
  
  factory HlsParseResult.success({
    required String videoVariantUrl,
    String? audioUrl,
    int? width,
    int? height,
    int? bandwidth,
  }) {
    return HlsParseResult._(
      success: true,
      videoVariantUrl: videoVariantUrl,
      audioUrl: audioUrl,
      width: width,
      height: height,
      bandwidth: bandwidth,
    );
  }
  
  factory HlsParseResult.error(String message) {
    return HlsParseResult._(
      success: false,
      errorMessage: message,
    );
  }
  
  @override
  String toString() {
    if (success) {
      return 'HlsParseResult(variant: $videoVariantUrl, audio: $audioUrl, ${width}x$height @ ${bandwidth}bps)';
    }
    return 'HlsParseResult(error: $errorMessage)';
  }
}
