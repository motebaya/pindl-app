import 'package:equatable/equatable.dart';

/// Video URL information
class VideoUrl extends Equatable {
  final String url;
  final String? thumbnail;
  final String quality;
  final int? width;
  final int? height;

  const VideoUrl({
    required this.url,
    this.thumbnail,
    this.quality = '720P',
    this.width,
    this.height,
  });

  factory VideoUrl.fromJson(Map<String, dynamic> json, String quality) {
    return VideoUrl(
      url: json['url'] as String? ?? '',
      thumbnail: json['thumbnail'] as String?,
      quality: quality,
      width: json['width'] as int?,
      height: json['height'] as int?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'url': url,
      'thumbnail': thumbnail,
      'quality': quality,
      'width': width,
      'height': height,
    };
  }

  @override
  List<Object?> get props => [url, thumbnail, quality, width, height];
}
