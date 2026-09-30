// Part of `home_page.dart` (same library via `part`) — Phase 08.6 file
// split: the single-pin media preview widgets.
part of 'home_page.dart';

extension _HomePagePreview on _HomePageState {
  Widget _buildMediaPreview(bool isDark, dynamic singleResult) {
    final settings = ref.watch(settingsProvider);
    final hasVideo = singleResult.hasVideoContent ?? false;
    final hasImage = singleResult.hasImage ?? false;
    final thumbnail = singleResult.thumbnail as String?;
    final imageUrl = singleResult.imageUrl as String?;
    final videoUrl = singleResult.videoUrl as String?;
    
    final showImage = settings.downloadImage;
    final showVideo = settings.downloadVideo && hasVideo;
    
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
      if (previewUrl == null) return const SizedBox.shrink();
      
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
    }
    
    return const SizedBox.shrink();
  }

  /// Build image preview
  Widget _buildImagePreview(String imageUrl) {
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
        
        // Muted indicator
        if (_isVideoInitialized)
          Positioned(
            bottom: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Icon(Icons.volume_off, color: Colors.white, size: 16),
            ),
          ),
      ],
    );
  }
}
