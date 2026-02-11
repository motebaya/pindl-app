import 'package:equatable/equatable.dart';

/// Video URL information
class VideoUrl extends Equatable {
  final String url;
  final String? thumbnail;
  final String quality;
  final int? width;
  final int? height;
  final bool needConvert; // true for HLS (.m3u8) that requires ffmpeg conversion

  const VideoUrl({
    required this.url,
    this.thumbnail,
    this.quality = '720P',
    this.width,
    this.height,
    this.needConvert = false,
  });

  /// Check if this video requires HLS conversion
  bool get isHls => needConvert || url.endsWith('.m3u8');

  factory VideoUrl.fromJson(Map<String, dynamic> json, String quality, {bool needConvert = false}) {
    return VideoUrl(
      url: json['url'] as String? ?? '',
      thumbnail: json['thumbnail'] as String?,
      quality: quality,
      width: json['width'] as int?,
      height: json['height'] as int?,
      needConvert: needConvert,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'url': url,
      'thumbnail': thumbnail,
      'quality': quality,
      'width': width,
      'height': height,
      'needConvert': needConvert,
    };
  }

  @override
  List<Object?> get props => [url, thumbnail, quality, width, height, needConvert];
}
