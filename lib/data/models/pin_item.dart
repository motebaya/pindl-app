import 'package:equatable/equatable.dart';
import 'video_url.dart';

/// Represents a single Pinterest pin item
class PinItem extends Equatable {
  final String pinId;
  final String title;
  final String? imageUrl;
  final VideoUrl? videoUrl;
  final String? thumbnail;
  final DateTime? uploadDate;
  final bool hasImage;
  final bool hasVideo;

  const PinItem({
    required this.pinId,
    required this.title,
    this.imageUrl,
    this.videoUrl,
    this.thumbnail,
    this.uploadDate,
    this.hasImage = false,
    this.hasVideo = false,
  });

  /// Create from Pinterest API response for user pins
  /// Matches Node.js output structure:
  /// {
  ///   "title": "...",
  ///   "images": { "170x": {...}, "orig": { "url": "..." } },
  ///   "videos": { "video_list": { "V_720P": { "url": "...", "thumbnail": "..." } } } or [],
  ///   "pinId": "...",
  ///   "uploadDate": "..."
  /// }
  /// 
  /// HLS Fallback Logic (matching Node.js Pinterest.js:206-238):
  /// - If videos is null, try story_pin_data.pages[0].blocks[0].video.video_list
  /// - Prefer direct MP4 (V_720P with .mp4 URL)
  /// - Fallback to HLS (V_HLSV3_MOBILE or V_HLSV4) with needConvert=true
  factory PinItem.fromUserPinJson(Map<String, dynamic> json) {
    String? imageUrl;
    VideoUrl? videoUrl;
    String? thumbnail;
    bool hasImage = false;
    bool hasVideo = false;

    // Extract image URL from images.orig.url
    final images = json['images'];
    if (images is Map<String, dynamic> && images.isNotEmpty) {
      final orig = images['orig'] as Map<String, dynamic>?;
      imageUrl = orig?['url'] as String?;
      hasImage = imageUrl != null && imageUrl.isNotEmpty;
    }

    // Extract video URL from videos.video_list
    // Implements Node.js logic for HLS fallback
    Map<String, dynamic>? videoList;
    
    final videos = json['videos'];
    if (videos is Map<String, dynamic> && videos.isNotEmpty) {
      videoList = videos['video_list'] as Map<String, dynamic>?;
    } else if (videos == null) {
      // Node.js: If d.videos === null, try story_pin_data fallback
      videoList = _extractVideoListFromStoryPinData(json);
    }
    // If videos is a List (empty array []), hasVideo remains false
    
    if (videoList != null && videoList.isNotEmpty) {
      // Try to get direct MP4 first (V_720P with .mp4 extension)
      final v720p = videoList['V_720P'] as Map<String, dynamic>?;
      final v720pUrl = v720p?['url'] as String?;
      
      if (v720p != null && v720pUrl != null && v720pUrl.endsWith('.mp4')) {
        // Direct MP4 available - use it without conversion
        videoUrl = VideoUrl.fromJson(v720p, '720P', needConvert: false);
        thumbnail = v720p['thumbnail'] as String?;
        hasVideo = true;
      } else {
        // No direct MP4 - check for HLS variants (V_HLSV3_MOBILE or V_HLSV4)
        // Node.js: let hls = loc?.V_HLSV3_MOBILE ?? loc?.V_HLSV4;
        final hlsVariant = videoList['V_HLSV3_MOBILE'] as Map<String, dynamic>? ??
                           videoList['V_HLSV4'] as Map<String, dynamic>?;
        
        if (hlsVariant != null && hlsVariant['url'] != null) {
          // HLS available - mark as needing conversion
          videoUrl = VideoUrl.fromJson(hlsVariant, 'HLS', needConvert: true);
          thumbnail = hlsVariant['thumbnail'] as String?;
          hasVideo = true;
        } else if (v720p != null && v720pUrl != null) {
          // V_720P exists but might be HLS (not .mp4)
          final isHls = v720pUrl.endsWith('.m3u8');
          videoUrl = VideoUrl.fromJson(v720p, '720P', needConvert: isHls);
          thumbnail = v720p['thumbnail'] as String?;
          hasVideo = true;
        } else {
          // Try any other available quality
          for (final entry in videoList.entries) {
            if (entry.value is Map<String, dynamic>) {
              final vData = entry.value as Map<String, dynamic>;
              final vUrl = vData['url'] as String?;
              if (vUrl != null) {
                final isHls = vUrl.endsWith('.m3u8');
                videoUrl = VideoUrl.fromJson(vData, entry.key, needConvert: isHls);
                thumbnail = vData['thumbnail'] as String?;
                hasVideo = true;
                break;
              }
            }
          }
        }
      }
    }

    // Parse upload date
    DateTime? uploadDate;
    final createdAt = json['created_at'] as String?;
    if (createdAt != null) {
      try {
        // Try parsing RFC 2822 format: "Thu, 11 Dec 2025 04:04:36 +0000"
        uploadDate = _parseRfc2822Date(createdAt);
      } catch (_) {
        try {
          // Fallback to ISO 8601
          uploadDate = DateTime.parse(createdAt);
        } catch (_) {}
      }
    }

    return PinItem(
      pinId: json['id']?.toString() ?? json['pinId']?.toString() ?? '',
      title: json['title'] as String? ?? '',
      imageUrl: imageUrl,
      videoUrl: videoUrl,
      thumbnail: thumbnail,
      uploadDate: uploadDate,
      hasImage: hasImage,
      hasVideo: hasVideo,
    );
  }
  
  /// Extract video_list from story_pin_data (fallback when videos is null)
  /// Node.js: d.story_pin_data?.pages[0]?.blocks[0]?.video?.video_list
  static Map<String, dynamic>? _extractVideoListFromStoryPinData(Map<String, dynamic> json) {
    try {
      final storyPinData = json['story_pin_data'] as Map<String, dynamic>?;
      if (storyPinData == null) return null;
      
      final pages = storyPinData['pages'] as List<dynamic>?;
      if (pages == null || pages.isEmpty) return null;
      
      final firstPage = pages[0] as Map<String, dynamic>?;
      if (firstPage == null) return null;
      
      final blocks = firstPage['blocks'] as List<dynamic>?;
      if (blocks == null || blocks.isEmpty) return null;
      
      final firstBlock = blocks[0] as Map<String, dynamic>?;
      if (firstBlock == null) return null;
      
      final video = firstBlock['video'] as Map<String, dynamic>?;
      if (video == null) return null;
      
      return video['video_list'] as Map<String, dynamic>?;
    } catch (_) {
      return null;
    }
  }
  
  /// Parse RFC 2822 date format: "Thu, 11 Dec 2025 04:04:36 +0000"
  static DateTime? _parseRfc2822Date(String dateStr) {
    try {
      // Simple RFC 2822 parser
      final months = {
        'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6,
        'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12,
      };
      
      // Remove day name if present
      final parts = dateStr.split(', ');
      final mainPart = parts.length > 1 ? parts[1] : parts[0];
      
      // Parse: "11 Dec 2025 04:04:36 +0000"
      final regex = RegExp(r'(\d+)\s+(\w+)\s+(\d+)\s+(\d+):(\d+):(\d+)');
      final match = regex.firstMatch(mainPart);
      if (match == null) return null;
      
      final day = int.parse(match.group(1)!);
      final month = months[match.group(2)!] ?? 1;
      final year = int.parse(match.group(3)!);
      final hour = int.parse(match.group(4)!);
      final minute = int.parse(match.group(5)!);
      final second = int.parse(match.group(6)!);
      
      return DateTime.utc(year, month, day, hour, minute, second);
    } catch (_) {
      return null;
    }
  }

  /// Get the download URL based on media type preference
  String? getDownloadUrl({required bool preferVideo}) {
    if (preferVideo && hasVideo) {
      return videoUrl?.url;
    }
    return imageUrl;
  }

  /// Get thumbnail URL (video thumbnail or image URL)
  String? get thumbnailUrl => thumbnail ?? imageUrl;

  /// Check if this pin matches the media type filter
  bool matchesMediaType({required bool isImage, required bool isVideo}) {
    if (isImage && hasImage && !hasVideo) return true;
    if (isVideo && hasVideo) return true;
    if (isImage && hasImage) return true; // Images including video thumbnails
    return false;
  }

  Map<String, dynamic> toJson() {
    return {
      'pinId': pinId,
      'title': title,
      'imageUrl': imageUrl,
      'videoUrl': videoUrl?.toJson(),
      'thumbnail': thumbnail,
      'uploadDate': uploadDate?.toIso8601String(),
      'hasImage': hasImage,
      'hasVideo': hasVideo,
    };
  }

  factory PinItem.fromJson(Map<String, dynamic> json) {
    VideoUrl? videoUrl;
    if (json['videoUrl'] != null) {
      final vJson = json['videoUrl'] as Map<String, dynamic>;
      final needConvert = vJson['needConvert'] as bool? ?? false;
      videoUrl = VideoUrl.fromJson(vJson, vJson['quality'] as String? ?? '720P', needConvert: needConvert);
    }
    
    return PinItem(
      pinId: json['pinId'] as String? ?? '',
      title: json['title'] as String? ?? '',
      imageUrl: json['imageUrl'] as String?,
      videoUrl: videoUrl,
      thumbnail: json['thumbnail'] as String?,
      uploadDate: json['uploadDate'] != null
          ? DateTime.tryParse(json['uploadDate'] as String)
          : null,
      hasImage: json['hasImage'] as bool? ?? false,
      hasVideo: json['hasVideo'] as bool? ?? false,
    );
  }

  PinItem copyWith({
    String? pinId,
    String? title,
    String? imageUrl,
    VideoUrl? videoUrl,
    String? thumbnail,
    DateTime? uploadDate,
    bool? hasImage,
    bool? hasVideo,
  }) {
    return PinItem(
      pinId: pinId ?? this.pinId,
      title: title ?? this.title,
      imageUrl: imageUrl ?? this.imageUrl,
      videoUrl: videoUrl ?? this.videoUrl,
      thumbnail: thumbnail ?? this.thumbnail,
      uploadDate: uploadDate ?? this.uploadDate,
      hasImage: hasImage ?? this.hasImage,
      hasVideo: hasVideo ?? this.hasVideo,
    );
  }

  @override
  List<Object?> get props => [pinId, title, imageUrl, videoUrl, thumbnail, uploadDate, hasImage, hasVideo];

  @override
  String toString() => 'PinItem($pinId, "$title", image: $hasImage, video: $hasVideo)';
}
