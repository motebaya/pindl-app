// Part of `home_page.dart` (same library via `part`) — Phase 08.6 file
// split: the single-pin media preview widgets.
part of 'home_page.dart';

extension _HomePagePreview on _HomePageState {
  Widget _buildMediaPreview(bool isDark, dynamic singleResult) {
    final settings = ref.watch(settingsProvider);
    final hasVideo = singleResult.hasVideoContent ?? false;
    final thumbnail = singleResult.thumbnail as String?;
    final imageUrl = singleResult.imageUrl as String?;
    final videoUrl = singleResult.videoUrl as String?;
    final slots = (singleResult.slots as List?) ?? const [];
    
    final showImage = settings.downloadImage;
    final showVideo = settings.downloadVideo && hasVideo;
    
    // Carousel pins (3.1.1): a multi-image post previews EVERY slide, not just
    // slide 0 — the old preview showed one image with no hint that 7 more were
    // part of the pin (device report: "only 1 item is ready to download").
    final carousel = showImage && slots.length > 1
        ? _buildCarouselStrip(isDark, slots)
        : null;

    // Determine what preview(s) to show
    if (showImage && showVideo) {
      // Show BOTH thumbnail AND video preview
      return Column(
        children: [
          // Thumbnail/image preview
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: NeumorphismTheme.getAccentColor(isDark).withValues(alpha: 0.5),
                width: 2,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Stack(
                children: [
                  _buildImagePreview(thumbnail ?? imageUrl ?? ''),
                  Positioned(
                    top: 8,
                    left: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.image, color: Colors.white, size: 14),
                          SizedBox(width: 4),
                          Text(
                            'THUMBNAIL',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (carousel != null) ...[
            const SizedBox(height: 8),
            carousel,
          ],
          const SizedBox(height: 12),
          // Video preview
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: NeumorphismTheme.getAccentColor(isDark).withValues(alpha: 0.5),
                width: 2,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: _buildVideoPreview(thumbnail ?? '', videoUrl),
            ),
          ),
        ],
      );
    } else if (showVideo && hasVideo) {
      // Show only video preview
      return Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: NeumorphismTheme.getAccentColor(isDark).withValues(alpha: 0.5),
            width: 2,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: _buildVideoPreview(thumbnail ?? '', videoUrl),
        ),
      );
    } else if (showImage) {
      // Show image/thumbnail preview (for video URLs, this shows the thumbnail)
      final previewUrl = hasVideo ? (thumbnail ?? imageUrl) : imageUrl;
      if (previewUrl == null) return carousel ?? const SizedBox.shrink();
      
      final imageCard = Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: NeumorphismTheme.getAccentColor(isDark).withValues(alpha: 0.5),
            width: 2,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Stack(
            children: [
              _buildImagePreview(previewUrl),
              if (hasVideo)
                Positioned(
                  top: 8,
                  left: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.image, color: Colors.white, size: 14),
                        SizedBox(width: 4),
                        Text(
                          'THUMBNAIL',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      );

      if (carousel == null) return imageCard;
      return Column(
        children: [
          imageCard,
          const SizedBox(height: 8),
          carousel,
        ],
      );
    }
    
    return carousel ?? const SizedBox.shrink();
  }

  /// Horizontal strip of every carousel slide (3.1.1) — index badge + image,
  /// so a multi-image post is visibly multi-image before the download.
  Widget _buildCarouselStrip(bool isDark, List<dynamic> slots) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.collections,
                size: 14, color: NeumorphismTheme.getAccentColor(isDark)),
            const SizedBox(width: 6),
            Text(
              'Carousel · ${slots.length} images',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: NeumorphismTheme.getSecondaryTextColor(isDark),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 96,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: slots.length,
            separatorBuilder: (_, _) => const SizedBox(width: 6),
            itemBuilder: (context, index) {
              final url = (slots[index].imageUrl as String?) ?? '';
              return ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: 72,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (url.isEmpty)
                        Container(
                          color: NeumorphismTheme.getSurfaceColor(isDark),
                          child: Icon(Icons.broken_image,
                              size: 20, color: AppColors.error),
                        )
                      else
                        Image.network(
                          url,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) => Container(
                            color: NeumorphismTheme.getSurfaceColor(isDark),
                            child: Icon(Icons.broken_image,
                                size: 20, color: AppColors.error),
                          ),
                        ),
                      Positioned(
                        left: 4,
                        bottom: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.7),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '${index + 1}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// Build image preview
  Widget _buildImagePreview(String imageUrl) {
    // A video-only pin may carry no thumbnail at all: never hand an empty URL
    // to Image.network (it throws and renders a red error box).
    if (imageUrl.isEmpty) {
      return SizedBox(
        height: 180,
        child: Center(
          child: Icon(Icons.image_not_supported,
              size: 40, color: AppColors.error),
        ),
      );
    }
    return Image.network(
      imageUrl,
      height: 180,
      width: double.infinity,
      fit: BoxFit.cover,
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) return child;
        return SizedBox(
          height: 180,
          child: Center(
            child: CircularProgressIndicator(
              value: loadingProgress.expectedTotalBytes != null
                  ? loadingProgress.cumulativeBytesLoaded /
                      loadingProgress.expectedTotalBytes!
                  : null,
              strokeWidth: 2,
            ),
          ),
        );
      },
      errorBuilder: (context, error, stackTrace) {
        return SizedBox(
          height: 180,
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.broken_image, size: 40, color: AppColors.error),
                const SizedBox(height: 8),
                Text(
                  'Failed to load preview',
                  style: TextStyle(fontSize: 12, color: AppColors.error),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Build video preview with actual video playback (autoplay, muted, looped)
  Widget _buildVideoPreview(String thumbnailUrl, String? videoUrl) {
    // Initialize video controller if we have a video URL
    if (videoUrl != null && videoUrl.isNotEmpty) {
      // Use post-frame callback to avoid calling setState during build
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _initVideoController(videoUrl);
      });
    }
    
    return Stack(
      alignment: Alignment.center,
      children: [
        // Show video player if initialized, otherwise show thumbnail
        if (_isVideoInitialized && _videoController != null)
          SizedBox(
            height: 180,
            width: double.infinity,
            child: FittedBox(
              fit: BoxFit.cover,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: _videoController!.value.size.width,
                height: _videoController!.value.size.height,
                child: VideoPlayer(_videoController!),
              ),
            ),
          )
        else
          Image.network(
            thumbnailUrl,
            height: 180,
            width: double.infinity,
            fit: BoxFit.cover,
            loadingBuilder: (context, child, loadingProgress) {
              if (loadingProgress == null) return child;
              return SizedBox(
                height: 180,
                child: Center(
                  child: CircularProgressIndicator(
                    value: loadingProgress.expectedTotalBytes != null
                        ? loadingProgress.cumulativeBytesLoaded /
                            loadingProgress.expectedTotalBytes!
                        : null,
                    strokeWidth: 2,
                  ),
                ),
              );
            },
            errorBuilder: (context, error, stackTrace) {
              return SizedBox(
                height: 180,
                child: Center(
                  child: Icon(Icons.videocam_off, size: 40, color: AppColors.error),
                ),
              );
            },
          ),
        
        // Show loading indicator while video is initializing
        if (videoUrl != null && !_isVideoInitialized)
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.6),
              shape: BoxShape.circle,
            ),
            child: const Padding(
              padding: EdgeInsets.all(15),
              child: CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 2,
              ),
            ),
          ),
        
        // Video indicator badge
        Positioned(
          top: 8,
          right: 8,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.videocam, color: Colors.white, size: 14),
                const SizedBox(width: 4),
                Text(
                  _isVideoInitialized ? 'PLAYING' : 'VIDEO',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
        
        // Mute/unmute control (3.1.1) — a real button, not a status icon.
        if (_isVideoInitialized)
          Positioned(
            bottom: 8,
            right: 8,
            child: PreviewAudioToggle(
              muted: _isVideoMuted,
              onToggle: (_) => _toggleVideoMute(),
            ),
          ),
      ],
    );
  }
}
