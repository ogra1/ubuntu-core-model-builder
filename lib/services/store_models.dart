
/// A brand store the account can access. `ubuntu` is the global store, for
/// which the model's `store` field should be omitted entirely.
class BrandStore {
  final String id;
  final String? name;
  final List<String> roles;
  const BrandStore({required this.id, this.name, this.roles = const []});
  bool get isGlobal => id == 'ubuntu';
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'roles': roles,
      };
  factory BrandStore.fromJson(Map<String, dynamic> j) => BrandStore(
        id: j['id'] as String,
        name: j['name'] as String?,
        roles: (j['roles'] as List<dynamic>?)
                ?.map((r) => r.toString())
                .toList() ??
            const [],
      );
}

/// A snap listed in a brand store's catalog (id + name only; type/base/
/// channels are resolved separately via the store info API).
class StoreCatalogSnap {
  final String id;
  final String name;
  const StoreCatalogSnap({required this.id, required this.name});
}

/// Shared-prefs key under which the brand-store list is cached.
/// (Top-level because it is shared between the store catalog service
/// and the pages.)
const String prefCachedStores = 'metadata.cachedStores';

class StoreAuthException implements Exception {
  final String message;
  StoreAuthException(this.message);
  @override
  String toString() => message;
}

/// Thrown when the store rejected a *live* session's macaroon (HTTP 401/403)
/// — i.e. the in-process auth state still reads `succeeded` but the store no
/// longer honours the credentials (expired/invalid). A subtype of
/// [StoreAuthException] so existing `on StoreAuthException` handlers keep
/// compiling, but distinct enough for callers to force a real re-login
/// (`RustStoreCatalogService.reauthenticate`) rather than the no-op
/// `RustStoreCatalogService.webLogin`.
class StoreAuthExpiredException extends StoreAuthException {
  StoreAuthExpiredException(super.message);
}

class StoreUnavailableException implements Exception {
  final String message;
  StoreUnavailableException([this.message = 'Store lookup is unavailable.']);
  @override
  String toString() => message;
}
