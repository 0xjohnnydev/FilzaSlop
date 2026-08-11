#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MCMLease : NSObject
@property(nonatomic, readonly) uint64_t containerClass;
@property(nonatomic, copy, readonly) NSString *identifier;
@property(nonatomic, copy, readonly) NSString *rootPath;
@property(nonatomic, readonly) BOOL groupIdentifier;
@property(nonatomic, readonly) BOOL tokenPresent;
@property(nonatomic, readonly) BOOL activated;

+ (nullable instancetype)leaseForClass:(uint64_t)containerClass
                             identifier:(NSString *)identifier
                                  group:(BOOL)group
                                   part:(uint64_t)part
                                  flags:(uint64_t)flags
                                  error:(NSString * _Nullable * _Nullable)error;
+ (nullable instancetype)leaseForClass:(uint64_t)containerClass
                             identifier:(NSString *)identifier
                                  group:(BOOL)group
                                   part:(uint64_t)part
                             partDomain:(nullable NSString *)partDomain
                                  flags:(uint64_t)flags
                                  error:(NSString * _Nullable * _Nullable)error;
- (BOOL)activate:(NSString * _Nullable * _Nullable)error;
- (void)invalidate;
@end

FOUNDATION_EXPORT BOOL MCMBridgeAvailable(void);
FOUNDATION_EXPORT NSArray<NSString *> *MCMEnumerateIdentifiersForClass(
    uint64_t containerClass, NSUInteger limit,
    NSString * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
