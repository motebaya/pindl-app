/// Status of an extraction/download operation
enum HistoryStatus {
  pending,
  success,
  failed,
  cancelled,
  skipped,
}

/// History item for tracking extraction requests
class HistoryItem {
  final String id;
  final String url;
  final HistoryStatus status;
  final DateTime createdAt;
  final String? errorMessage;

  HistoryItem({
    required this.id,
    required this.url,
    required this.status,
    required this.createdAt,
    this.errorMessage,
  });

  HistoryItem copyWith({
    String? id,
    String? url,
    HistoryStatus? status,
    DateTime? createdAt,
    String? errorMessage,
  }) {
    return HistoryItem(
      id: id ?? this.id,
      url: url ?? this.url,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  /// Format for display and copy
  String toDisplayString() {
    final statusStr = status.name;
    final dateStr = _formatDate(createdAt);
    return '$url\nstatus: $statusStr, date: $dateStr';
  }

  String _formatDate(DateTime date) {
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    final hour = date.hour > 12 ? date.hour - 12 : (date.hour == 0 ? 12 : date.hour);
    final ampm = date.hour >= 12 ? 'PM' : 'AM';
    final minute = date.minute.toString().padLeft(2, '0');
    return '${date.day} ${months[date.month - 1]} ${date.year}, $hour:$minute $ampm';
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'url': url,
    'status': status.name,
    'createdAt': createdAt.toIso8601String(),
    'errorMessage': errorMessage,
  };

  factory HistoryItem.fromJson(Map<String, dynamic> json) => HistoryItem(
    id: json['id'] as String,
    url: json['url'] as String,
    status: HistoryStatus.values.firstWhere(
      (s) => s.name == json['status'],
      orElse: () => HistoryStatus.pending,
    ),
    createdAt: DateTime.parse(json['createdAt'] as String),
    errorMessage: json['errorMessage'] as String?,
  );
}

/// Download history item
class DownloadHistoryItem {
  final String id;
  final String filename;
  final String url;
  final HistoryStatus status;
  final DateTime createdAt;
  final String? errorMessage;

  DownloadHistoryItem({
    required this.id,
    required this.filename,
    required this.url,
    required this.status,
    required this.createdAt,
    this.errorMessage,
  });

  /// Format for display and copy
  String toDisplayString() {
    final statusStr = status.name;
    final dateStr = _formatDate(createdAt);
    return '$filename\n$url\nstatus: $statusStr, date: $dateStr';
  }

  String _formatDate(DateTime date) {
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    final hour = date.hour > 12 ? date.hour - 12 : (date.hour == 0 ? 12 : date.hour);
    final ampm = date.hour >= 12 ? 'PM' : 'AM';
    final minute = date.minute.toString().padLeft(2, '0');
    return '${date.day} ${months[date.month - 1]} ${date.year}, $hour:$minute $ampm';
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'filename': filename,
    'url': url,
    'status': status.name,
    'createdAt': createdAt.toIso8601String(),
    'errorMessage': errorMessage,
  };

  factory DownloadHistoryItem.fromJson(Map<String, dynamic> json) => DownloadHistoryItem(
    id: json['id'] as String,
    filename: json['filename'] as String,
    url: json['url'] as String,
    status: HistoryStatus.values.firstWhere(
      (s) => s.name == json['status'],
      orElse: () => HistoryStatus.pending,
    ),
    createdAt: DateTime.parse(json['createdAt'] as String),
    errorMessage: json['errorMessage'] as String?,
  );
}
