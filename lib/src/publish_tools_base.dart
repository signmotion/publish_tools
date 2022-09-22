import 'dart:convert' show json;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:github/github.dart';
import 'package:grinder/grinder.dart';
import 'package:publish_tools/publish_tools.dart';
import 'package:mustache_template/mustache.dart';
import 'package:path/path.dart' as p;
import 'package:publish_tools/src/service/repository_service.dart';
import 'package:universal_io/io.dart';

final projectDir = Directory.current;

class PublishTools {
  static final PublishToolsConfig ptConfig =
      PublishToolsConfig.init(projectDir);

  static final bool isNewVersion = () {
    final pubSpec = ptConfig.pubSpec;

    return _git([
          'tag',
          '-l',
          'v${pubSpec.version}',
        ]).trim() !=
        'v${pubSpec.version}';
  }();

  /// https://pub.dev/documentation/grinder/latest/grinder.tools/run.html
  static String _git(List<String>? args) => run(
        'git',
        arguments: args ?? [],
      );

  /// Enables all tasks from the `publish_tools` package.
  static void addAllTasks() {
    addTask(GrinderTask(
      'pt-analyze',
      taskFunction: () => Analyzer.analyze('.', fatalWarnings: true),
      description: 'Perform static analysis.',
    ));

    addTask(GrinderTask(
      'pt-format',
      taskFunction: () => DartFmt.format('.'),
      description: 'Format code that might be auto-generated.',
    ));

    addTask(GrinderTask(
      'pt-doc',
      taskFunction: () => DartDoc.doc(),
      description: 'Generate the API documentation.',
    ));

    addTask(GrinderTask(
      'pt-test',
      taskFunction: () => TestRunner().test(),
      description: 'Perform tests.',
    ));

    addTask(GrinderTask(
      'pt-meta',
      taskFunction: _meta,
      description: 'Update the pubspec.json to display for the cli command.',
    ));

    addTask(GrinderTask(
      'pt-markdown',
      taskFunction: _markdown,
      description: 'Update the markdown templates with pubspec info.',
    ));

    addTask(GrinderTask(
      'pt-commit',
      depends: ['pt-analyze', 'pt-format', 'pt-doc', 'pt-meta', 'pt-markdown'],
      taskFunction: _commit,
      description: 'Commit, tag and push to github.',
    ));

    addTask(GrinderTask(
      'pt-release',
      taskFunction: _release,
      description: 'Update the markdown templates with pubspec info.',
    ));

    addTask(GrinderTask(
      'pt-homebrew',
      taskFunction: _homebrew,
      depends: ['pt-release'],
      description: 'Update the homebrew repository.',
    ));

    addTask(GrinderTask(
      'pt-clean',
      taskFunction: _clean,
      description: 'Remove build folder and homebrew repository.',
    ));

    addTask(GrinderTask(
      'pt-publish',
      taskFunction: _publish,
      depends: ['pt-commit'],
      description: 'Remove build folder and homebrew repository.',
    ));

    // addTask(GrinderTask(
    //   'pt-dry-run',
    //   depends: ['pt-markdown'],
    //   taskFunction: _dryrun,
    //   description: 'Perform a dry-run for pub.dev publishing.',
    // ));
  }

  // static void _dryrun() =>
  //     run('dart', arguments: ['pub', 'publish', '--dry-run']);

  static void _publish() =>
      run('dart', arguments: ['pub', 'publish', '--force']);

  static Future<void> _clean() async {
    final String homebrewRepoName = 'homebrew-${ptConfig.github.repoName}';

    final github =
        GitHub(auth: Authentication.withToken(ptConfig.github.bearerToken));

    final repoService = RepositoryService(github);

    await repoService.update();

    final homebrewSlug =
        RepositorySlug(ptConfig.github.repoUser, homebrewRepoName);

    try {
      if (repoService.exists(homebrewRepoName)) {
        final success =
            await github.repositories.deleteRepository(homebrewSlug);

        if (!success) {
          GrinderException('Could not delete repository - $homebrewSlug');
        } else {
          log('Removed $homebrewSlug repository.');
        }
      } else {
        log('Repository $homebrewSlug could not be found.');
      }
    } catch (exception) {
      log('Problem identifying repository $homebrewSlug.');
    }

    try {
      final buildFolder = joinDir(projectDir, [
        'build',
        homebrewRepoName,
      ]);

      Directory.current = buildFolder;

      hasGitInstalled();

      _git(['remote', 'rm', 'origin']);

      if (buildFolder.existsSync()) {
        buildFolder.deleteSync(recursive: true);

        log('"build" folder removed.');
      }
    } catch (exception) {
      log('Problem removing the build folder');
    } finally {
      Directory.current = projectDir;
    }
  }

  static Future<void> _homebrew() async {
    Repository? repository;

    final String homebrewRepoName = 'homebrew-${ptConfig.github.repoName}';

    final github =
        GitHub(auth: Authentication.withToken(ptConfig.github.bearerToken));

    final repoService = RepositoryService(github);

    await repoService.update();

    final homebrewSlug =
        RepositorySlug(ptConfig.github.repoUser, homebrewRepoName);

    final projectSlug =
        RepositorySlug(ptConfig.github.repoUser, ptConfig.github.repoName);

    final repoDir = joinDir(
      Directory.current,
      [
        'build',
        homebrewRepoName,
      ],
    )..createSync(recursive: true);

    if (repoService.exists(homebrewSlug.name)) {
      repository = repoService.getRepo(homebrewSlug.name);
    }

    Directory.current = repoDir;

    if (repository == null) {
      log('Repository "${homebrewSlug.toString()}" not found.');

      // No repo, so create one.
      await github.repositories
          .createRepository(CreateRepository(homebrewRepoName));

      await repoService.update();

      repository = repoService.getRepo(homebrewSlug.name);

      if (repository == null) {
        throw GrinderException(
            'Problem creating the new repository - $homebrewRepoName.');
      }

      log('New repository clone url: ${repository.cloneUrl}');

      hasGitInstalled();

      _git(['init']);
      _git(['branch', '-M', 'main']);
      _git(['remote', 'add', 'origin', repository.cloneUrl]);
    } else if (joinDir(repoDir, ['.git']).existsSync()) {
      // Repo exists since we found the .git folder
      log('Updating ${repository.cloneUrl}');

      _git(['fetch']);

      _git(['checkout', 'main']);
    } else {
      // no .git folder so recreate it
      Directory.current = projectDir;

      delete(repoDir);

      _git(['clone', repository.cloneUrl, repoDir.path]);

      _git(['config', 'advice.detachedHead', 'false']);
    }

    try {
      final pubSpec = ptConfig.pubSpec;

      final release = await github.repositories.getLatestRelease(projectSlug);

      final digest = await _download(release.tarballUrl!);

      joinFile(
        repoDir,
        ['README.md'],
      ).writeAsStringSync('''# $homebrewRepoName
 A tap for the ${ptConfig.github.repoName} v${pubSpec.version?.canonicalizedVersion} Dart package''',
          mode: FileMode.write);

      final ruby = '''class ${ptConfig.homebrew.className} < Formula
  desc "${pubSpec.description}"
  homepage "${pubSpec.homepage}"
  url "${release.tarballUrl}"
  sha256 "$digest"
  license "MIT"
  
  depends_on "dart-lang/dart/dart" => :build
  
  def install
    system "dart", "pub", "get"
    system "dart", "compile", "exe", "${ptConfig.homebrew.binFolder}/${ptConfig.homebrew.binSrc}", "-o", "${ptConfig.homebrew.executableName}"
    bin.install "${ptConfig.homebrew.executableName}"
  end
  
  test do
    assert_match "obs_websocket v${pubSpec.version?.canonicalizedVersion}", shell_output("${ptConfig.homebrew.binFolder}/${ptConfig.homebrew.executableName} version")
  end
end''';

      joinFile(
        joinDir(repoDir, ['Formula'])..createSync(),
        ['${ptConfig.homebrew.executableName}.rb'],
      ).writeAsStringSync(ruby, mode: FileMode.write);

      // assumes repoDir as current directory
      _git(['add', '.']);

      _git(['commit', '-m', 'v${pubSpec.version?.canonicalizedVersion}']);

      _git(['push', '-u', 'origin', 'main']);
    } catch (exception) {
      throw GrinderException('Problem updating ${homebrewSlug.toString()}');
    } finally {
      Directory.current = projectDir;
    }
  }

  static Future<void> _release() async {
    final pubSpec = ptConfig.pubSpec;

    final github =
        GitHub(auth: Authentication.withToken(ptConfig.github.bearerToken));

    final slug =
        RepositorySlug(ptConfig.github.repoUser, ptConfig.github.repoName);

    try {
      final release = await github.repositories
          .getReleaseByTagName(slug, pubSpec.version?.canonicalizedVersion);

      await github.repositories.deleteRelease(slug, release);

      log('Deleting existing release.');
    } catch (exception) {
      log('Existing release not found.');
    }

    final createRelease =
        CreateRelease('v${pubSpec.version?.canonicalizedVersion}');

    await github.repositories.createRelease(slug, createRelease);

    log('Release v${pubSpec.version?.canonicalizedVersion} created.');
  }

  static Future<void> _commit() async {
    final pubSpec = ptConfig.pubSpec;

    // final github =
    //     GitHub(auth: Authentication.withToken(ptConfig.github.bearerToken));

    // final projectSlug =
    //     RepositorySlug(ptConfig.github.repoUser, ptConfig.github.repoName);

    // final repository = await github.repositories.getRepository(projectSlug);

    hasGitInstalled();

    // _git(['remote', 'add', 'origin', repository.cloneUrl]);

    _git(['add', '.']);

    _git(['commit', '-m', '\'${ptConfig.commit}\'']);

    _git(['pull', '--tags']);

    if (isNewVersion) {
      _git(['tag', 'v${pubSpec.version}']);

      _git(['push', '--tags']);
    }

    _git(['push']);
  }

  static void _markdown() {
    final templates = ptConfig.templates;

    for (var tmpl in templates) {
      final mustacheTpl = joinFile(Directory.current, ['tool', tmpl.name]);

      final outputFile = File(tmpl.name);

      final template = Template(mustacheTpl.readAsStringSync(), name: tmpl.name)
          .renderString({
        'pubspec': ptConfig.pubSpec.toJson(),
        'github': ptConfig.github.toJson(),
        'homebrew': ptConfig.homebrew,
        'meta_path': ptConfig.optionalMetaFilePath,
        'templates': ptConfig.templates,
        'commit': ptConfig.commit,
        'changes': ptConfig.optionalChangeList,
      });

      switch (tmpl.type) {
        case 'prepend':
          final currentContent =
              outputFile.existsSync() ? outputFile.readAsStringSync() : '';

          outputFile.writeAsStringSync(template, mode: FileMode.write);

          outputFile.writeAsStringSync(
              currentContent.replaceFirst(RegExp(r'# Changelog\n'), ''),
              mode: FileMode.append);

          break;

        case 'overwrite':
          outputFile.deleteSync();

          outputFile.writeAsStringSync(template);

          break;

        default: //append
          outputFile.writeAsString(template, mode: FileMode.append);
      }
    }
  }

  static void _meta() async {
    final rawJson = json.encode(ptConfig.pubSpec.toJson());

    File(ptConfig.metaFilePath).writeAsStringSync('''/// DO NOT EDIT THIS FILE
/// THIS FILE IS AUTOMATICALLY OVER WRITTEN BY PublishTools
import 'dart:convert' show json;

final pubSpec = json.decode('$rawJson');
''');
  }

  static Future<Digest> _download(String url) async {
    final request = await HttpClient().getUrl(Uri.parse(url));

    final response = await request.close();

    return await sha256.bind(response.asBroadcastStream()).first;
  }

  static void hasGitInstalled() {
    if (run('which', arguments: ['git']).split(p.separator).last.trim() !=
        'git') {
      throw GrinderException('The git cli executable could not be located.');
    }
  }

  // void cloneOrPull(Repository repository) {
  //   final path = p.join('build', repository.name);

  //   if (Directory(p.join(path, '.git')).existsSync()) {
  //     log('Updating ${repository.cloneUrl}');

  //     _git(['fetch', 'origin']);
  //   } else {
  //     delete(Directory(path));

  //     _git(['clone', repository.cloneUrl, path]);

  //     _git(['config', 'advice.detachedHead', 'false']);
  //   }

  //   _git(['checkout', 'origin/HEAD']);
  // }
}
