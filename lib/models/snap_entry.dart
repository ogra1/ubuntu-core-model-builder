enum SnapType { kernel, gadget, base, app, snapd }

enum SnapPresence { required_, optional }

class SnapEntry {
  final String name;
  final String id;
  final SnapType type;
  final String defaultChannel;
  final SnapPresence? presence;
  final String? appBase;
  final bool autoAdded;

  /// Components: name -> presence ('required' or 'optional'). Empty when none.
  /// Currently only meaningful/edited for kernel snaps, but parsed/emitted for
  /// any snap type so imported models do not lose component data.
  final Map<String, String> components;

  SnapEntry({
    required this.name,
    required this.id,
    required this.type,
    required this.defaultChannel,
    this.presence,
    this.appBase,
    this.autoAdded = false,
    this.components = const {},
  });

  SnapEntry copyWith({
    SnapPresence? presence,
    String? appBase,
    bool? autoAdded,
    Map<String, String>? components,
  }) =>
      SnapEntry(
        name: name,
        id: id,
        type: type,
        defaultChannel: defaultChannel,
        presence: presence ?? this.presence,
        appBase: appBase ?? this.appBase,
        autoAdded: autoAdded ?? this.autoAdded,
        components: components ?? this.components,
      );

  Map<String, dynamic> toMap() {
    final m = <String, dynamic>{
      'name': name,
      'id': id,
      'type': type.name,
      'default-channel': defaultChannel,
    };
    if (presence != null) {
      m['presence'] =
          presence == SnapPresence.required_ ? 'required' : 'optional';
    }
    return m;
  }
}
