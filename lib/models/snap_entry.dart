enum SnapType { kernel, gadget, base, app, snapd }

class SnapEntry {
  final String name;
  final String id;
  final SnapType type;
  final String defaultChannel;

  SnapEntry({
    required this.name,
    required this.id,
    required this.type,
    required this.defaultChannel,
  });

  Map<String, dynamic> toMap() => {
        'name': name,
        'id': id,
        'type': type.name,
        'default-channel': defaultChannel,
      };
}
