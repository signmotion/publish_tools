import 'dart:convert';

import 'package:publish_tools/src/util/ext.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:pubspec/pubspec.dart';
import 'package:universal_io/io.dart';
import 'package:yaml/yaml.dart';

part 'github_config.g.dart';

@JsonSerializable()
class GithubConfig {
  final String repoUser;
  final String repoName;
  @JsonKey(name: 'bearerToken')
  final String? optionalBearerToken;

  GithubConfig({
    required this.repoUser,
    required this.repoName,
    this.optionalBearerToken,
  });

  String get bearerToken =>
      Platform.environment.containsKey('githubConfig_bearer_token')
          ? Platform.environment['githubConfig_bearer_token']!
          : optionalBearerToken ?? '';

  String get repoPath => '$repoUser/$repoName';

  factory GithubConfig.fromYamlMap(YamlMap template, PubSpec pubspec) {
    final checkKeys = <String>['repoUser'];

    if (!template.mapContainsKeys(checkKeys)) {
      throw Exception('The config file is missing a template key.');
    }

    return GithubConfig(
      repoUser: template['repoUser'],
      repoName: template['repoName'] ?? pubspec.name,
      optionalBearerToken: template['bearerToken'],
    );
  }

  factory GithubConfig.fromJson(Map<String, dynamic> json) =>
      _$GithubConfigFromJson(json);

  Map<String, dynamic> toJson() => _$GithubConfigToJson(this)
    ..removeWhere((key, value) => value == null)
    ..putIfAbsent('repoPath', () => repoPath)
    ..putIfAbsent('bearerToken', () => bearerToken);

  @override
  String toString() => json.encode(toJson());
}