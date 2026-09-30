import 'package:equatable/equatable.dart';
import 'author.dart';

/// One carousel slot image (Phase 07, workstream 07.3). Order = slot order
/// (JS-verified field order matches display order).
class MediaSlot extends Equatable {
  final String imageUrl;
  final int? width;
  final int? height;

  const MediaSlot({required this.imageUrl, this.width, this.height});

  Map<String, dynamic> toJson() => {
        'imageUrl': imageUrl,
        if (width != null) 'width': width,
        if (height != null) 'height': height,
      };

  factory MediaSlot.fromJson(Map<String, dynamic> json) => MediaSlot(
        imageUrl: json['imageUrl'] as String? ?? '',
        width: json['width'] as int?,
        height: json['height'] as int?,
      );

  @override
  List<Object?> get props => [imageUrl, width, height];
}

/// Result of extracting media from a single pin
/// Updated to match new parsing output format
class MediaResult extends Equatable {
  final Author author;
  final String title;
  final String pinId;
  final String? entityId; // Added: entityId from response for metadata filename
  final String? imageUrl;
  final String? videoUrl;
  final String? thumbnail;
  final bool isVideo;
  final bool hasImage;
  final bool hasVideoContent;
  final String? message;
  final Map<String, dynamic>? rawJson; // Store raw JSON for metadata export

  /// Carousel slots in display order (Phase 07). Empty for non-carousel pins;
  /// single-slot carousels behave identically to a plain image pin.
  final List<MediaSlot> slots;

  const MediaResult({
    required this.author,
    required this.title,
    required this.pinId,
    this.entityId,
    this.imageUrl,
    this.videoUrl,
    this.thumbnail,
    this.isVideo = false,
    this.hasImage = false,
    this.hasVideoContent = false,
    this.message,
    this.rawJson,
    this.slots = const [],
  });

  // Phase 12.3 (CQ-3): downloadUrl/previewUrl/hasBothMedia getters removed —
  // zero callers (callers compose from imageUrl/videoUrl/thumbnail directly).

  /// Get download URL for image (or thumbnail if video-only)
  String? getImageDownloadUrl({bool useThumbnailForVideo = false}) {
    if (hasImage) return imageUrl;
    if (useThumbnailForVideo && hasVideoContent && thumbnail != null) {
      return thumbnail;
    }
    return null;
  }

  /// Get download URL for video
  String? get videoDownloadUrl => hasVideoContent ? videoUrl : null;
  
  /// Get the effective ID for metadata filename (entityId or pinId)
  String get metadataId => entityId ?? pinId;

  Map<String, dynamic> toJson() {
    return {
      'author': author.toJson(),
      'title': title,
      'pinId': pinId,
      'entityId': entityId,
      'imageUrl': imageUrl,
      'videoUrl': videoUrl,
      'thumbnail': thumbnail,
      'isVideo': isVideo,
      'hasImage': hasImage,
      'hasVideoContent': hasVideoContent,
      'message': message,
    };
  }

  factory MediaResult.fromJson(Map<String, dynamic> json) {
    return MediaResult(
      author: Author.fromJson(json['author'] as Map<String, dynamic>),
      title: json['title'] as String? ?? '',
      pinId: json['pinId'] as String? ?? '',
      entityId: json['entityId'] as String?,
      imageUrl: json['imageUrl'] as String?,
      videoUrl: json['videoUrl'] as String?,
      thumbnail: json['thumbnail'] as String?,
      isVideo: json['isVideo'] as bool? ?? false,
      hasImage: json['hasImage'] as bool? ?? false,
      hasVideoContent: json['hasVideoContent'] as bool? ?? false,
      message: json['message'] as String?,
      slots: (json['slots'] as List<dynamic>?)
              ?.whereType<Map<String, dynamic>>()
              .map(MediaSlot.fromJson)
              .toList() ??
          const [],
    );
  }

  MediaResult copyWith({
    Author? author,
    String? title,
    String? pinId,
    String? entityId,
    String? imageUrl,
    String? videoUrl,
    String? thumbnail,
    bool? isVideo,
    bool? hasImage,
    bool? hasVideoContent,
    String? message,
    Map<String, dynamic>? rawJson,
    List<MediaSlot>? slots,
  }) {
    return MediaResult(
      author: author ?? this.author,
      title: title ?? this.title,
      pinId: pinId ?? this.pinId,
      entityId: entityId ?? this.entityId,
      imageUrl: imageUrl ?? this.imageUrl,
      videoUrl: videoUrl ?? this.videoUrl,
      thumbnail: thumbnail ?? this.thumbnail,
      isVideo: isVideo ?? this.isVideo,
      hasImage: hasImage ?? this.hasImage,
      hasVideoContent: hasVideoContent ?? this.hasVideoContent,
      message: message ?? this.message,
      rawJson: rawJson ?? this.rawJson,
      slots: slots ?? this.slots,
    );
  }

  @override
  List<Object?> get props => [
        author,
        title,
        pinId,
        entityId,
        imageUrl,
        videoUrl,
        thumbnail,
        isVideo,
        hasImage,
        hasVideoContent,
        message,
        slots,
      ];
}
