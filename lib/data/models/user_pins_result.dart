import 'package:equatable/equatable.dart';
import 'author.dart';
import 'pin_item.dart';

/// Result of fetching user pins
/// Includes resume statistics for continue functionality
class UserPinsResult extends Equatable {
  final Author author;
  final List<PinItem> pins;
  final int totalImages;
  final int totalVideos;
  final String? bookmark;
  final bool hasMore;
  
  // Resume statistics (for continue mode)
  final int successDownloaded;
  final int skipDownloaded;
  final int failedDownloaded;
  final int lastIndexDownloaded;
  final bool wasInterrupted;

  const UserPinsResult({
    required this.author,
    required this.pins,
    this.totalImages = 0,
    this.totalVideos = 0,
    this.bookmark,
    this.hasMore = false,
    this.successDownloaded = 0,
    this.skipDownloaded = 0,
    this.failedDownloaded = 0,
    this.lastIndexDownloaded = -1,
    this.wasInterrupted = false,
  });

  /// Create result from API response
  /// Counting follows Node.js logic:
  /// - totalImages = count of pins with images.orig.url
  /// - totalVideos = count of pins with videos.video_list (V_720P)
  /// Note: A pin can have both image AND video
  factory UserPinsResult.fromApiResponse({
    required Author author,
    required List<PinItem> pins,
    String? bookmark,
  }) {
    int images = 0;
    int videos = 0;

    for (final pin in pins) {
      if (pin.hasImage) {
        images++;
      }
      if (pin.hasVideo) {
        videos++;
      }
    }

    return UserPinsResult(
      author: author,
      pins: pins,
      totalImages: images,
      totalVideos: videos,
      bookmark: bookmark,
      hasMore: bookmark != null && bookmark.isNotEmpty,
    );
  }

  /// Create from saved metadata JSON (for resume/continue functionality)
  factory UserPinsResult.fromMetadataJson(Map<String, dynamic> json) {
    final authorJson = json['author'] as Map<String, dynamic>?;
    final pinsJson = json['pins'] as List<dynamic>?;
    
    return UserPinsResult(
      author: authorJson != null 
          ? Author.fromJson(authorJson)
          : const Author(username: '-', name: '-', userId: '-'),
      pins: pinsJson != null
          ? pinsJson.map((p) => PinItem.fromJson(p as Map<String, dynamic>)).toList()
          : [],
      totalImages: json['totalImages'] as int? ?? 0,
      totalVideos: json['totalVideos'] as int? ?? 0,
      bookmark: json['bookmark'] as String?,
      hasMore: json['hasMore'] as bool? ?? false,
      successDownloaded: json['success_downloaded'] as int? ?? 0,
      skipDownloaded: json['skip_downloaded'] as int? ?? 0,
      failedDownloaded: json['failed_downloaded'] as int? ?? 0,
      lastIndexDownloaded: json['last_index_downloaded'] as int? ?? -1,
      wasInterrupted: json['was_interrupted'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'author': author.toJson(),
      'pins': pins.map((p) => p.toJson()).toList(),
      'totalImages': totalImages,
      'totalVideos': totalVideos,
      'bookmark': bookmark,
      'hasMore': hasMore,
    };
  }

  /// Convert to metadata JSON for saving (includes resume stats)
  Map<String, dynamic> toMetadataJson({
    int? successDownloaded,
    int? skipDownloaded,
    int? failedDownloaded,
    int? lastIndexDownloaded,
    bool? wasInterrupted,
  }) {
    return {
      'author': author.toJson(),
      'pins': pins.map((p) => p.toJson()).toList(),
      'totalImages': totalImages,
      'totalVideos': totalVideos,
      'bookmark': bookmark,
      'hasMore': hasMore,
      'success_downloaded': successDownloaded ?? this.successDownloaded,
      'skip_downloaded': skipDownloaded ?? this.skipDownloaded,
      'failed_downloaded': failedDownloaded ?? this.failedDownloaded,
      'last_index_downloaded': lastIndexDownloaded ?? this.lastIndexDownloaded,
      'was_interrupted': wasInterrupted ?? this.wasInterrupted,
    };
  }

  factory UserPinsResult.fromJson(Map<String, dynamic> json) {
    return UserPinsResult(
      author: Author.fromJson(json['author'] as Map<String, dynamic>),
      pins: (json['pins'] as List<dynamic>)
          .map((p) => PinItem.fromJson(p as Map<String, dynamic>))
          .toList(),
      totalImages: json['totalImages'] as int? ?? 0,
      totalVideos: json['totalVideos'] as int? ?? 0,
      bookmark: json['bookmark'] as String?,
      hasMore: json['hasMore'] as bool? ?? false,
      successDownloaded: json['success_downloaded'] as int? ?? 0,
      skipDownloaded: json['skip_downloaded'] as int? ?? 0,
      failedDownloaded: json['failed_downloaded'] as int? ?? 0,
      lastIndexDownloaded: json['last_index_downloaded'] as int? ?? -1,
      wasInterrupted: json['was_interrupted'] as bool? ?? false,
    );
  }

  UserPinsResult copyWith({
    Author? author,
    List<PinItem>? pins,
    int? totalImages,
    int? totalVideos,
    String? bookmark,
    bool? hasMore,
    int? successDownloaded,
    int? skipDownloaded,
    int? failedDownloaded,
    int? lastIndexDownloaded,
    bool? wasInterrupted,
  }) {
    return UserPinsResult(
      author: author ?? this.author,
      pins: pins ?? this.pins,
      totalImages: totalImages ?? this.totalImages,
      totalVideos: totalVideos ?? this.totalVideos,
      bookmark: bookmark ?? this.bookmark,
      hasMore: hasMore ?? this.hasMore,
      successDownloaded: successDownloaded ?? this.successDownloaded,
      skipDownloaded: skipDownloaded ?? this.skipDownloaded,
      failedDownloaded: failedDownloaded ?? this.failedDownloaded,
      lastIndexDownloaded: lastIndexDownloaded ?? this.lastIndexDownloaded,
      wasInterrupted: wasInterrupted ?? this.wasInterrupted,
    );
  }

  /// Merge with additional results (for pagination)
  UserPinsResult merge(UserPinsResult other) {
    final allPins = [...pins, ...other.pins];
    int images = 0;
    int videos = 0;

    for (final pin in allPins) {
      if (pin.hasImage) {
        images++;
      }
      if (pin.hasVideo) {
        videos++;
      }
    }

    return UserPinsResult(
      author: author,
      pins: allPins,
      totalImages: images,
      totalVideos: videos,
      bookmark: other.bookmark,
      hasMore: other.hasMore,
    );
  }

  /// Calculate remaining items for continue mode
  int get remainingImages {
    if (lastIndexDownloaded < 0) return totalImages;
    return totalImages - (lastIndexDownloaded + 1);
  }

  int get remainingVideos {
    if (lastIndexDownloaded < 0) return totalVideos;
    return totalVideos - (lastIndexDownloaded + 1);
  }

  @override
  List<Object?> get props => [
    author, pins, totalImages, totalVideos, bookmark, hasMore,
    successDownloaded, skipDownloaded, failedDownloaded, lastIndexDownloaded, wasInterrupted,
  ];
}
