class StoreSnap {
  final String name;
  final String snapId;
  final String? title;
  final String? summary;
  final String? type;
  final String? base; // the base this snap is built on (e.g. "core22")
  final List<String> channels;

  StoreSnap({
    required this.name,
    required this.snapId,
    this.title,
    this.summary,
    this.type,
    this.base,
    this.channels = const [],
  });

  factory StoreSnap.fromSnapdJson(Map<String, dynamic> json) {
    return StoreSnap(
      name: json['name'] as String,
      snapId: json['id'] as String? ?? json['snap-id'] as String? ?? '',
      title: json['title'] as String?,
      summary: json['summary'] as String?,
      type: json['type'] as String?,
      base: json['base'] as String?,
    );
  }
}
