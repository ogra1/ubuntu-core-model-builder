enum SnapType { kernel, gadget, base, app, snapd }

/// Presence of an app snap in the model. Infrastructure snaps
/// (kernel/gadget/base/snapd) are always required and don't set this.
enum SnapPresence { required_, optional }

class SnapEntry {
  final String name;
  final String id;
  final SnapType type;
  final String defaultChannel;

  /// For app snaps: whether the snap is required or optional in the model.
  /// Null for infrastructure snaps (implicitly required).
  final SnapPresence? presence;

  SnapEntry({
    required this.name,
    required this.id,
    required this.type,
    required this.defaultChannel,
    this.presence,
  });

  SnapEntry copyWith({SnapPresence? presence}) => SnapEntry(
        name: name,
        id: id,
        type: type,
        defaultChannel: defaultChannel,
        presence: presence ?? this.presence,
      );

  Map<String, dynamic> toMap() {
    final m = <String, dynamic>{
      'name': name,
      'id': id,
      'type': type.name,
      'default-channel': defaultChannel,
    };
    if (presence != null) {
      m['presence'] = presence == SnapPresence.required_ ? 'required' : 'optional';
    }
    return m;
  }
}
