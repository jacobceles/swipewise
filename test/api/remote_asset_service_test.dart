import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:swipewise/api/app_check_service.dart';
import 'package:swipewise/api/remote_asset_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PathProviderPlatform originalPaths;
  late RemoteAssetService service;
  const oldBody = '{"dataVersion":1}';

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('swipewise_asset_');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    AppCheckService.getTokenForTest = () async => 'test-attestation';
    service = RemoteAssetService(baseUrl: 'https://assets.test');
    await File('${directory.path}/catalog.json').writeAsString(oldBody);
    await File('${directory.path}/catalog.etag').writeAsString('old-tag');
    await File('${directory.path}/catalog.version').writeAsString('1');
  });
  tearDown(() async {
    AppCheckService.resetForTest();
    PathProviderPlatform.instance = originalPaths;
    await directory.delete(recursive: true);
  });

  Future<String?> fetch(http.Response response) => http.runWithClient(
    () => service.fetchIfUpdated('catalog', 'https://assets.test/catalog.json'),
    () => MockClient((request) async {
      expect(request.url.toString(), 'https://assets.test/catalog.json');
      expect(request.headers['If-None-Match'], 'old-tag');
      expect(request.headers['X-Firebase-AppCheck'], 'test-attestation');
      return response;
    }),
  );

  Future<void> expectOldCache() async {
    expect(await service.readCached('catalog'), oldBody);
    expect(await service.cachedDataVersion('catalog'), 1);
    expect(
      await File('${directory.path}/catalog.etag').readAsString(),
      'old-tag',
    );
  }

  test('304 leaves body, ETag, and version untouched', () async {
    expect(
      await fetch(
        http.Response(
          '{"dataVersion":99}',
          304,
          headers: {'etag': 'ignored-tag'},
        ),
      ),
      isNull,
    );
    await expectOldCache();
  });

  test('200 stores the validated body, ETag, and version', () async {
    const updated = '{"dataVersion":2,"cards":[]}';
    expect(
      await fetch(http.Response(updated, 200, headers: {'etag': 'new-tag'})),
      updated,
    );
    expect(await service.readCached('catalog'), updated);
    expect(await service.cachedDataVersion('catalog'), 2);
    expect(
      await File('${directory.path}/catalog.etag').readAsString(),
      'new-tag',
    );
  });

  test('corrupt 200 cannot poison cache or conditional retry', () async {
    expect(
      await fetch(http.Response('{broken', 200, headers: {'etag': 'bad-tag'})),
      isNull,
    );
    await expectOldCache();
    expect(await fetch(http.Response('', 304)), isNull);
    await expectOldCache();
  });
}

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}
