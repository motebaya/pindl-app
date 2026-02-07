import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/neumorphism_theme.dart';
import '../widgets/soft_button.dart';
import '../widgets/soft_card.dart';

/// About page with app information
class AboutPage extends ConsumerWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: NeumorphismTheme.getBackgroundColor(isDark),
      body: SafeArea(
        child: Column(
          children: [
            // Top bar
            _buildTopBar(context, isDark),

            // Content
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    // App info card
                    SoftCard(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        children: [
                          // App icon
                          Container(
                            width: 80,
                            height: 80,
                            decoration: BoxDecoration(
                              color: NeumorphismTheme.getCardColor(isDark),
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: NeumorphismTheme.getRaisedShadows(isDark),
                            ),
                            child: Icon(
                              Icons.push_pin,
                              size: 40,
                              color: NeumorphismTheme.getAccentColor(isDark),
                            ),
                          ),
                          const SizedBox(height: 16),

                          // App name
                          Text(
                            'PinDL',
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color: NeumorphismTheme.getTextColor(isDark),
                            ),
                          ),
                          const SizedBox(height: 4),

                          // Version
                          Text(
                            'Version 1.1.0',
                            style: TextStyle(
                              fontSize: 14,
                              color: NeumorphismTheme.getSecondaryTextColor(isDark),
                            ),
                          ),
                          const SizedBox(height: 16),

                          // Description
                          Text(
                            'Pinterest Downloader for Android',
                            style: TextStyle(
                              fontSize: 14,
                              color: NeumorphismTheme.getTextColor(isDark),
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'A personal-use utility for downloading publicly accessible Pinterest content.',
                            style: TextStyle(
                              fontSize: 13,
                              color: NeumorphismTheme.getSecondaryTextColor(isDark),
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),

                    // Features card
                    SoftCard(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Features',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: NeumorphismTheme.getTextColor(isDark),
                            ),
                          ),
                          const SizedBox(height: 12),
                          _buildFeatureItem(isDark, Icons.person, 'Download from Pinterest username'),
                          _buildFeatureItem(isDark, Icons.link, 'Download single pins via URL or ID'),
                          _buildFeatureItem(isDark, Icons.image, 'Support for images and videos'),
                          _buildFeatureItem(isDark, Icons.save, 'Metadata saving for resume'),
                          _buildFeatureItem(isDark, Icons.folder, 'Custom output folder selection'),
                          _buildFeatureItem(isDark, Icons.dark_mode, 'Light and dark theme support'),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),

                    // Legal disclaimer
                    SoftCard(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.gavel,
                                size: 18,
                                color: NeumorphismTheme.getSecondaryTextColor(isDark),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Legal Notice',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: NeumorphismTheme.getTextColor(isDark),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'This app is intended for personal use only. It only handles publicly accessible content. Users are responsible for ensuring their use complies with Pinterest\'s terms of service and applicable laws.',
                            style: TextStyle(
                              fontSize: 13,
                              color: NeumorphismTheme.getSecondaryTextColor(isDark),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),

                    // Credits
                    SoftCard(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        children: [
                          Text(
                            'Made with ☕ by davins',
                            style: TextStyle(
                              fontSize: 14,
                              color: NeumorphismTheme.getTextColor(isDark),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '@github.com/motebaya',
                            style: TextStyle(
                              fontSize: 13,
                              color: NeumorphismTheme.getSecondaryTextColor(isDark),
                            ),
                          ),
                        ],
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

  Widget _buildTopBar(BuildContext context, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          SoftIconButton(
            icon: Icons.arrow_back,
            onPressed: () => Navigator.pop(context),
          ),
          const SizedBox(width: 12),
          Text(
            'About',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: NeumorphismTheme.getTextColor(isDark),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFeatureItem(bool isDark, IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(
            icon,
            size: 18,
            color: NeumorphismTheme.getAccentColor(isDark),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                color: NeumorphismTheme.getTextColor(isDark),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
