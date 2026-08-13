#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT void MCMFilzaStart(void);
FOUNDATION_EXPORT NSString *_Nullable MCMFilzaDataContainerPath(
    NSString *identifier, NSString * _Nullable * _Nullable error);
FOUNDATION_EXPORT NSString *MCMFilzaVirtualRoot(void);
FOUNDATION_EXPORT NSString *MCMFilzaArchivePath(void);
FOUNDATION_EXPORT void MCMFilzaRecordDeletedGeneratedPath(NSString *path);
FOUNDATION_EXPORT NSString *MCMFilzaWallpaperLabName(void);
FOUNDATION_EXPORT BOOL MCMFilzaIsRunningInLiveContainer(void);
FOUNDATION_EXPORT BOOL MCMFilzaPathHasActiveLease(NSString *path);
FOUNDATION_EXPORT void MCMFilzaSetUnrestrictedFilesystem(BOOL enabled);

NS_ASSUME_NONNULL_END
