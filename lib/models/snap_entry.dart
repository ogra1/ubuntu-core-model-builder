enum SnapType { kernel, gadget, base, app, snapd }

/// Presence of an app or dependent-base snap in the model. Infrastructure
/// snaps (kernel/gadget/snapd and the model's own base) are always required
/// and don't set this.
enum SnapPresence { required_, optional }

class SnapEntry {
  final String name;
  final String id;
  final SnapType type;
  final String defaultChannel;

  /// For app snaps: required or optional presence.
  /// For dependent base snaps: derived from the apps that use them.
  /// Null for infrastructure snaps (implicitly required).
  final SnapPresence? presence;

  /// For app snaps: the base this app is built on (e.g. "core24"), used to
  /// drive precise presence coupling of dependent base snaps. Null for
  /// non-app snaps.
  final String? appBase;

  /// True if this snap was added automatically by the app (e.g. a base snap
  /// added because an app depends on it). Auto-added bases are removed again
  /// when their last dependent app is removed. User-added snaps are never
  /// auto-removed.
  final bool autoAdded;

  SnapEntry({
    required this.name,
    required this.id,
    required this.type,
    required this.defaultChannel,
    this.presence,
    this.appBase,
    this.autoAdded = false,
  });

  SnapEntry copyWith({
    SnapPresence? presence,
    String? appBase,
    bool? autoAdded,
  }) =>
      SnapEntry(
        name: name,
        id: id,
        type: type,
        defaultChannel: defaultChannel,
        presence: presence ?? this.presence,
        appBase: appBase ?? this.appBase,
        autoAdded: autoAdded ?? this.autoAdded,
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
