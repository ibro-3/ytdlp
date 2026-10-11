import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../core/models/video_info.dart';
import '../../../core/theme/app_theme_context.dart';
import '../../../core/utils/formatters.dart';
import '../../../widgets/platform/platform.dart';

class VideoInfoCard extends StatelessWidget {
  const VideoInfoCard({super.key, required this.video});
  final VideoInfo video;

  @override
  Widget build(BuildContext context) {
    final theme = context.textStyles;
    final scheme = context.colors;
    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: video.thumbnail == null
                ? ColoredBox(
                    color: scheme.surfaceContainerHighest,
                    child: Icon(
                      Icons.movie_outlined,
                      size: 56,
                      color: scheme.onSurfaceVariant,
                    ),
                  )
                : CachedNetworkImage(
                    imageUrl: video.thumbnail!,
                    fit: BoxFit.cover,
                    placeholder: (_, _) => ColoredBox(
                      color: scheme.surfaceContainerHighest,
                      child: const Center(child: AppCircularProgress()),
                    ),
                    errorWidget: (_, _, _) => ColoredBox(
                      color: scheme.surfaceContainerHighest,
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  video.title,
                  style: theme.titleMedium,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Icon(
                      Icons.account_circle_outlined,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        video.author ?? 'Unknown channel',
                        style: theme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (video.duration > 0)
                      AppLabelChip(
                        icon: Icons.schedule,
                        label: formatDuration(video.duration),
                      ),
                    if (video.uploadDate != null)
                      AppLabelChip(
                        icon: Icons.event_outlined,
                        label: formatDate(video.uploadDate!),
                      ),
                    if (video.videoFormats.isNotEmpty)
                      AppLabelChip(
                        icon: Icons.high_quality_outlined,
                        label: '${video.videoFormats.length} video options',
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
