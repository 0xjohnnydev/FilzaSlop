#import "MCMBridge.h"

#import <dlfcn.h>
#import <stdlib.h>
#import <xpc/xpc.h>

typedef void *(*MCMQueryCreate)(void);
typedef void (*MCMQuerySetU64)(void *, uint64_t);
typedef void (*MCMQuerySetXPC)(void *, xpc_object_t);
typedef void (*MCMQuerySetCString)(void *, const char *);
typedef void *(*MCMQueryGetPointer)(void *);
typedef bool (*MCMQueryIterate)(void *, bool (^)(void *));
typedef void (*MCMQueryFree)(void *);
typedef const char *(*MCMObjectGetPath)(void *);
typedef const char *(*MCMObjectGetIdentifier)(void *);
typedef void *(*MCMObjectCopy)(void *);
typedef char *(*MCMObjectCopyToken)(void *);
typedef bool (*MCMObjectActivate)(void *, bool);
typedef void (*MCMObjectFree)(void *);
typedef int (*MCMErrorGetInt)(void *);
typedef const char *(*MCMErrorGetString)(void *);

typedef struct {
    void *handle;
    MCMQueryCreate queryCreate;
    MCMQuerySetU64 querySetClass;
    MCMQuerySetXPC querySetIdentifiers;
    MCMQuerySetXPC querySetGroupIdentifiers;
    MCMQuerySetU64 querySetFlags;
    MCMQuerySetU64 querySetPart;
    MCMQuerySetCString querySetPartDomain;
    MCMQueryGetPointer queryGetSingle;
    MCMQueryGetPointer queryGetLastError;
    MCMQueryIterate queryIterate;
    MCMQueryFree queryFree;
    MCMObjectGetPath objectGetPath;
    MCMObjectGetIdentifier objectGetIdentifier;
    MCMObjectCopy objectCopy;
    MCMObjectCopyToken objectCopyToken;
    MCMObjectActivate objectActivate;
    MCMObjectFree objectFree;
    MCMErrorGetInt errorGetPOSIX;
    MCMErrorGetString errorGetMessage;
} MCMAPI;

static MCMAPI *MCMSharedAPI(void)
{
    static MCMAPI api;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        api.handle = dlopen("/usr/lib/system/libsystem_containermanager.dylib",
                            RTLD_NOW | RTLD_LOCAL);
        void *handle = api.handle != NULL ? api.handle : RTLD_DEFAULT;
#define LOAD(field, symbol) api.field = (__typeof(api.field))dlsym(handle, symbol)
        LOAD(queryCreate, "container_query_create");
        LOAD(querySetClass, "container_query_set_class");
        LOAD(querySetIdentifiers, "container_query_set_identifiers");
        LOAD(querySetGroupIdentifiers, "container_query_set_group_identifiers");
        LOAD(querySetFlags, "container_query_operation_set_flags");
        LOAD(querySetPart, "container_query_operation_set_part");
        LOAD(querySetPartDomain, "container_query_operation_set_part_domain");
        LOAD(queryGetSingle, "container_query_get_single_result");
        LOAD(queryGetLastError, "container_query_get_last_error");
        LOAD(queryIterate, "container_query_iterate_results_sync");
        LOAD(queryFree, "container_query_free");
        LOAD(objectGetPath, "container_object_get_path");
        LOAD(objectGetIdentifier, "container_object_get_identifier");
        LOAD(objectCopy, "container_object_copy");
        LOAD(objectCopyToken, "container_copy_sandbox_token");
        LOAD(objectActivate, "container_object_sandbox_extension_activate");
        LOAD(objectFree, "container_object_free");
        LOAD(errorGetPOSIX, "container_error_get_posix_errno");
        LOAD(errorGetMessage, "container_error_get_message");
#undef LOAD
    });
    return &api;
}

NSArray<NSString *> *MCMEnumerateIdentifiersForClass(
    uint64_t containerClass, NSUInteger limit, NSString **error)
{
    MCMAPI *api = MCMSharedAPI();
    if (!MCMBridgeAvailable() || !api->queryIterate || !api->objectGetIdentifier || limit == 0) {
        if (error) *error = @"ContainerManager enumeration API unavailable";
        return @[];
    }
    void *query = api->queryCreate();
    if (!query) {
        if (error) *error = @"container_query_create returned NULL";
        return @[];
    }
    api->querySetClass(query, containerClass);
    // Metadata-only, no-create lookup. Extensions are requested individually
    // only after an identifier passes validation.
    api->querySetFlags(query, 0x100000000ULL);
    // iOS 18 does not export the part API. A new query already defaults to
    // part 0, so only set it when the newer API is present.
    if (api->querySetPart) api->querySetPart(query, 0);
    NSMutableOrderedSet<NSString *> *identifiers = [NSMutableOrderedSet orderedSet];
    BOOL iterated = api->queryIterate(query, ^bool(void *object) {
        const char *raw = object ? api->objectGetIdentifier(object) : NULL;
        NSString *identifier = raw ? [NSString stringWithUTF8String:raw] : nil;
        if (identifier.length) [identifiers addObject:identifier];
        return identifiers.count < limit;
    });
    if (!iterated && identifiers.count < limit) {
        void *queryError = api->queryGetLastError(query);
        int posix = queryError && api->errorGetPOSIX ? api->errorGetPOSIX(queryError) : 0;
        const char *message = queryError && api->errorGetMessage
            ? api->errorGetMessage(queryError) : NULL;
        if (error) *error = [NSString stringWithFormat:@"enumeration denied posix=%d message=%s",
            posix, message ?: "unknown"];
    }
    api->queryFree(query);
    return identifiers.array;
}

BOOL MCMBridgeAvailable(void)
{
    MCMAPI *api = MCMSharedAPI();
    return api->queryCreate != NULL && api->querySetClass != NULL &&
        api->querySetIdentifiers != NULL && api->querySetGroupIdentifiers != NULL &&
        api->querySetFlags != NULL &&
        api->queryGetSingle != NULL && api->queryGetLastError != NULL &&
        api->queryFree != NULL && api->objectGetPath != NULL &&
        api->objectCopy != NULL && api->objectCopyToken != NULL &&
        api->objectActivate != NULL && api->objectFree != NULL;
}

@interface MCMLease () {
    void *_query;
    void *_activation;
}
@property(nonatomic, readwrite) uint64_t containerClass;
@property(nonatomic, copy, readwrite) NSString *identifier;
@property(nonatomic, copy, readwrite) NSString *rootPath;
@property(nonatomic, readwrite) BOOL groupIdentifier;
@property(nonatomic, readwrite) BOOL tokenPresent;
@property(nonatomic, readwrite) BOOL activated;
@end

@implementation MCMLease

+ (instancetype)leaseForClass:(uint64_t)containerClass
                    identifier:(NSString *)identifier
                         group:(BOOL)group
                          part:(uint64_t)part
                         flags:(uint64_t)flags
                         error:(NSString **)error
{
    return [self leaseForClass:containerClass identifier:identifier group:group
                          part:part partDomain:nil flags:flags error:error];
}

+ (instancetype)leaseForClass:(uint64_t)containerClass
                    identifier:(NSString *)identifier
                         group:(BOOL)group
                          part:(uint64_t)part
                    partDomain:(NSString *)partDomain
                         flags:(uint64_t)flags
                         error:(NSString **)error
{
    if (!MCMBridgeAvailable() || identifier.length == 0) {
        if (error) *error = @"ContainerManager bridge unavailable or identifier empty";
        return nil;
    }
    MCMAPI *api = MCMSharedAPI();
    void *query = api->queryCreate();
    if (query == NULL) {
        if (error) *error = @"container_query_create returned NULL";
        return nil;
    }
    api->querySetClass(query, containerClass);
    xpc_object_t value = xpc_string_create(identifier.UTF8String);
    if (group) api->querySetGroupIdentifiers(query, value);
    else api->querySetIdentifiers(query, value);
#if !OS_OBJECT_USE_OBJC
    xpc_release(value);
#endif
    api->querySetFlags(query, flags);
    if (part != 0 && !api->querySetPart) {
        if (error) *error = @"part API unavailable on this OS";
        api->queryFree(query);
        return nil;
    }
    if (api->querySetPart) api->querySetPart(query, part);
    if (partDomain.length != 0) {
        if (!api->querySetPartDomain) {
            if (error) *error = @"part-domain API unavailable";
            api->queryFree(query);
            return nil;
        }
        api->querySetPartDomain(query, partDomain.fileSystemRepresentation);
    }
    void *object = api->queryGetSingle(query);
    if (object == NULL) {
        void *queryError = api->queryGetLastError(query);
        int posix = queryError && api->errorGetPOSIX ? api->errorGetPOSIX(queryError) : 0;
        const char *message = queryError && api->errorGetMessage
            ? api->errorGetMessage(queryError) : NULL;
        if (error) *error = [NSString stringWithFormat:@"lookup denied posix=%d message=%s",
            posix, message ?: "unknown"];
        api->queryFree(query);
        return nil;
    }
    const char *rawPath = api->objectGetPath(object);
    NSString *root = rawPath ? [NSString stringWithUTF8String:rawPath] : nil;
    if (root.length == 0 || !root.isAbsolutePath) {
        if (error) *error = @"MCM returned no absolute container path";
        api->queryFree(query);
        return nil;
    }
    if ([root isEqualToString:@"/var"] || [root hasPrefix:@"/var/"])
        root = [@"/private" stringByAppendingString:root];
    MCMLease *lease = [MCMLease new];
    lease->_query = query;
    lease.containerClass = containerClass;
    lease.identifier = identifier;
    lease.groupIdentifier = group;
    lease.rootPath = root;
    return lease;
}

- (BOOL)activate:(NSString **)error
{
    if (self.activated) return YES;
    if (!_query) {
        if (error) *error = @"lease invalidated";
        return NO;
    }
    MCMAPI *api = MCMSharedAPI();
    void *object = api->queryGetSingle(_query);
    _activation = object ? api->objectCopy(object) : NULL;
    char *token = _activation ? api->objectCopyToken(_activation) : NULL;
    self.tokenPresent = token && token[0] != '\0';
    free(token);
    self.activated = self.tokenPresent && api->objectActivate(_activation, false);
    if (!self.activated && error)
        *error = self.tokenPresent ? @"sandbox extension activation failed"
                                   : @"MCM object contained no sandbox token";
    return self.activated;
}

- (void)invalidate
{
    MCMAPI *api = MCMSharedAPI();
    if (_activation) { api->objectFree(_activation); _activation = NULL; }
    if (_query) { api->queryFree(_query); _query = NULL; }
    self.activated = NO;
}

- (void)dealloc { [self invalidate]; }

@end
