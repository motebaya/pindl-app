import 'package:equatable/equatable.dart';

/// Pinterest configuration extracted from profile page
class PinterestConfig extends Equatable {
  final String appVersion;
  final String userId;

  const PinterestConfig({
    required this.appVersion,
    required this.userId,
  });

  factory PinterestConfig.fromJson(Map<String, dynamic> json) {
    return PinterestConfig(
      appVersion: json['appVersion'] as String? ?? '',
      userId: json['userId'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'appVersion': appVersion,
      'userId': userId,
    };
  }

  @override
  List<Object?> get props => [appVersion, userId];
}
