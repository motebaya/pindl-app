import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/core/exceptions/pinterest_exception.dart';
import 'package:pindl/data/controllers/download_coordinator.dart';
import 'package:pindl/data/models/author.dart';
import 'package:pindl/data/models/hls_conversion_result.dart';
import 'package:pindl/data/models/media_result.dart';
import 'package:pindl/data/services/download_service.dart';
import 'package:pindl/data/services/hls_converter.dart';
import 'package:pindl/data/services/hls_service.dart';

/// 3.1.1 — single-pin download strategy.
///
/// Device report (CRITICAL): a video pin previewed fine but the file that
/// landed was a 918/920 B HLS master playlist named `<pinId>_video.mp4`, with
/// nothing logged as an error — the single-pin flow had no HLS branch at all.
/// The same flow also downloaded a 60x60 thumbnail as the pin's image.
///
/// These tests pin the decision logic: no I/O, fake DownloadService, fake HLS
/// services injected exactly as the provider does per flavor (present =
/// FFmpeg build, null = lite build).
void main() {
  const pinId = '727331408611432034';

  MediaResult media({
    String? imageUrl,
    String? videoUrl,
    bool videoNeedConvert = false,
    List<MediaSlot> slots = const [],
  }) =>
      MediaResult(
        author: const Author(username: 'u', name: 'n', userId: '1'),
        title: 't',
        pinId: pinId,
        imageUrl: imageUrl,
        videoUrl: videoUrl,
        videoNeedConvert: videoNeedConvert,
        thumbnail: 'https://i.pinimg.com/60x60/aa/bb/cc/thumb.jpg',
        hasImage: imageUrl != null,
        hasVideoContent: videoUrl != null,
        isVideo: videoUrl != null,
        slots: slots,
      );

  DownloadCoordinatorHooks hooks() => DownloadCoordinatorHooks(
        queue: (_) {},
        downloading: (_) {},
        saved: (_) {},
        skipped: (_) {},
        failed: (_) {},
        parse: (_) {},
        error: (_) {},
        interrupted: (_) {},
        complete: (_) {},
        onFfmpegLog: (_) {},
        onHistory: ({required filename, required url, required success, errorMessage}) {},
        mapError: (e) => e.toString(),
      );

  group('progressive video (the fixed default path)', () {
    test('direct MP4 downloads as a file and never touches the HLS services',
        () async {
      final service = _FakeDownloadService();
      final converter = _FakeConverter();
      final coordinator = DownloadCoordinator(
        downloadService: service,
        hlsService: _FakeHlsService(fail: true),
        hlsConverter: converter,
        hooks: hooks(),
      );

      final run = await coordinator.runSinglePinDownload(
        result: media(videoUrl: 'https://v1.pinimg.com/videos/iht/expMp4/aa/bb/cc/x_720w.mp4'),
        outputPath: 'Downloads/PinDL',
        overwrite: true,
        downloadImage: false,
        downloadVideo: true,
      );

      expect(run.downloaded, 1);
      expect(service.downloads, hasLength(1));
      expect(service.downloads.single.url, endsWith('x_720w.mp4'));
      expect(service.downloads.single.filename, '${pinId}_video.mp4');
      expect(converter.calls, 0, reason: 'no conversion for a direct MP4');
      expect(service.savedTempFiles, isEmpty);
    });
  });

  group('HLS video on the FFmpeg flavor', () {
    test('parses the playlist, converts, and imports the MP4', () async {
      final service = _FakeDownloadService();
      final converter = _FakeConverter(
        result: HlsConversionResult.success(
          outputPath: '/tmp/${pinId}_video.mp4',
          fileSize: 2000000,
        ),
      );
      final coordinator = DownloadCoordinator(
        downloadService: service,
        hlsService: _FakeHlsService(),
        hlsConverter: converter,
        hooks: hooks(),
      );

      final run = await coordinator.runSinglePinDownload(
        result: media(
          videoUrl: 'https://v1.pinimg.com/videos/iht/hls/42/16/b2/master.m3u8',
          videoNeedConvert: true,
        ),
        outputPath: 'Downloads/PinDL',
        overwrite: true,
        downloadImage: false,
        downloadVideo: true,
      );

      expect(run.downloaded, 1);
      expect(run.failed, 0);
      // The playlist was parsed and the VARIANT converted — never downloaded
      // as a file.
      expect(converter.calls, 1);
      expect(converter.usedVideoM3u8, endsWith('_720.m3u8'));
      expect(converter.usedAudioM3u8, endsWith('_audio.m3u8'));
      expect(service.downloads, isEmpty,
          reason: 'the m3u8 must never go through the byte downloader');
      expect(service.savedTempFiles.single, '/tmp/${pinId}_video.mp4');
    });

    test('a failed conversion is a failure, not a silent corrupt file',
        () async {
      final service = _FakeDownloadService();
      final history = <bool>[];
      final coordinator = DownloadCoordinator(
        downloadService: service,
        hlsService: _FakeHlsService(),
        hlsConverter: _FakeConverter(
          result: HlsConversionResult.error('FFmpeg failed with code 1'),
        ),
        hooks: DownloadCoordinatorHooks(
          queue: (_) {},
          downloading: (_) {},
          saved: (_) {},
          skipped: (_) {},
          failed: (_) {},
          parse: (_) {},
          error: (_) {},
          interrupted: (_) {},
          complete: (_) {},
          onFfmpegLog: (_) {},
          onHistory: ({required filename, required url, required success, errorMessage}) =>
              history.add(success),
          mapError: (e) => e.toString(),
        ),
      );

      final run = await coordinator.runSinglePinDownload(
        result: media(
          videoUrl: 'https://v1.pinimg.com/videos/iht/hls/42/16/b2/master.m3u8',
          videoNeedConvert: true,
        ),
        outputPath: 'Downloads/PinDL',
        overwrite: true,
        downloadImage: false,
        downloadVideo: true,
      );

      expect(run.failed, 1);
      expect(run.downloaded, 0);
      expect(service.downloads, isEmpty);
      expect(service.savedTempFiles, isEmpty);
      expect(history, [false]);
    });

    test('skip-existing (overwrite=false) skips BEFORE converting anything',
        () async {
      final service = _FakeDownloadService(existing: true);
      final converter = _FakeConverter(
        result: HlsConversionResult.success(
          outputPath: '/tmp/${pinId}_video.mp4',
          fileSize: 2000000,
        ),
      );
      final coordinator = DownloadCoordinator(
        downloadService: service,
        hlsService: _FakeHlsService(),
        hlsConverter: converter,
        hooks: hooks(),
      );

      final run = await coordinator.runSinglePinDownload(
        result: media(
          videoUrl: 'https://v1.pinimg.com/videos/iht/hls/42/16/b2/master.m3u8',
          videoNeedConvert: true,
        ),
        outputPath: 'Downloads/PinDL',
        overwrite: false,
        downloadImage: false,
        downloadVideo: true,
      );

      expect(run.skipped, 1);
      expect(run.downloaded, 0);
      expect(run.failed, 0);
      expect(converter.calls, 0,
          reason: 'a present file must not trigger a full playlist conversion');
      expect(service.savedTempFiles, isEmpty);
    });

    test('cancelled conversion counts as interrupted, never failed', () async {
      final service = _FakeDownloadService();
      final coordinator = DownloadCoordinator(
        downloadService: service,
        hlsService: _FakeHlsService(),
        hlsConverter: _FakeConverter(result: HlsConversionResult.cancelled()),
        hooks: hooks(),
      );

      final run = await coordinator.runSinglePinDownload(
        result: media(
          videoUrl: 'https://v1.pinimg.com/videos/iht/hls/42/16/b2/master.m3u8',
          videoNeedConvert: true,
        ),
        outputPath: 'Downloads/PinDL',
        overwrite: true,
        downloadImage: false,
        downloadVideo: true,
      );

      expect(run.wasInterrupted, isTrue);
      expect(run.failed, 0);
      expect(run.downloaded, 0);
    });
  });

  group('HLS video on the lite flavor (no FFmpeg services)', () {
    test('honest skip with the documented reason — no file at all', () async {
      final service = _FakeDownloadService();
      final skipped = <String>[];
      final coordinator = DownloadCoordinator(
        downloadService: service,
        // Exactly what JobNotifier constructs when enableFfmpeg is false.
        hlsService: null,
        hlsConverter: null,
        hooks: DownloadCoordinatorHooks(
          queue: (_) {},
          downloading: (_) {},
          saved: (_) {},
          skipped: skipped.add,
          failed: (_) {},
          parse: (_) {},
          error: (_) {},
          interrupted: (_) {},
          complete: (_) {},
          onFfmpegLog: (_) {},
          onHistory: ({required filename, required url, required success, errorMessage}) {},
          mapError: (e) => e.toString(),
        ),
      );

      final run = await coordinator.runSinglePinDownload(
        result: media(
          videoUrl: 'https://v1.pinimg.com/videos/iht/hls/42/16/b2/master.m3u8',
          videoNeedConvert: true,
        ),
        outputPath: 'Downloads/PinDL',
        overwrite: true,
        downloadImage: false,
        downloadVideo: true,
      );

      expect(run.skipped, 1);
      expect(run.downloaded, 0);
      expect(service.downloads, isEmpty);
      expect(skipped.single, contains('requires FFmpeg build'));
    });
  });

  group('images', () {
    test('a thumbnail-only URL is upgraded to the full-size rendition',
        () async {
      final service = _FakeDownloadService();
      final coordinator = DownloadCoordinator(
        downloadService: service,
        hooks: hooks(),
      );

      final run = await coordinator.runSinglePinDownload(
        result: media(
          imageUrl: 'https://i.pinimg.com/60x60/aa/bb/cc/aabbcc11223344556677889900112233.jpg',
        ),
        outputPath: 'Downloads/PinDL',
        overwrite: true,
        downloadImage: true,
        downloadVideo: false,
      );

      expect(run.downloaded, 1);
      expect(service.downloads.single.url, contains('/originals/'));
      expect(service.downloads.single.filename, '${pinId}_image.jpg');
    });

    test('a video-only pin downloads the thumbnail (role: thumbnail)', () async {
      final service = _FakeDownloadService();
      final coordinator = DownloadCoordinator(
        downloadService: service,
        hooks: hooks(),
      );

      await coordinator.runSinglePinDownload(
        result: media(
          videoUrl: 'https://v1.pinimg.com/videos/iht/expMp4/aa/bb/cc/x_720w.mp4',
        ),
        outputPath: 'Downloads/PinDL',
        overwrite: true,
        downloadImage: true,
        downloadVideo: false,
      );

      expect(service.downloads.single.filename, '${pinId}_thumbnail.jpg');
      expect(service.downloads.single.url, contains('/originals/'));
    });
  });

  group('carousel', () {
    test('every slot downloads, in slot order, with indexed names', () async {
      final service = _FakeDownloadService();
      final coordinator = DownloadCoordinator(
        downloadService: service,
        hooks: hooks(),
      );

      final slots = List.generate(
        8,
        (i) => MediaSlot(
          imageUrl:
              'https://i.pinimg.com/236x/aa/bb/cc/aabbcc1122334455667788990011223$i.jpg',
          width: 236,
          height: 314,
        ),
      );

      final run = await coordinator.runSinglePinDownload(
        result: media(imageUrl: slots.first.imageUrl, slots: slots),
        outputPath: 'Downloads/PinDL',
        overwrite: true,
        downloadImage: true,
        downloadVideo: false,
      );

      expect(run.downloaded, 8);
      expect(service.downloads, hasLength(8));
      for (var i = 0; i < 8; i++) {
        expect(service.downloads[i].filename, '${pinId}_image_${i + 1}.jpg');
        expect(service.downloads[i].url, contains('/originals/'));
      }
    });

    test('skip-existing on a re-run counts as skipped, not failed', () async {
      final service = _FakeDownloadService(
        failure: DownloadException('File already exists',
            filePath: 'Downloads/PinDL/x.jpg'),
      );
      final coordinator = DownloadCoordinator(
        downloadService: service,
        hooks: hooks(),
      );

      final run = await coordinator.runSinglePinDownload(
        result: media(imageUrl: 'https://i.pinimg.com/736x/aa/bb/cc/x.jpg'),
        outputPath: 'Downloads/PinDL',
        overwrite: false,
        downloadImage: true,
        downloadVideo: false,
      );

      expect(run.skipped, 1);
      expect(run.failed, 0);
    });
  });
}

class _DownloadCall {
  final String url;
  final String filename;
  final String pinId;
  _DownloadCall({required this.url, required this.filename, required this.pinId});
}

class _FakeDownloadService extends DownloadService {
  _FakeDownloadService({this.failure, this.existing = false})
      : super(dio: Dio());

  final Object? failure;

  /// When true, `fileExistsInDownloads` reports the target as already present
  /// (the skip-existing gate).
  final bool existing;
  final List<_DownloadCall> downloads = [];
  final List<String> savedTempFiles = [];

  @override
  Future<bool> fileExistsInDownloads(String filename, String subFolder) async =>
      existing;

  @override
  Future<String?> downloadFile({
    required String url,
    required String outputPath,
    required String filename,
    required String pinId,
    required bool overwrite,
    String subFolder = 'PinDL',
    CancelToken? cancelToken,
    void Function(int received, int total)? onProgress,
  }) async {
    downloads.add(_DownloadCall(url: url, filename: filename, pinId: pinId));
    if (failure != null) throw failure!;
    return 'Downloads/$subFolder/$filename';
  }

  @override
  Future<String?> saveFileToDownloads(
    String tempPath,
    String filename,
    String subFolder, {
    bool overwrite = true,
  }) async {
    savedTempFiles.add(tempPath);
    return 'Downloads/$subFolder/$filename';
  }
}

class _FakeHlsService extends HlsService {
  _FakeHlsService({this.fail = false});
  final bool fail;

  @override
  Future<HlsParseResult> fetchAndParse(String masterPlaylistUrl) async {
    if (fail) {
      return HlsParseResult.error('should not be called for a direct MP4');
    }
    final base = masterPlaylistUrl.replaceAll('master.m3u8', '');
    return HlsParseResult.success(
      videoVariantUrl: '${base}x_720.m3u8',
      audioUrl: '${base}x_audio.m3u8',
      width: 720,
      height: 1280,
      bandwidth: 1200000,
    );
  }
}

class _FakeConverter extends HlsConverter {
  _FakeConverter({HlsConversionResult? result})
      : result = result ??
            HlsConversionResult.error('no fake result configured');

  final HlsConversionResult result;
  int calls = 0;
  String? usedVideoM3u8;
  String? usedAudioM3u8;

  @override
  Future<HlsConversionResult> convertToMp4({
    required String videoM3u8Url,
    String? audioM3u8Url,
    required String outputFilename,
    void Function(double progress)? onProgress,
    void Function(String log)? onLog,
    CancelToken? cancelToken,
  }) async {
    calls++;
    usedVideoM3u8 = videoM3u8Url;
    usedAudioM3u8 = audioM3u8Url;
    return result;
  }
}
