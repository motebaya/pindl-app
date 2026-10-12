import 'package:equatable/equatable.dart';
import '../../core/media/carousel_slots.dart';
import '../../core/media/video_selection.dart';
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

  /// Carousel slide image URLs in display order (Feed/Board carousel
  /// migration). Empty for a plain pin AND for a one-slide carousel — callers
  /// must treat `length <= 1` as "single item" so non-carousel behavior stays
  /// byte-identical. Sourced from the feed/board row's `carousel_data` block
  /// via [carouselSlotUrlsFromRow] (live-verified shape; see that module).
  final List<String> imageSlots;

  const PinItem({
    required this.pinId,
    required this.title,
    this.imageUrl,
    this.videoUrl,
    this.thumbnail,
    this.uploadDate,
    this.hasImage = false,
    this.hasVideo = false,
    this.imageSlots = const [],
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
      // Phase 07 (07.2): rendition ranking delegated to the pure selector —
      // JS MP4_PREFERENCE order (720P→960P→480P→360P, then any MP4) with
      // V_HLSV4 over V_HLSV3_MOBILE. Deliberate behavior change vs the legacy
      // inline chain (720P-first / HLSV3-first); release-noted in 07.6.
      final selected = selectVideo(videoList);
      if (selected != null) {
        videoUrl = selected;
        thumbnail = selected.thumbnail;
        hasVideo = true;
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
      // Phase 10.6 device-evidence fix: board rows may carry `title` as a
      // Map (rich-pin payloads) — a hard cast crashed the whole board job
      // (raw error: `_Map<String, dynamic>' is not a subtype of 'String?'`;
      // stack: fromUserPinJson → BoardController._fetchPinFeed). Tolerant
      // read: String passes through, anything else (null/Map) → ''. Same
      // user-pins feed benefits when rows surface rich metadata.
      title: json['title'] is String ? json['title'] as String : '',
      imageUrl: imageUrl,
      videoUrl: videoUrl,
      thumbnail: thumbnail,
      uploadDate: uploadDate,
      hasImage: hasImage,
      hasVideo: hasVideo,
      // Feed/Board carousel migration: the row carries every slide (live
      // evidence in `core/media/carousel_slots.dart`); absent/one-slot rows
      // stay a single item.
      imageSlots: carouselSlotUrlsFromRow(json),
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
      // v2-additive: older readers ignore the key; a resumed job whose pins
      // were persisted by 3.1.0/3.1.1 simply has no slots (see the resume
      // migration in `core/persistence/feed_plan_migration.dart`).
      if (imageSlots.isNotEmpty) 'imageSlots': imageSlots,
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
      imageSlots: (json['imageSlots'] as List<dynamic>?)
              ?.whereType<String>()
              .where((u) => u.isNotEmpty)
              .toList() ??
          const [],
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
    List<String>? imageSlots,
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
      imageSlots: imageSlots ?? this.imageSlots,
    );
  }

  @override
  List<Object?> get props => [pinId, title, imageUrl, videoUrl, thumbnail, uploadDate, hasImage, hasVideo, imageSlots];

  @override
  String toString() => 'PinItem($pinId, "$title", image: $hasImage, video: $hasVideo, '
      'slots: ${imageSlots.length})';
}
