import 'package:equatable/equatable.dart';

/// Author/creator information for a pin
class Author extends Equatable {
  final String username;
  final String name;
  final String userId;
  final String? avatarUrl; // Profile avatar image URL

  const Author({
    required this.username,
    required this.name,
    required this.userId,
    this.avatarUrl,
  });

  factory Author.fromJson(Map<String, dynamic> json) {
    return Author(
      username: json['username'] as String? ?? '-',
      name: json['name'] as String? ?? json['fullName'] as String? ?? json['full_name'] as String? ?? '-',
      userId: json['userId'] as String? ?? json['entityId'] as String? ?? json['id'] as String? ?? '-',
      avatarUrl: json['avatarUrl'] as String? ?? json['image_large_url'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'username': username,
      'name': name,
      'userId': userId,
      if (avatarUrl != null) 'avatarUrl': avatarUrl,
    };
  }

  Author copyWith({
    String? username,
    String? name,
    String? userId,
    String? avatarUrl,
  }) {
    return Author(
      username: username ?? this.username,
      name: name ?? this.name,
      userId: userId ?? this.userId,
      avatarUrl: avatarUrl ?? this.avatarUrl,
    );
  }

  @override
  List<Object?> get props => [username, name, userId, avatarUrl];

  @override
  String toString() => 'Author(@$username, $name, id: $userId)';
}
