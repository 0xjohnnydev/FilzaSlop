@import UIKit;
#import <objc/runtime.h>
#import <objc/message.h>
#import <xpc/xpc.h>

#include <errno.h>
#include <dirent.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "MCMFilzaIntegration.h"
#include "PosterBoardFeature.h"

#pragma mark - Root Helper Hooks

static BOOL hook_isRootHelperAvailable(id self, SEL _cmd) {
    return NO;
}

static int hook_spawnRootHelper(id self, SEL _cmd) { return 0; }
static int hook_spawnRootHelperIfNeeds(id self, SEL _cmd) { return 0; }
static int hook_respawnRootHelper(id self, SEL _cmd) { return 0; }
static void hook_tryLoadFilzaHelper(id self, SEL _cmd) {}
static void hook_createHelperConnectionIfNeeds(id self, SEL _cmd) {}

// A jailed Filza otherwise restores its usual /var/mobile start path, which is
// not listable by this container-scoped primitive. Start directly in the MCM
// virtual root after ensuring it has been populated.
static id hook_defaultPath(id self, SEL _cmd) {
    MCMFilzaStart();
    return MCMFilzaVirtualRoot();
}

static NSString *redirectedLegacyBrowserPath(id requestedPath) {
    NSString *path = [requestedPath isKindOfClass:NSString.class] ? requestedPath : nil;
    NSRange legacy = [path rangeOfString:@"/Documents/MCM Containers"];
    if (legacy.location != NSNotFound) {
        NSUInteger suffixStart = NSMaxRange(legacy);
        NSString *suffix = suffixStart < path.length ? [path substringFromIndex:suffixStart] : @"";
        path = [MCMFilzaVirtualRoot() stringByAppendingString:suffix];
    }
    return path;
}

static IMP orig_fileSystemSetCurrentPath = NULL;
static IMP orig_fileSystemUpdateEditableUI = NULL;
static void refreshWallpaperButton(id controller, id fallbackPath) {
    if (![controller isKindOfClass:UIViewController.class]) return;
    SEL selector = NSSelectorFromString(@"currentPath");
    NSString *currentPath = [controller respondsToSelector:selector]
        ? ((id(*)(id, SEL))objc_msgSend)(controller, selector) : nil;
    PBWallpaperConfigureBrowser((UIViewController *)controller,
        currentPath ?: fallbackPath);
}

static void hook_fileSystemUpdateEditableUI(id self, SEL _cmd) {
    ((void(*)(id, SEL))orig_fileSystemUpdateEditableUI)(self, _cmd);
    // This is the exact Filza routine that restores the Edit item. Apply the
    // Wallpaper Lab action after Filza has completed that update.
    refreshWallpaperButton(self, nil);
}

static void hook_fileSystemSetCurrentPath(id self, SEL _cmd, id requestedPath) {
    NSString *path = redirectedLegacyBrowserPath(requestedPath);
    if (path && ![path isEqual:requestedPath])
        NSLog(@"[DeviceStorage] redirected legacy browser path to %@", path);
    ((void(*)(id, SEL, id))orig_fileSystemSetCurrentPath)(self, _cmd, path ?: requestedPath);
    refreshWallpaperButton(self, path ?: requestedPath);
    // Filza rebuilds its Edit item after loading a directory. Re-apply the
    // lab action after those deferred navigation updates have completed.
    for (NSNumber *delay in @[@100, @500]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            delay.unsignedLongLongValue * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                refreshWallpaperButton(self, path ?: requestedPath);
            });
    }
}

static IMP orig_fileSystemViewWillAppear = NULL;
static BOOL gNormalizedInitialBrowserPath = NO;
static void hook_fileSystemViewWillAppear(id self, SEL _cmd, BOOL animated) {
    NSString *currentPath = [self respondsToSelector:NSSelectorFromString(@"currentPath")]
        ? ((id(*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"currentPath")) : nil;
    NSString *redirected = redirectedLegacyBrowserPath(currentPath);
    NSString *root = MCMFilzaVirtualRoot();
    BOOL firstAppearance = !gNormalizedInitialBrowserPath;
    gNormalizedInitialBrowserPath = YES;
    BOOL insideRoot = [currentPath isEqualToString:root] ||
        [currentPath hasPrefix:[root stringByAppendingString:@"/"]];
    if (firstAppearance && currentPath.length > 0 && !insideRoot)
        redirected = root;
    if (redirected && ![redirected isEqual:currentPath]) {
        ((void(*)(id, SEL, id))objc_msgSend)(self,
            NSSelectorFromString(@"setCurrentPath:"), redirected);
        NSLog(@"[DeviceStorage] repaired initial browser path from %@ to %@",
            currentPath, redirected);
    }
    ((void(*)(id, SEL, BOOL))orig_fileSystemViewWillAppear)(self, _cmd, animated);

    if (firstAppearance && currentPath.length == 0) {
        ((void(*)(id, SEL, id))objc_msgSend)(self,
            NSSelectorFromString(@"setCurrentPath:"), root);
        NSLog(@"[DeviceStorage] initialized empty browser path to %@", root);
    }

    // Older Filza state restoration can preserve the navigation title even
    // after the path has been repaired, so replace that presentation-only
    // residue as well.
    UINavigationItem *item = [self respondsToSelector:@selector(navigationItem)]
        ? ((id(*)(id, SEL))objc_msgSend)(self, @selector(navigationItem)) : nil;
    if ([item.title isEqualToString:@"MCM Containers"])
        item.title = @"Device Storage";

    SEL visiblePathSelector = NSSelectorFromString(@"currentPath");
    NSString *visiblePath = [self respondsToSelector:visiblePathSelector]
        ? ((id(*)(id, SEL))objc_msgSend)(self, visiblePathSelector) : redirected;
    PBWallpaperConfigureBrowser(self, visiblePath);

    // State restoration can leave the browser's table model empty even after
    // its path is correct. Reload on the next main-loop turn, after the view
    // hierarchy and browser view have finished appearing.
    dispatch_async(dispatch_get_main_queue(), ^{
        SEL currentSelector = NSSelectorFromString(@"currentPath");
        NSString *visiblePath = [self respondsToSelector:currentSelector]
            ? ((id(*)(id, SEL))objc_msgSend)(self, currentSelector) : nil;
        NSString *visibleRoot = MCMFilzaVirtualRoot();
        BOOL visibleInsideRoot = [visiblePath isEqualToString:visibleRoot] ||
            [visiblePath hasPrefix:[visibleRoot stringByAppendingString:@"/"]];
        SEL loadSelector = NSSelectorFromString(@"doLoadingPage");
        if (visibleInsideRoot && [self respondsToSelector:loadSelector]) {
            ((void(*)(id, SEL))objc_msgSend)(self, loadSelector);
            NSLog(@"[DeviceStorage] reloaded visible browser path %@", visiblePath);
        }
    });
}

static int hook_spawnRoot_args_pid(id self, SEL _cmd, id path, id args, int *pid) {
    if (pid) *pid = 0;
    return -1;
}

static id hook_sendObjectWithReplySync(id self, SEL _cmd, id msg) {
    return (id)xpc_null_create();
}

static id hook_sendObjectWithReplySync_fd(id self, SEL _cmd, id msg, int *fd) {
    if (fd) *fd = -1;
    return (id)xpc_null_create();
}

static id hook_sendObjectWithReplySync_fd_logintty(id self, SEL _cmd, id msg, int *fd, BOOL logintty) {
    if (fd) *fd = -1;
    return (id)xpc_null_create();
}

static void hook_sendObjectNoReply(id self, SEL _cmd, id msg) {}

static void hook_sendObjectWithReplyAsync(id self, SEL _cmd, id msg, id queue, id completion) {
    if (completion) { void (^block)(id) = completion; block(nil); }
}

#pragma mark - Zip/Unzip via minizip C API (linked in Filza binary)

// minizip C functions — statically linked in Filza, resolve via dlsym at runtime
#include <dlfcn.h>
typedef void* zipFile64;
typedef void* unzFile64;

// Function pointer types
static zipFile64 (*p_zipOpen64)(const char*, int);
static int (*p_zipOpenNewFileInZip64)(zipFile64, const char*, const void*, const void*, unsigned, const void*, unsigned, const char*, int, int, int);
static int (*p_zipWriteInFileInZip)(zipFile64, const void*, unsigned);
static int (*p_zipCloseFileInZip)(zipFile64);
static int (*p_zipClose)(zipFile64, const char*);
static unzFile64 (*p_unzOpen64)(const char*);
static int (*p_unzGoToFirstFile)(unzFile64);
static int (*p_unzGoToNextFile)(unzFile64);
static int (*p_unzGetCurrentFileInfo64)(unzFile64, void*, char*, unsigned long, void*, unsigned long, char*, unsigned long);
static int (*p_unzOpenCurrentFilePassword)(unzFile64, const char*);
static int (*p_unzReadCurrentFile)(unzFile64, void*, unsigned);
static int (*p_unzCloseCurrentFile)(unzFile64);
static int (*p_unzClose)(unzFile64);

static bool g_minizipLoaded = false;
static void loadMinizip(void) {
    if (g_minizipLoaded) return;
    // RTLD_DEFAULT searches all loaded images including Filza's statically linked minizip
    p_zipOpen64 = dlsym(RTLD_DEFAULT, "zipOpen64");
    p_zipOpenNewFileInZip64 = dlsym(RTLD_DEFAULT, "zipOpenNewFileInZip64");
    p_zipWriteInFileInZip = dlsym(RTLD_DEFAULT, "zipWriteInFileInZip");
    p_zipCloseFileInZip = dlsym(RTLD_DEFAULT, "zipCloseFileInZip");
    p_zipClose = dlsym(RTLD_DEFAULT, "zipClose");
    p_unzOpen64 = dlsym(RTLD_DEFAULT, "unzOpen64");
    p_unzGoToFirstFile = dlsym(RTLD_DEFAULT, "unzGoToFirstFile");
    p_unzGoToNextFile = dlsym(RTLD_DEFAULT, "unzGoToNextFile");
    p_unzGetCurrentFileInfo64 = dlsym(RTLD_DEFAULT, "unzGetCurrentFileInfo64");
    p_unzOpenCurrentFilePassword = dlsym(RTLD_DEFAULT, "unzOpenCurrentFilePassword");
    p_unzReadCurrentFile = dlsym(RTLD_DEFAULT, "unzReadCurrentFile");
    p_unzCloseCurrentFile = dlsym(RTLD_DEFAULT, "unzCloseCurrentFile");
    p_unzClose = dlsym(RTLD_DEFAULT, "unzClose");
    g_minizipLoaded = (p_zipOpen64 && p_unzOpen64);
    NSLog(@"[Tweak] minizip loaded: %d (zip=%p unz=%p)", g_minizipLoaded, p_zipOpen64, p_unzOpen64);
}

static IMP orig_ZipFiles = NULL, orig_unZipFile = NULL, orig_unZipFilePassword = NULL;

// Recursively add files to a zip archive using minizip C API
static void addFileToZip(zipFile64 zf, NSString *basePath, NSString *relativePath) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *fullPath = [basePath stringByAppendingPathComponent:relativePath];
    BOOL isDir = NO;
    [fm fileExistsAtPath:fullPath isDirectory:&isDir];
    if (isDir) {
        // Add directory entry
        NSString *dirEntry = [relativePath stringByAppendingString:@"/"];
        p_zipOpenNewFileInZip64(zf, dirEntry.UTF8String, NULL, NULL, 0, NULL, 0, NULL, 0, 0, 0);
        p_zipCloseFileInZip(zf);
        for (NSString *item in [fm contentsOfDirectoryAtPath:fullPath error:nil])
            addFileToZip(zf, basePath, [relativePath stringByAppendingPathComponent:item]);
    } else {
        NSData *data = [NSData dataWithContentsOfFile:fullPath];
        if (!data) return;
        // Z_DEFLATED=8, Z_DEFAULT_COMPRESSION=-1
        p_zipOpenNewFileInZip64(zf, relativePath.UTF8String, NULL, NULL, 0, NULL, 0, NULL, 8, -1, data.length > 0xFFFFFFFF);
        p_zipWriteInFileInZip(zf, data.bytes, (unsigned int)data.length);
        p_zipCloseFileInZip(zf);
    }
}

// Hook: -[Zipper ZipFiles:toFilePath:currentDirectory:]
static id hook_ZipFiles(id self, SEL _cmd, id files, id toFilePath, id currentDirectory) {
    @try {
        loadMinizip();
        if (!g_minizipLoaded) return orig_ZipFiles ? ((id(*)(id,SEL,id,id,id))orig_ZipFiles)(self, _cmd, files, toFilePath, currentDirectory) : nil;
        zipFile64 zf = p_zipOpen64(((NSString *)toFilePath).UTF8String, 0); // APPEND_STATUS_CREATE=0
        if (!zf) { NSLog(@"[Tweak] zipOpen64 failed"); return nil; }

        for (id fi in files) {
            NSString *fn = [fi performSelector:NSSelectorFromString(@"fileName")];
            if (fn) addFileToZip(zf, currentDirectory, fn);
        }
        p_zipClose(zf, NULL);

        // Return FileItem if zip was created (matching original behavior)
        if ([[NSFileManager defaultManager] fileExistsAtPath:toFilePath]) {
            Class FI = NSClassFromString(@"FileItem");
            if (FI) {
                id item = [[FI alloc] init];
                ((void(*)(id,SEL,id,id))objc_msgSend)(item, NSSelectorFromString(@"setFilePath:attribute:"), toFilePath, nil);
                return item;
            }
        }
        return nil;
    } @catch (NSException *e) { NSLog(@"[Tweak] Zip error: %@", e); return nil; }
}

// Hook: -[Zipper unZipFile:toPath:currentDirectory:outMessage:]
static id hook_unZipFile(id self, SEL _cmd, id zipPath, id toPath, id currentDir, id *outMsg) {
    @try {
        loadMinizip();
        if (!g_minizipLoaded) return orig_unZipFile ? ((id(*)(id,SEL,id,id,id,id*))orig_unZipFile)(self, _cmd, zipPath, toPath, currentDir, outMsg) : nil;
        // zipPath is a FileItem, get the actual path string
        NSString *zipPathStr = zipPath;
        if ([zipPath respondsToSelector:NSSelectorFromString(@"filePath")])
            zipPathStr = [zipPath performSelector:NSSelectorFromString(@"filePath")];

        unzFile64 uf = p_unzOpen64(((NSString *)zipPathStr).UTF8String);
        if (!uf) { if (outMsg) *outMsg = @"Failed to open zip"; return nil; }

        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *destPath = toPath;
        [fm createDirectoryAtPath:destPath withIntermediateDirectories:YES attributes:nil error:nil];

        char filename[512];
        uint8_t buf[32768];
        int ret = p_unzGoToFirstFile(uf);
        while (ret == 0) {
            p_unzGetCurrentFileInfo64(uf, NULL, filename, sizeof(filename), NULL, 0, NULL, 0);
            NSString *name = [NSString stringWithUTF8String:filename];
            NSString *fullPath = [destPath stringByAppendingPathComponent:name];

            if ([name hasSuffix:@"/"]) {
                [fm createDirectoryAtPath:fullPath withIntermediateDirectories:YES attributes:nil error:nil];
            } else {
                [fm createDirectoryAtPath:[fullPath stringByDeletingLastPathComponent]
                  withIntermediateDirectories:YES attributes:nil error:nil];

                if (p_unzOpenCurrentFilePassword(uf, NULL) == 0) {
                    NSMutableData *fileData = [NSMutableData data];
                    int bytesRead;
                    while ((bytesRead = p_unzReadCurrentFile(uf, buf, sizeof(buf))) > 0)
                        [fileData appendBytes:buf length:bytesRead];
                    p_unzCloseCurrentFile(uf);
                    [fileData writeToFile:fullPath atomically:YES];
                }
            }
            ret = p_unzGoToNextFile(uf);
        }
        p_unzClose(uf);

        if (outMsg) *outMsg = @"OK";

        // Return array of extracted FileItems (matching original behavior)
        NSArray *contents = [fm contentsOfDirectoryAtPath:destPath error:nil];
        if (contents.count > 0) {
            Class FI = NSClassFromString(@"FileItem");
            if (FI) {
                id item = [[FI alloc] init];
                ((void(*)(id,SEL,id,id))objc_msgSend)(item, NSSelectorFromString(@"setFilePath:attribute:"), destPath, nil);
                return @[item];
            }
        }
        return nil;
    } @catch (NSException *e) { NSLog(@"[Tweak] Unzip error: %@", e); if (outMsg) *outMsg = [e reason]; return nil; }
}

// Hook: -[Zipper unZipFile:toPath:currentDirectory:withPassword:outMessage:]
static id hook_unZipFilePassword(id self, SEL _cmd, id zipPath, id toPath, id currentDir, id password, id *outMsg) {
    return hook_unZipFile(self, @selector(unZipFile:toPath:currentDirectory:outMessage:), zipPath, toPath, currentDir, outMsg);
}

#pragma mark - Apps Manager Fix

// Full Apps Manager fix for sandbox-escaped devices.
// LSApplicationProxy properties (localizedName, iconsDictionary, dataContainerURL,
// staticDiskUsage, etc.) return nil without entitlements.
// Fix: Hook setAppProxy: to populate from Info.plist + filesystem directly.
// Hook calculateDiskUsage to walk bundle dirs. Hook tap to use bundle path fallback.

@interface LSApplicationProxy : NSObject
+ (id)applicationProxyForIdentifier:(NSString *)bundleId;
- (NSString *)applicationIdentifier;
- (NSURL *)bundleURL;
- (NSURL *)dataContainerURL;
- (NSString *)localizedName;
- (NSString *)bundleVersion;
- (NSString *)shortVersionString;
- (NSString *)applicationType;
- (NSDictionary *)iconsDictionary;
- (NSNumber *)staticDiskUsage;
- (NSNumber *)dynamicDiskUsage;
@end

@interface LSApplicationWorkspace : NSObject
+ (id)defaultWorkspace;
- (NSArray *)allApplications;
@end

// --- Helper: find app bundle path from bundleId ---
static NSString *findBundlePath(NSString *bundleId) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *appsDir = @"/var/containers/Bundle/Application";
    for (NSString *uuid in [fm contentsOfDirectoryAtPath:appsDir error:nil]) {
        NSString *uuidPath = [appsDir stringByAppendingPathComponent:uuid];
        for (NSString *item in [fm contentsOfDirectoryAtPath:uuidPath error:nil]) {
            if (![item hasSuffix:@".app"]) continue;
            NSString *appPath = [uuidPath stringByAppendingPathComponent:item];
            NSString *plist = [appPath stringByAppendingPathComponent:@"Info.plist"];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plist];
            if ([info[@"CFBundleIdentifier"] isEqualToString:bundleId]) return appPath;
        }
    }
    // System apps
    for (NSString *item in [fm contentsOfDirectoryAtPath:@"/Applications" error:nil]) {
        if (![item hasSuffix:@".app"]) continue;
        NSString *appPath = [@"/Applications" stringByAppendingPathComponent:item];
        NSString *plist = [appPath stringByAppendingPathComponent:@"Info.plist"];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plist];
        if ([info[@"CFBundleIdentifier"] isEqualToString:bundleId]) return appPath;
    }
    return nil;
}

// --- Helper: find data container path ---
static NSString *findDataContainer(NSString *bundleId) {
    NSString *error = nil;
    NSString *path = MCMFilzaDataContainerPath(bundleId, &error);
    if (!path) NSLog(@"[MCMFilza] data lookup failed id=%@ detail=%@", bundleId, error);
    return path;
}

// --- Helper: find best icon in bundle ---
static NSString *findIconPath(NSString *bundlePath, NSDictionary *infoPlist) {
    NSFileManager *fm = [NSFileManager defaultManager];
    // Try CFBundleIcons -> CFBundlePrimaryIcon -> CFBundleIconFiles
    NSDictionary *icons = infoPlist[@"CFBundleIcons"];
    NSDictionary *primary = icons[@"CFBundlePrimaryIcon"];
    NSArray *iconFiles = primary[@"CFBundleIconFiles"];
    if (!iconFiles) iconFiles = infoPlist[@"CFBundleIconFiles"];

    NSString *bestIcon = nil;
    unsigned long long bestSize = 0;
    if (iconFiles.count > 0) {
        for (NSString *iconName in iconFiles) {
            // Try exact name and @2x/@3x variants
            NSArray *variants = @[
                iconName,
                [iconName stringByAppendingString:@"@2x.png"],
                [iconName stringByAppendingString:@"@3x.png"],
                [iconName stringByAppendingString:@"@2x~iphone.png"],
                [iconName stringByAppendingString:@"@3x~iphone.png"],
                [NSString stringWithFormat:@"%@.png", iconName],
            ];
            for (NSString *v in variants) {
                NSString *full = [bundlePath stringByAppendingPathComponent:v];
                NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
                unsigned long long sz = [attrs fileSize];
                if (sz > bestSize) { bestSize = sz; bestIcon = full; }
            }
        }
    }

    // Fallback: scan for Icon*.png / AppIcon*.png
    if (!bestIcon) {
        for (NSString *file in [fm contentsOfDirectoryAtPath:bundlePath error:nil]) {
            if (([file hasPrefix:@"Icon"] || [file hasPrefix:@"icon"] || [file hasPrefix:@"AppIcon"])
                && [file hasSuffix:@".png"]) {
                NSString *full = [bundlePath stringByAppendingPathComponent:file];
                NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
                unsigned long long sz = [attrs fileSize];
                if (sz > bestSize) { bestSize = sz; bestIcon = full; }
            }
        }
    }
    return bestIcon;
}

// --- Hook: allApplications fallback ---
static IMP orig_allApplications = NULL;
static id hook_allApplications(id self, SEL _cmd) {
    NSArray *origResult = ((id(*)(id,SEL))orig_allApplications)(self, _cmd);
    if (origResult && origResult.count > 0) return origResult;

    NSMutableArray *apps = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    void (^scanDir)(NSString *) = ^(NSString *dir) {
        for (NSString *uuid in [fm contentsOfDirectoryAtPath:dir error:nil]) {
            NSString *uuidPath = [dir stringByAppendingPathComponent:uuid];
            for (NSString *item in [fm contentsOfDirectoryAtPath:uuidPath error:nil]) {
                if (![item hasSuffix:@".app"]) continue;
                NSString *plist = [[uuidPath stringByAppendingPathComponent:item] stringByAppendingPathComponent:@"Info.plist"];
                NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plist];
                NSString *bid = info[@"CFBundleIdentifier"];
                if (bid) {
                    id proxy = [NSClassFromString(@"LSApplicationProxy") applicationProxyForIdentifier:bid];
                    if (proxy) [apps addObject:proxy];
                }
            }
        }
    };
    scanDir(@"/var/containers/Bundle/Application");
    // System apps (flat structure)
    for (NSString *item in [fm contentsOfDirectoryAtPath:@"/Applications" error:nil]) {
        if (![item hasSuffix:@".app"]) continue;
        NSString *plist = [[@"/Applications" stringByAppendingPathComponent:item] stringByAppendingPathComponent:@"Info.plist"];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plist];
        NSString *bid = info[@"CFBundleIdentifier"];
        if (bid) {
            id proxy = [NSClassFromString(@"LSApplicationProxy") applicationProxyForIdentifier:bid];
            if (proxy) [apps addObject:proxy];
        }
    }
    NSLog(@"[Tweak] Apps Manager: found %lu apps via filesystem", (unsigned long)apps.count);
    return apps;
}

// --- Hook: setAppProxy: — populate name, icon, paths from filesystem ---
static IMP orig_setAppProxy = NULL;
static void hook_setAppProxy(id self, SEL _cmd, id proxy) {
    // Call original first
    ((void(*)(id,SEL,id))orig_setAppProxy)(self, _cmd, proxy);

    NSString *bundleId = [self performSelector:NSSelectorFromString(@"bundleId")];
    if (!bundleId) return;

    NSString *bundlePath = nil;
    NSString *currentFilePath = [self performSelector:NSSelectorFromString(@"filePath")];

    // Fix filePath if missing or inaccessible
    if (!currentFilePath || currentFilePath.length == 0) {
        NSURL *bundleURL = [proxy bundleURL];
        if (bundleURL) bundlePath = [bundleURL path];
        if (!bundlePath) bundlePath = findBundlePath(bundleId);
        if (bundlePath) {
            ((void(*)(id,SEL,id))objc_msgSend)(self, NSSelectorFromString(@"setFilePath:"), bundlePath);
        }
    } else {
        bundlePath = currentFilePath;
    }

    // Fix display name — always prefer Info.plist name over proxy
    if (bundlePath) {
        NSString *plist = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plist];
        NSString *name = info[@"CFBundleDisplayName"];
        if (!name) name = info[@"CFBundleName"];
        if (!name) name = [proxy localizedName];
        if (!name) name = bundleId;
        ((void(*)(id,SEL,id))objc_msgSend)(self, NSSelectorFromString(@"setAFileName:"), name);
    }

    // Fix icon path
    NSString *iconPath = ((id(*)(id,SEL))objc_msgSend)(self, NSSelectorFromString(@"iconPath"));
    if (!iconPath && bundlePath) {
        NSString *plist = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plist];
        NSString *found = findIconPath(bundlePath, info);
        if (found) {
            ((void(*)(id,SEL,id))objc_msgSend)(self, NSSelectorFromString(@"setIconPath:"), found);
        }
    }

    // Fix document path
    NSString *docPath = ((id(*)(id,SEL))objc_msgSend)(self, NSSelectorFromString(@"documentPath"));
    if (!docPath) {
        NSURL *dataURL = [proxy dataContainerURL];
        if (dataURL) docPath = [dataURL path];
        if (!docPath) docPath = findDataContainer(bundleId);
        if (docPath) {
            ((void(*)(id,SEL,id))objc_msgSend)(self, NSSelectorFromString(@"setDocumentPath:"), docPath);
        }
    }

    // Fix version
    NSString *ver = ((id(*)(id,SEL))objc_msgSend)(self, NSSelectorFromString(@"version"));
    if (!ver || ver.length == 0) {
        ver = [proxy bundleVersion];
        if (!ver && bundlePath) {
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                [bundlePath stringByAppendingPathComponent:@"Info.plist"]];
            ver = info[@"CFBundleShortVersionString"];
            if (!ver) ver = info[@"CFBundleVersion"];
        }
        if (ver) ((void(*)(id,SEL,id))objc_msgSend)(self, NSSelectorFromString(@"setVersion:"), ver);
    }
}


// --- Hook: browserView:didSelectItemAtIndexPath: — fallback to bundle path ---
static IMP orig_didSelectItem = NULL;
static void hook_didSelectItem(id self, SEL _cmd, id browserView, id indexPath) {
    // Get the selected item
    id fileList = ((id(*)(id,SEL))objc_msgSend)(self, NSSelectorFromString(@"fileList"));
    NSUInteger row = ((NSUInteger(*)(id,SEL))objc_msgSend)(indexPath, @selector(row));
    id item = ((id(*)(id,SEL,NSUInteger))objc_msgSend)(fileList, NSSelectorFromString(@"objectAtIndex:"), row);

    NSString *docPath = ((id(*)(id,SEL))objc_msgSend)(item, NSSelectorFromString(@"documentPath"));
    NSString *bundlePath = [item performSelector:NSSelectorFromString(@"filePath")];

    // If documentPath is nil but bundlePath exists, set documentPath to bundlePath
    // so the original handler can navigate there instead of showing error
    if (!docPath && bundlePath) {
        ((void(*)(id,SEL,id))objc_msgSend)(item, NSSelectorFromString(@"setDocumentPath:"), bundlePath);
    }

    // Call original
    ((void(*)(id,SEL,id,id))orig_didSelectItem)(self, _cmd, browserView, indexPath);
}

#pragma mark - License / Integrity Bypass

// Suppress "Main binary was modified" and "Not activated" alerts.
// +[TGAlertController showAlertWithTitle:text:cancelButton:otherButtons:completion:]
// checks the text parameter; if it's the integrity/activation alert, swallow it.
static IMP orig_showAlert = NULL;
static id hook_showAlertWithTitle(id self, SEL _cmd, id title, id text, id cancelButton, id otherButtons, id completion) {
    NSString *textStr = text;
    if ([textStr isKindOfClass:[NSString class]]) {
        if ([textStr containsString:@"binary was modified"] ||
            [textStr containsString:@"reinstall Filza"]) {
            NSLog(@"[Tweak] Suppressed integrity alert");
            return nil;
        }
    }
    // Pass through all other alerts
    return ((id(*)(id,SEL,id,id,id,id,id))orig_showAlert)(self, _cmd, title, text, cancelButton, otherButtons, completion);
}

// Suppress activation nag: -[NewActivationViewController viewDidLoad]
// Just dismiss the VC immediately so the user never sees it.
static IMP orig_activationViewDidLoad = NULL;
static void hook_activationViewDidLoad(id self, SEL _cmd) {
    // Call original to set up the VC, then immediately dismiss
    ((void(*)(id,SEL))orig_activationViewDidLoad)(self, _cmd);
    dispatch_async(dispatch_get_main_queue(), ^{
        ((void(*)(id,SEL,BOOL,id))objc_msgSend)(self,
            NSSelectorFromString(@"dismissViewControllerAnimated:completion:"), NO, nil);
    });
    NSLog(@"[Tweak] Suppressed activation nag");
}

#pragma mark - MCM-aware local file operations

static void setPastePOSIXError(NSError **error, int code,
                               NSString *operation, NSString *path) {
    if (!error) return;
    NSString *description = [NSString stringWithFormat:@"%@ failed for %@: %s",
        operation, path, strerror(code)];
    *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey: description}];
}

static BOOL directCopyItem(NSString *source, NSString *destination, NSError **error);

static BOOL directCopyRegularFile(NSString *source, NSString *destination,
                                  mode_t mode, NSError **error) {
    int input = open(source.fileSystemRepresentation,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (input < 0) {
        setPastePOSIXError(error, errno, @"open source", source);
        return NO;
    }
    int output = open(destination.fileSystemRepresentation,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        mode & 0777 ?: 0600);
    if (output < 0) {
        int saved = errno;
        close(input);
        setPastePOSIXError(error, saved, @"create destination", destination);
        return NO;
    }

    BOOL success = YES;
    uint8_t buffer[64 * 1024];
    while (success) {
        ssize_t count = read(input, buffer, sizeof(buffer));
        if (count == 0) break;
        if (count < 0) {
            if (errno == EINTR) continue;
            setPastePOSIXError(error, errno, @"read", source);
            success = NO;
            break;
        }
        ssize_t offset = 0;
        while (offset < count) {
            ssize_t written = write(output, buffer + offset, (size_t)(count - offset));
            if (written < 0 && errno == EINTR) continue;
            if (written <= 0) {
                setPastePOSIXError(error, written < 0 ? errno : EIO,
                    @"write", destination);
                success = NO;
                break;
            }
            offset += written;
        }
    }
    if (success) fsync(output);
    close(output);
    close(input);
    if (!success) unlink(destination.fileSystemRepresentation);
    return success;
}

static BOOL directCopyDirectory(NSString *source, NSString *destination,
                                mode_t mode, NSError **error) {
    if (mkdir(destination.fileSystemRepresentation, mode & 0777 ?: 0700) != 0) {
        setPastePOSIXError(error, errno, @"create directory", destination);
        return NO;
    }
    DIR *directory = opendir(source.fileSystemRepresentation);
    if (!directory) {
        int saved = errno;
        rmdir(destination.fileSystemRepresentation);
        setPastePOSIXError(error, saved, @"open directory", source);
        return NO;
    }

    BOOL success = YES;
    struct dirent *entry = NULL;
    while (success && (entry = readdir(directory)) != NULL) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        NSString *name = [NSFileManager.defaultManager
            stringWithFileSystemRepresentation:entry->d_name
            length:strlen(entry->d_name)];
        if (!name) {
            setPastePOSIXError(error, EILSEQ, @"decode filename", source);
            success = NO;
            break;
        }
        success = directCopyItem([source stringByAppendingPathComponent:name],
            [destination stringByAppendingPathComponent:name], error);
    }
    closedir(directory);
    if (!success)
        [NSFileManager.defaultManager removeItemAtPath:destination error:nil];
    return success;
}

static BOOL directCopySymbolicLink(NSString *source, NSString *destination,
                                   NSError **error) {
    char target[PATH_MAX] = {0};
    ssize_t length = readlink(source.fileSystemRepresentation,
        target, sizeof(target) - 1);
    if (length < 0) {
        setPastePOSIXError(error, errno, @"read symbolic link", source);
        return NO;
    }
    target[length] = '\0';
    if (symlink(target, destination.fileSystemRepresentation) != 0) {
        setPastePOSIXError(error, errno, @"create symbolic link", destination);
        return NO;
    }
    return YES;
}

static BOOL directCopyItem(NSString *source, NSString *destination, NSError **error) {
    struct stat status = {0};
    if (lstat(source.fileSystemRepresentation, &status) != 0) {
        setPastePOSIXError(error, errno, @"inspect source", source);
        return NO;
    }
    if (S_ISREG(status.st_mode))
        return directCopyRegularFile(source, destination, status.st_mode, error);
    if (S_ISDIR(status.st_mode))
        return directCopyDirectory(source, destination, status.st_mode, error);
    if (S_ISLNK(status.st_mode))
        return directCopySymbolicLink(source, destination, error);
    setPastePOSIXError(error, ENOTSUP, @"copy unsupported item", source);
    return NO;
}

static NSString *localPathFromPasteboardValue(id value) {
    if ([value isKindOfClass:NSURL.class] && [(NSURL *)value isFileURL])
        return [(NSURL *)value path];
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *string = value;
    if (string.isAbsolutePath) return string;
    NSURL *URL = [NSURL URLWithString:string];
    if (URL.isFileURL) return URL.path;

    Class preferencesClass = NSClassFromString(@"TGPreferences");
    id preferences = [preferencesClass respondsToSelector:@selector(sharedInstance)]
        ? ((id(*)(id, SEL))objc_msgSend)(preferencesClass, @selector(sharedInstance)) : nil;
    SEL selector = NSSelectorFromString(@"urlFromString:");
    id parsed = [preferences respondsToSelector:selector]
        ? ((id(*)(id, SEL, id))objc_msgSend)(preferences, selector, string) : nil;
    return [parsed isKindOfClass:NSURL.class] && [(NSURL *)parsed isFileURL]
        ? [(NSURL *)parsed path] : nil;
}

static NSString *uniquePasteDestination(NSString *directory, NSString *name) {
    if (name.length == 0 || [name isEqualToString:@"."] ||
        [name isEqualToString:@".."] || [name containsString:@"/"]) return nil;
    NSString *candidate = [directory stringByAppendingPathComponent:name];
    struct stat status = {0};
    if (lstat(candidate.fileSystemRepresentation, &status) != 0 && errno == ENOENT)
        return candidate;

    NSString *extension = name.pathExtension;
    NSString *stem = extension.length ? name.stringByDeletingPathExtension : name;
    for (NSUInteger index = 1; index <= 999; index++) {
        NSString *suffix = index == 1 ? @" copy"
            : [NSString stringWithFormat:@" copy %lu", (unsigned long)index];
        NSString *copyName = [stem stringByAppendingString:suffix];
        if (extension.length) copyName = [copyName stringByAppendingPathExtension:extension];
        candidate = [directory stringByAppendingPathComponent:copyName];
        if (lstat(candidate.fileSystemRepresentation, &status) != 0 && errno == ENOENT)
            return candidate;
    }
    return nil;
}

static BOOL pasteDestinationIsInsideSource(NSString *source, NSString *destinationDirectory) {
    struct stat status = {0};
    if (lstat(source.fileSystemRepresentation, &status) != 0 || !S_ISDIR(status.st_mode))
        return NO;
    char sourceReal[PATH_MAX] = {0};
    char destinationReal[PATH_MAX] = {0};
    if (!realpath(source.fileSystemRepresentation, sourceReal) ||
        !realpath(destinationDirectory.fileSystemRepresentation, destinationReal)) return NO;
    NSString *sourcePath = [NSString stringWithUTF8String:sourceReal];
    NSString *destinationPath = [NSString stringWithUTF8String:destinationReal];
    return [destinationPath isEqualToString:sourcePath] ||
        [destinationPath hasPrefix:[sourcePath stringByAppendingString:@"/"]];
}

static void showPasteFailure(UIViewController *controller, NSArray<NSError *> *errors) {
    if (errors.count == 0) return;
    NSString *message = errors.firstObject.localizedDescription ?: @"Paste failed";
    if (errors.count > 1)
        message = [NSString stringWithFormat:@"%lu items failed.\n%@",
            (unsigned long)errors.count, message];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Paste failed"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
        style:UIAlertActionStyleDefault handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}

static NSArray *selectedFileItems(id controller, NSArray *indexPaths) {
    SEL fileListSelector = NSSelectorFromString(@"fileList");
    NSArray *fileList = [controller respondsToSelector:fileListSelector]
        ? ((id(*)(id, SEL))objc_msgSend)(controller, fileListSelector) : nil;
    if (![fileList isKindOfClass:NSArray.class] ||
        ![indexPaths isKindOfClass:NSArray.class]) return @[];

    NSMutableArray *items = [NSMutableArray array];
    for (id value in indexPaths) {
        if (![value isKindOfClass:NSIndexPath.class]) continue;
        NSInteger row = [(NSIndexPath *)value row];
        if (row >= 0 && (NSUInteger)row < fileList.count)
            [items addObject:fileList[(NSUInteger)row]];
    }
    return items;
}

static NSString *fileItemPath(id item) {
    SEL selector = NSSelectorFromString(@"filePath");
    id value = [item respondsToSelector:selector]
        ? ((id(*)(id, SEL))objc_msgSend)(item, selector) : nil;
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static BOOL fileItemsUseMCMOperations(NSArray *items) {
    if (items.count == 0) return NO;
    for (id item in items) {
        NSString *path = fileItemPath(item);
        if (!path.length || !MCMFilzaPathHasActiveLease(path)) return NO;
    }
    return YES;
}

static void showDeleteFailure(UIViewController *controller,
                              NSArray<NSError *> *errors) {
    if (errors.count == 0 || ![controller isKindOfClass:UIViewController.class]) return;
    NSString *message = errors.firstObject.localizedDescription ?: @"Delete failed";
    if (errors.count > 1)
        message = [NSString stringWithFormat:@"%lu items failed.\n%@",
            (unsigned long)errors.count, message];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Delete failed"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
        style:UIAlertActionStyleDefault handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}

static void reloadFileSystemController(id controller) {
    SEL loadSelector = NSSelectorFromString(@"doLoadingPage");
    if ([controller respondsToSelector:loadSelector])
        ((void(*)(id, SEL))objc_msgSend)(controller, loadSelector);
}

static void showArchiveResult(UIViewController *controller, NSUInteger moved,
                              NSArray<NSError *> *errors) {
    if (![controller isKindOfClass:UIViewController.class]) return;
    NSString *title = moved > 0
        ? (errors.count ? @"Archive completed with errors" : @"Archived")
        : @"Archive failed";
    NSString *message = moved == 1
        ? @"Moved 1 item to Documents/FilzaSlop Archive."
        : [NSString stringWithFormat:@"Moved %lu items to Documents/FilzaSlop Archive.",
            (unsigned long)moved];
    if (errors.count)
        message = [message stringByAppendingFormat:@"\n\n%@",
            errors.firstObject.localizedDescription];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
        style:UIAlertActionStyleDefault handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}

static NSString *uniqueArchiveDestination(NSString *directory, NSString *name) {
    NSFileManager *manager = NSFileManager.defaultManager;
    if (!name.length) name = @"Archived Item";
    NSString *base = name.stringByDeletingPathExtension;
    NSString *extension = name.pathExtension;
    if (!base.length) base = @"Archived Item";
    for (NSUInteger suffix = 0; suffix < 10000; suffix++) {
        NSString *candidateName = suffix == 0 ? name
            : [NSString stringWithFormat:@"%@ %lu", base,
                (unsigned long)(suffix + 1)];
        if (suffix > 0 && extension.length)
            candidateName = [candidateName stringByAppendingPathExtension:extension];
        NSString *candidate = [directory stringByAppendingPathComponent:candidateName];
        if (![manager fileExistsAtPath:candidate]) return candidate;
    }
    return nil;
}

static dispatch_queue_t archiveQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("local.filzamod.container-archive",
                                      DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static BOOL pathIsInsideArchive(NSString *path) {
    if (!path.length) return NO;
    NSString *candidate = [[path stringByStandardizingPath]
        stringByResolvingSymlinksInPath];
    NSString *archive = [[MCMFilzaArchivePath() stringByStandardizingPath]
        stringByResolvingSymlinksInPath];
    return [candidate isEqualToString:archive] ||
        [candidate hasPrefix:[archive stringByAppendingString:@"/"]];
}

static void archiveSelectedItems(id controller, NSArray *indexPaths) {
    MCMFilzaStart();
    NSArray *items = selectedFileItems(controller, indexPaths);
    if (items.count == 0) {
        NSError *error = nil;
        setPastePOSIXError(&error, EINVAL, @"archive", @"selection");
        showArchiveResult(controller, 0, @[error]);
        return;
    }

    NSArray *capturedItems = [items copy];
    UIViewController *viewController = controller;
    dispatch_async(archiveQueue(), ^{
        NSFileManager *manager = NSFileManager.defaultManager;
        NSString *archive = MCMFilzaArchivePath();
        NSMutableArray<NSError *> *errors = [NSMutableArray array];
        NSError *directoryError = nil;
        [manager createDirectoryAtPath:archive withIntermediateDirectories:YES
                            attributes:@{NSFilePosixPermissions: @0700}
                                 error:&directoryError];
        if (directoryError) [errors addObject:directoryError];

        NSUInteger moved = 0;
        if (!directoryError) for (id item in capturedItems) {
            NSString *source = fileItemPath(item);
            NSError *error = nil;
            if (!source.length || !MCMFilzaPathHasActiveLease(source)) {
                setPastePOSIXError(&error, EACCES, @"archive",
                                   source ?: @"(unknown)");
            } else if (pathIsInsideArchive(source)) {
                error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL
                    userInfo:@{NSLocalizedDescriptionKey:
                        [NSString stringWithFormat:@"%@ is already in FilzaSlop Archive.",
                            source.lastPathComponent]}];
            } else {
                NSString *destination = uniqueArchiveDestination(
                    archive, source.lastPathComponent);
                if (!destination)
                    setPastePOSIXError(&error, EEXIST, @"archive", source);
                else if ([manager moveItemAtPath:source toPath:destination error:&error]) {
                    MCMFilzaRecordDeletedGeneratedPath(source);
                    moved++;
                    NSLog(@"[ContainerArchive] moved %@ -> %@", source, destination);
                }
            }
            if (error) {
                [errors addObject:error];
                NSLog(@"[ContainerArchive] failed source=%@ error=%@", source, error);
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            reloadFileSystemController(viewController);
            showArchiveResult(viewController, moved, errors);
            NSLog(@"[ContainerArchive] complete moved=%lu failed=%lu destination=%@",
                  (unsigned long)moved, (unsigned long)errors.count, archive);
        });
    });
}

static void showPermanentDeleteConfirmation(id controller, NSArray *indexPaths,
                                            NSUInteger itemCount) {
    if (![controller isKindOfClass:UIViewController.class]) return;
    NSArray *capturedIndexPaths = [indexPaths copy] ?: @[];
    __weak id weakController = controller;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        id activeController = weakController;
        if (![activeController isKindOfClass:UIViewController.class]) return;

        NSString *message = itemCount == 1
            ? @"This permanently deletes the item and cannot be undone. We recommend Archive first so you have a backup in Documents/FilzaSlop Archive."
            : @"This permanently deletes the items and cannot be undone. We recommend Archive first so you have backups in Documents/FilzaSlop Archive.";
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"Are you sure?" message:message
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Archive Instead"
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                id selectedController = weakController;
                if (selectedController)
                    archiveSelectedItems(selectedController, capturedIndexPaths);
            }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Delete Permanently"
            style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
                id selectedController = weakController;
                if (!selectedController) return;
                SEL eraseSelector = NSSelectorFromString(
                    @"doEraseSelectedIndexPaths:completion:");
                if (![selectedController respondsToSelector:eraseSelector]) return;
                void (^completion)(NSArray *) = ^(__unused NSArray *deleted) {
                    reloadFileSystemController(selectedController);
                };
                ((void(*)(id, SEL, id, id))objc_msgSend)(
                    selectedController, eraseSelector, capturedIndexPaths, completion);
            }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
            style:UIAlertActionStyleCancel handler:nil]];
        [(UIViewController *)activeController presentViewController:alert
            animated:YES completion:nil];
    });
}

static IMP orig_fileSystemPageDeleteAction = NULL;
static IMP orig_fileSystemDeleteSelectedItems = NULL;
static IMP orig_fileSystemDoTrashSelectedItems = NULL;
static IMP orig_fileSystemDoEraseSelectedItems = NULL;
static IMP parentFileSystemAskDeleteItems = NULL;
static IMP orig_pageAskDeleteItems = NULL;
static IMP orig_pageDoTrashSelectedItems = NULL;
static IMP orig_pageDoEraseSelectedItems = NULL;

// Filza's jailed filesystem subclass replaces delete, trash, and erase with
// no-ops. Show a clear permanent-delete warning for paths backed by an active
// MCM lease, then perform the operation in this process instead of the helper.
static NSUInteger hook_fileSystemPageDeleteAction(id self, SEL _cmd) {
    SEL selector = NSSelectorFromString(@"currentPath");
    NSString *path = [self respondsToSelector:selector]
        ? ((id(*)(id, SEL))objc_msgSend)(self, selector) : nil;
    if (MCMFilzaPathHasActiveLease(path)) return 0x8000;
    return orig_fileSystemPageDeleteAction
        ? ((NSUInteger(*)(id, SEL))orig_fileSystemPageDeleteAction)(self, _cmd)
        : 0x8000;
}

static void hook_fileSystemDeleteSelectedItems(id self, SEL _cmd) {
    SEL selectedSelector = NSSelectorFromString(@"indexPathsForSelectedItemsOrMenu");
    NSArray *indexPaths = [self respondsToSelector:selectedSelector]
        ? ((id(*)(id, SEL))objc_msgSend)(self, selectedSelector) : nil;
    if (!fileItemsUseMCMOperations(selectedFileItems(self, indexPaths))) {
        if (orig_fileSystemDeleteSelectedItems)
            ((void(*)(id, SEL))orig_fileSystemDeleteSelectedItems)(self, _cmd);
        return;
    }
    SEL askSelector = NSSelectorFromString(@"askDeleteItems:");
    if ([self respondsToSelector:askSelector])
        ((void(*)(id, SEL, id))objc_msgSend)(self, askSelector, indexPaths ?: @[]);
}

static void hook_fileSystemAskDeleteItems(id self, SEL _cmd, NSArray *indexPaths) {
    NSArray *items = selectedFileItems(self, indexPaths);
    if (!fileItemsUseMCMOperations(items)) {
        if (parentFileSystemAskDeleteItems)
            ((void(*)(id, SEL, id))parentFileSystemAskDeleteItems)(
                self, _cmd, indexPaths ?: @[]);
        return;
    }

    NSArray *capturedIndexPaths = [indexPaths copy] ?: @[];
    NSLog(@"[ContainerDelete] intercepted class=%@ items=%lu",
          NSStringFromClass([self class]), (unsigned long)items.count);

    NSString *message = items.count == 1
        ? @"FilzaSlop cannot use Filza's Trash here. Archive moves this item to Documents/FilzaSlop Archive. Delete Permanently cannot be undone."
        : @"FilzaSlop cannot use Filza's Trash here. Archive moves these items to Documents/FilzaSlop Archive. Delete Permanently cannot be undone.";
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:items.count == 1 ? @"Remove item?" : @"Remove items?"
        message:message preferredStyle:UIAlertControllerStyleActionSheet];

    __weak id weakController = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Archive"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            id controller = weakController;
            if (controller) archiveSelectedItems(controller, capturedIndexPaths);
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Delete Permanently"
        style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
            id controller = weakController;
            if (!controller) return;
            showPermanentDeleteConfirmation(controller, capturedIndexPaths,
                                            items.count);
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
        style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover && [self isKindOfClass:UIViewController.class]) {
        UIView *view = ((UIViewController *)self).view;
        popover.sourceView = view;
        popover.sourceRect = CGRectMake(CGRectGetMidX(view.bounds),
            CGRectGetMaxY(view.bounds), 1, 1);
        popover.permittedArrowDirections = 0;
    }
    if ([self isKindOfClass:UIViewController.class])
        [(UIViewController *)self presentViewController:sheet animated:YES completion:nil];
}

static void performPermanentDelete(id self, NSArray *indexPaths,
                                   void (^completion)(NSArray *)) {
    MCMFilzaStart();
    NSArray *items = selectedFileItems(self, indexPaths);

    NSMutableArray *deleted = [NSMutableArray array];
    NSMutableArray<NSError *> *errors = [NSMutableArray array];
    for (id item in items) {
        NSString *path = fileItemPath(item);
        NSError *error = nil;
        if (!path.length || !MCMFilzaPathHasActiveLease(path)) {
            setPastePOSIXError(&error, EACCES, @"delete", path ?: @"(unknown)");
        } else if ([NSFileManager.defaultManager removeItemAtPath:path error:&error]) {
            MCMFilzaRecordDeletedGeneratedPath(path);
            [deleted addObject:item];
            NSLog(@"[ContainerDelete] deleted %@", path);
        }
        if (error) {
            [errors addObject:error];
            NSLog(@"[ContainerDelete] failed path=%@ error=%@", path, error);
        }
    }
    if (completion) completion(deleted);
    showDeleteFailure(self, errors);
    NSLog(@"[ContainerDelete] complete deleted=%lu failed=%lu",
          (unsigned long)deleted.count, (unsigned long)errors.count);
}

static void hook_fileSystemDoTrashSelectedItems(id self, SEL _cmd,
                                                 NSArray *indexPaths,
                                                 void (^completion)(NSArray *)) {
    NSArray *items = selectedFileItems(self, indexPaths);
    if (!fileItemsUseMCMOperations(items)) {
        if (orig_fileSystemDoTrashSelectedItems)
            ((void(*)(id, SEL, id, id))orig_fileSystemDoTrashSelectedItems)(
                self, _cmd, indexPaths, completion);
        return;
    }
    hook_fileSystemAskDeleteItems(self, NSSelectorFromString(@"askDeleteItems:"),
                                  indexPaths ?: @[]);
    if (completion) completion(@[]);
}

static void hook_pageDoTrashSelectedItems(id self, SEL _cmd,
                                           NSArray *indexPaths,
                                           void (^completion)(NSArray *)) {
    NSArray *items = selectedFileItems(self, indexPaths);
    if (!fileItemsUseMCMOperations(items)) {
        if (orig_pageDoTrashSelectedItems)
            ((void(*)(id, SEL, id, id))orig_pageDoTrashSelectedItems)(
                self, _cmd, indexPaths, completion);
        return;
    }
    hook_fileSystemAskDeleteItems(self, NSSelectorFromString(@"askDeleteItems:"),
                                  indexPaths ?: @[]);
    if (completion) completion(@[]);
}

static void hook_fileSystemDoEraseSelectedItems(id self, SEL _cmd,
                                                 NSArray *indexPaths,
                                                 void (^completion)(NSArray *)) {
    NSArray *items = selectedFileItems(self, indexPaths);
    if (!fileItemsUseMCMOperations(items)) {
        if (orig_fileSystemDoEraseSelectedItems)
            ((void(*)(id, SEL, id, id))orig_fileSystemDoEraseSelectedItems)(
                self, _cmd, indexPaths, completion);
        return;
    }
    performPermanentDelete(self, indexPaths, completion);
}

static void hook_pageDoEraseSelectedItems(id self, SEL _cmd,
                                           NSArray *indexPaths,
                                           void (^completion)(NSArray *)) {
    NSArray *items = selectedFileItems(self, indexPaths);
    if (!fileItemsUseMCMOperations(items)) {
        if (orig_pageDoEraseSelectedItems)
            ((void(*)(id, SEL, id, id))orig_pageDoEraseSelectedItems)(
                self, _cmd, indexPaths, completion);
        return;
    }
    performPermanentDelete(self, indexPaths, completion);
}

static dispatch_queue_t pasteCopyQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("local.filzamod.container-copy", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static IMP orig_copyFilesAndDirectoryFromPasteboard = NULL;
static void hook_copyFilesAndDirectoryFromPasteboard(id self, SEL _cmd) {
    MCMFilzaStart();
    NSString *destinationDirectory = ((id(*)(id, SEL))objc_msgSend)(self,
        NSSelectorFromString(@"currentPath"));
    destinationDirectory = localPathFromPasteboardValue(destinationDirectory)
        ?: destinationDirectory;
    if (!MCMFilzaPathHasActiveLease(destinationDirectory)) {
        ((void(*)(id, SEL))orig_copyFilesAndDirectoryFromPasteboard)(self, _cmd);
        return;
    }

    Class pasteboardClass = NSClassFromString(@"TGPasteboard");
    id pasteboard = [pasteboardClass respondsToSelector:@selector(sharedInstance)]
        ? ((id(*)(id, SEL))objc_msgSend)(pasteboardClass, @selector(sharedInstance)) : nil;
    NSArray *objects = [pasteboard respondsToSelector:NSSelectorFromString(@"resolveAndGetObjects")]
        ? ((id(*)(id, SEL))objc_msgSend)(pasteboard,
            NSSelectorFromString(@"resolveAndGetObjects")) : nil;
    if (![objects isKindOfClass:NSArray.class] || objects.count == 0) {
        ((void(*)(id, SEL))orig_copyFilesAndDirectoryFromPasteboard)(self, _cmd);
        return;
    }

    UIViewController *controller = self;
    dispatch_async(pasteCopyQueue(), ^{
        NSMutableArray<NSError *> *errors = [NSMutableArray array];
        NSUInteger copied = 0;
        for (id object in objects) {
            if (![object isKindOfClass:NSDictionary.class]) continue;
            NSString *source = localPathFromPasteboardValue(object[@"path"]);
            NSString *name = [object[@"name"] isKindOfClass:NSString.class]
                ? object[@"name"] : source.lastPathComponent;
            NSString *destination = uniquePasteDestination(destinationDirectory, name);
            NSError *error = nil;
            if (!source || !destination) {
                setPastePOSIXError(&error, EINVAL, @"resolve paste item", name ?: @"(unknown)");
            } else if (pasteDestinationIsInsideSource(source, destinationDirectory)) {
                setPastePOSIXError(&error, EINVAL, @"paste directory into itself", source);
            } else if (directCopyItem(source, destination, &error)) {
                copied++;
                NSLog(@"[ContainerPaste] copied %@ -> %@", source, destination);
            }
            if (error) {
                [errors addObject:error];
                NSLog(@"[ContainerPaste] failed: %@", error.localizedDescription);
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            SEL loadSelector = NSSelectorFromString(@"doLoadingPage");
            if ([controller respondsToSelector:loadSelector])
                ((void(*)(id, SEL))objc_msgSend)(controller, loadSelector);
            showPasteFailure(controller, errors);
            NSLog(@"[ContainerPaste] complete copied=%lu failed=%lu destination=%@",
                (unsigned long)copied, (unsigned long)errors.count, destinationDirectory);
        });
    });
}

static void runOptInPasteCopyProbe(void) {
    if (!getenv("FILZA_PASTE_PROBE")) return;
    NSString *source = [NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject
        stringByAppendingPathComponent:[NSString stringWithFormat:
            @".filza-mod-paste-source-%d", getpid()]];
    NSString *destination = [[MCMFilzaVirtualRoot()
        stringByAppendingPathComponent:@"App Groups/group.com.apple.notes"]
        stringByAppendingPathComponent:[NSString stringWithFormat:
            @".filza-mod-paste-destination-%d", getpid()]];
    NSData *payload = [NSUUID.UUID.UUIDString dataUsingEncoding:NSUTF8StringEncoding];
    BOOL sourceWritten = [payload writeToFile:source atomically:NO];
    NSError *error = nil;
    BOOL copied = sourceWritten && directCopyItem(source, destination, &error);
    NSData *roundTrip = copied ? [NSData dataWithContentsOfFile:destination] : nil;
    BOOL verified = [roundTrip isEqualToData:payload];
    BOOL destinationRemoved = !copied ||
        [NSFileManager.defaultManager removeItemAtPath:destination error:nil];
    BOOL sourceRemoved = !sourceWritten ||
        [NSFileManager.defaultManager removeItemAtPath:source error:nil];
    NSLog(@"[ContainerPasteProbe] copied=%d verified=%d cleanup=%d error=%@",
        copied, verified, destinationRemoved && sourceRemoved, error);
}

#pragma mark - Hook Installation

static void installHooks(void) {
    Class preferences = NSClassFromString(@"TGPreferences");
    if (preferences) {
        Method defaultPath = class_getInstanceMethod(preferences, NSSelectorFromString(@"defaultPath"));
        if (defaultPath) method_setImplementation(defaultPath, (IMP)hook_defaultPath);
    }

    Class fileSystemController = NSClassFromString(@"TGFileSystemListViewController");
    if (fileSystemController) {
        Method setCurrentPath = class_getInstanceMethod(
            fileSystemController, NSSelectorFromString(@"setCurrentPath:"));
        if (setCurrentPath) {
            orig_fileSystemSetCurrentPath = method_getImplementation(setCurrentPath);
            method_setImplementation(setCurrentPath, (IMP)hook_fileSystemSetCurrentPath);
        }
        Method viewWillAppear = class_getInstanceMethod(
            fileSystemController, @selector(viewWillAppear:));
        if (viewWillAppear) {
            orig_fileSystemViewWillAppear = method_getImplementation(viewWillAppear);
            method_setImplementation(viewWillAppear, (IMP)hook_fileSystemViewWillAppear);
        }
        SEL editableSelector = NSSelectorFromString(@"updateEditableUI");
        Method updateEditableUI = class_getInstanceMethod(fileSystemController,
            editableSelector);
        if (updateEditableUI) {
            orig_fileSystemUpdateEditableUI = method_getImplementation(updateEditableUI);
            const char *types = method_getTypeEncoding(updateEditableUI);
            // updateEditableUI is inherited from TGPageViewController in this
            // Filza build. Add a subclass override rather than modifying every
            // page controller in the application.
            if (!class_addMethod(fileSystemController, editableSelector,
                    (IMP)hook_fileSystemUpdateEditableUI, types))
                method_setImplementation(updateEditableUI,
                    (IMP)hook_fileSystemUpdateEditableUI);
        }

        SEL pageDeleteSelector = NSSelectorFromString(@"pageDeleteAction");
        Method pageDeleteAction = class_getInstanceMethod(fileSystemController,
            pageDeleteSelector);
        if (pageDeleteAction) {
            orig_fileSystemPageDeleteAction = method_getImplementation(pageDeleteAction);
            const char *types = method_getTypeEncoding(pageDeleteAction);
            if (!class_addMethod(fileSystemController, pageDeleteSelector,
                    (IMP)hook_fileSystemPageDeleteAction, types))
                method_setImplementation(pageDeleteAction,
                    (IMP)hook_fileSystemPageDeleteAction);
        }

        SEL deleteSelectedSelector = NSSelectorFromString(@"deleteSelectedItems");
        Method deleteSelected = class_getInstanceMethod(fileSystemController,
            deleteSelectedSelector);
        if (deleteSelected) {
            orig_fileSystemDeleteSelectedItems = method_getImplementation(deleteSelected);
            method_setImplementation(deleteSelected,
                (IMP)hook_fileSystemDeleteSelectedItems);
        }

        SEL askDeleteSelector = NSSelectorFromString(@"askDeleteItems:");
        Method askDelete = class_getInstanceMethod(fileSystemController,
            askDeleteSelector);
        Method parentAskDelete = class_getInstanceMethod(
            class_getSuperclass(fileSystemController), askDeleteSelector);
        if (askDelete && parentAskDelete) {
            parentFileSystemAskDeleteItems = method_getImplementation(parentAskDelete);
            method_setImplementation(askDelete,
                (IMP)hook_fileSystemAskDeleteItems);
        }

        SEL trashSelector = NSSelectorFromString(
            @"doTrashSelectedIndexPaths:completion:");
        Method trashSelected = class_getInstanceMethod(fileSystemController,
            trashSelector);
        if (trashSelected) {
            orig_fileSystemDoTrashSelectedItems = method_getImplementation(trashSelected);
            method_setImplementation(trashSelected,
                (IMP)hook_fileSystemDoTrashSelectedItems);
        }

        SEL eraseSelector = NSSelectorFromString(
            @"doEraseSelectedIndexPaths:completion:");
        Method eraseSelected = class_getInstanceMethod(fileSystemController,
            eraseSelector);
        if (eraseSelected) {
            orig_fileSystemDoEraseSelectedItems = method_getImplementation(eraseSelected);
            method_setImplementation(eraseSelected,
                (IMP)hook_fileSystemDoEraseSelectedItems);
        }
    }

    Class pageController = NSClassFromString(@"TGPageViewController");
    if (pageController) {
        SEL askDeleteSelector = NSSelectorFromString(@"askDeleteItems:");
        Method askDelete = class_getInstanceMethod(pageController, askDeleteSelector);
        if (askDelete) {
            orig_pageAskDeleteItems = method_getImplementation(askDelete);
            if (!parentFileSystemAskDeleteItems)
                parentFileSystemAskDeleteItems = orig_pageAskDeleteItems;
            method_setImplementation(askDelete,
                (IMP)hook_fileSystemAskDeleteItems);
        }

        SEL trashSelector = NSSelectorFromString(
            @"doTrashSelectedIndexPaths:completion:");
        Method trashSelected = class_getInstanceMethod(pageController, trashSelector);
        if (trashSelected) {
            orig_pageDoTrashSelectedItems = method_getImplementation(trashSelected);
            method_setImplementation(trashSelected,
                (IMP)hook_pageDoTrashSelectedItems);
        }

        SEL eraseSelector = NSSelectorFromString(
            @"doEraseSelectedIndexPaths:completion:");
        Method eraseSelected = class_getInstanceMethod(pageController, eraseSelector);
        if (eraseSelected) {
            orig_pageDoEraseSelectedItems = method_getImplementation(eraseSelected);
            method_setImplementation(eraseSelected,
                (IMP)hook_pageDoEraseSelectedItems);
        }

        Method copyPaste = class_getInstanceMethod(pageController,
            NSSelectorFromString(@"copyFilesAndDirectoryFromPasteboard"));
        if (copyPaste) {
            orig_copyFilesAndDirectoryFromPasteboard = method_getImplementation(copyPaste);
            method_setImplementation(copyPaste,
                (IMP)hook_copyFilesAndDirectoryFromPasteboard);
        }
    }

    Class rfm = NSClassFromString(@"TGRootFileManager");
    if (rfm) {
        Class meta = object_getClass(rfm);
        class_replaceMethod(meta, NSSelectorFromString(@"isRootHelperAvailable"), (IMP)hook_isRootHelperAvailable, "B@:");
        class_replaceMethod(rfm, NSSelectorFromString(@"spawnRootHelper"), (IMP)hook_spawnRootHelper, "i@:");
        class_replaceMethod(rfm, NSSelectorFromString(@"spawnRootHelperIfNeeds"), (IMP)hook_spawnRootHelperIfNeeds, "i@:");
        class_replaceMethod(rfm, NSSelectorFromString(@"respawnRootHelper"), (IMP)hook_respawnRootHelper, "i@:");
        class_replaceMethod(rfm, NSSelectorFromString(@"tryLoadFilzaHelper"), (IMP)hook_tryLoadFilzaHelper, "v@:");
        class_replaceMethod(rfm, NSSelectorFromString(@"createHelperConnectionIfNeeds"), (IMP)hook_createHelperConnectionIfNeeds, "v@:");
        class_replaceMethod(rfm, NSSelectorFromString(@"spawnRoot:args:pid:"), (IMP)hook_spawnRoot_args_pid, "i@:@@^i");
        class_replaceMethod(rfm, NSSelectorFromString(@"sendObjectWithReplySync:"), (IMP)hook_sendObjectWithReplySync, "@@:@");
        class_replaceMethod(rfm, NSSelectorFromString(@"sendObjectWithReplySync:fileDescriptor:"), (IMP)hook_sendObjectWithReplySync_fd, "@@:@^i");
        class_replaceMethod(rfm, NSSelectorFromString(@"sendObjectWithReplySync:fileDescriptor:logintty:"), (IMP)hook_sendObjectWithReplySync_fd_logintty, "@@:@^iB");
        class_replaceMethod(rfm, NSSelectorFromString(@"sendObjectNoReply:"), (IMP)hook_sendObjectNoReply, "v@:@");
        class_replaceMethod(rfm, NSSelectorFromString(@"sendObjectWithReplyAsync:queue:completion:"), (IMP)hook_sendObjectWithReplyAsync, "v@:@@?");

    }
    Class zipper = NSClassFromString(@"Zipper");
    if (zipper) {
        Method m;
        m = class_getInstanceMethod(zipper, NSSelectorFromString(@"ZipFiles:toFilePath:currentDirectory:"));
        if (m) { orig_ZipFiles = method_getImplementation(m); method_setImplementation(m, (IMP)hook_ZipFiles); }
        m = class_getInstanceMethod(zipper, NSSelectorFromString(@"unZipFile:toPath:currentDirectory:outMessage:"));
        if (m) { orig_unZipFile = method_getImplementation(m); method_setImplementation(m, (IMP)hook_unZipFile); }
        m = class_getInstanceMethod(zipper, NSSelectorFromString(@"unZipFile:toPath:currentDirectory:withPassword:outMessage:"));
        if (m) { orig_unZipFilePassword = method_getImplementation(m); method_setImplementation(m, (IMP)hook_unZipFilePassword); }
    }

    // License/integrity bypass
    Class alertCtrl = NSClassFromString(@"TGAlertController");
    if (alertCtrl) {
        Class alertMeta = object_getClass(alertCtrl);
        Method m = class_getClassMethod(alertCtrl, NSSelectorFromString(@"showAlertWithTitle:text:cancelButton:otherButtons:completion:"));
        if (m) {
            orig_showAlert = method_getImplementation(m);
            class_replaceMethod(alertMeta, NSSelectorFromString(@"showAlertWithTitle:text:cancelButton:otherButtons:completion:"),
                (IMP)hook_showAlertWithTitle, "@@:@@@@@");
        }
    }
    Class activationVC = NSClassFromString(@"NewActivationViewController");
    if (activationVC) {
        Method m = class_getInstanceMethod(activationVC, @selector(viewDidLoad));
        if (m) {
            orig_activationViewDidLoad = method_getImplementation(m);
            method_setImplementation(m, (IMP)hook_activationViewDidLoad);
        }
    }

    // Apps Manager fixes
    Class lsWorkspace = NSClassFromString(@"LSApplicationWorkspace");
    if (lsWorkspace) {
        Method m = class_getInstanceMethod(lsWorkspace, NSSelectorFromString(@"allApplications"));
        if (m) { orig_allApplications = method_getImplementation(m); method_setImplementation(m, (IMP)hook_allApplications); }
    }
    Class appItem = NSClassFromString(@"ApplicationItem");
    if (appItem) {
        Method m;
        m = class_getInstanceMethod(appItem, NSSelectorFromString(@"setAppProxy:"));
        if (m) { orig_setAppProxy = method_getImplementation(m); method_setImplementation(m, (IMP)hook_setAppProxy); }
    }
    Class appsVC = NSClassFromString(@"TGApplicationsViewController");
    if (appsVC) {
        Method m = class_getInstanceMethod(appsVC, NSSelectorFromString(@"browserView:didSelectItemAtIndexPath:"));
        if (m) { orig_didSelectItem = method_getImplementation(m); method_setImplementation(m, (IMP)hook_didSelectItem); }
    }

    NSLog(@"[Tweak] All hooks installed");
}

#pragma mark - MCM container activation

static void runWriteProbeAtDirectory(NSString *label, NSString *directory) {
    NSString *name = [NSString stringWithFormat:@".filza-mod-write-probe-%d", getpid()];
    NSString *path = [directory stringByAppendingPathComponent:name];
    NSData *payload = [NSUUID.UUID.UUIDString dataUsingEncoding:NSUTF8StringEncoding];
    int descriptor = open(path.fileSystemRepresentation,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    int createError = descriptor < 0 ? errno : 0;
    ssize_t written = -1;
    if (descriptor >= 0) {
        written = write(descriptor, payload.bytes, payload.length);
        fsync(descriptor);
        close(descriptor);
    }

    NSData *roundTrip = descriptor >= 0 ? [NSData dataWithContentsOfFile:path] : nil;
    BOOL verified = written == (ssize_t)payload.length && [roundTrip isEqualToData:payload];
    int cleanupResult = descriptor >= 0 ? unlink(path.fileSystemRepresentation) : -1;
    struct stat status = {0};
    BOOL removed = descriptor >= 0 && cleanupResult == 0 &&
        lstat(path.fileSystemRepresentation, &status) != 0 && errno == ENOENT;
    NSLog(@"[WriteProbe] target=%@ create=%d errno=%d bytes=%zd readback=%d cleanup=%d path=%@",
        label, descriptor >= 0, createError, written, verified, removed, path);
}

static void runWritableOpenProbe(NSString *label, NSString *path) {
    int descriptor = open(path.fileSystemRepresentation,
        O_RDWR | O_CLOEXEC | O_NOFOLLOW);
    int openError = descriptor < 0 ? errno : 0;
    struct stat status = {0};
    BOOL regularFile = descriptor >= 0 && fstat(descriptor, &status) == 0 &&
        S_ISREG(status.st_mode);
    if (descriptor >= 0) close(descriptor);
    NSLog(@"[WriteProbe] target=%@ open_rdwr=%d errno=%d regular=%d size=%lld path=%@",
        label, descriptor >= 0, openError, regularFile,
        regularFile ? (long long)status.st_size : -1LL, path);
}

static void runOptInWriteProbe(void) {
    if (!getenv("FILZA_WRITE_PROBE")) return;
    NSString *root = MCMFilzaVirtualRoot();
    NSString *canary = [root stringByAppendingPathComponent:
        @"App Data/local.research.SandboxCanaryVictim"];
    runWriteProbeAtDirectory(@"Canary app data", canary);
    runWriteProbeAtDirectory(@"Canary app data tmp",
        [canary stringByAppendingPathComponent:@"tmp"]);
    runWriteProbeAtDirectory(@"Notes app data",
        [root stringByAppendingPathComponent:@"App Data/com.apple.mobilenotes"]);
    runWriteProbeAtDirectory(@"Notes app data tmp",
        [root stringByAppendingPathComponent:@"App Data/com.apple.mobilenotes/tmp"]);
    runWriteProbeAtDirectory(@"Notes app group",
        [root stringByAppendingPathComponent:@"App Groups/group.com.apple.notes"]);
    runWritableOpenProbe(@"Notes database",
        [root stringByAppendingPathComponent:
            @"App Groups/group.com.apple.notes/NoteStore.sqlite"]);
}

static UIViewController *activeBrowserController(void) {
    UIWindow *window = nil;
    for (UIWindow *candidate in UIApplication.sharedApplication.windows) {
        if (candidate.isKeyWindow) { window = candidate; break; }
        if (!window && !candidate.hidden) window = candidate;
    }
    UIViewController *controller = window.rootViewController;
    while (controller) {
        UIViewController *next = controller.presentedViewController;
        if (!next && [controller isKindOfClass:UINavigationController.class])
            next = ((UINavigationController *)controller).visibleViewController;
        if (!next && [controller isKindOfClass:UITabBarController.class])
            next = ((UITabBarController *)controller).selectedViewController;
        if (!next && [controller isKindOfClass:UISplitViewController.class])
            next = ((UISplitViewController *)controller).viewControllers.lastObject;
        if (!next && [controller respondsToSelector:
                NSSelectorFromString(@"visibleViewControllers")]) {
            id visible = ((id(*)(id, SEL))objc_msgSend)(controller,
                NSSelectorFromString(@"visibleViewControllers"));
            if ([visible isKindOfClass:NSArray.class] && [visible count] > 0)
                next = [visible lastObject];
        }
        if (!next && controller.childViewControllers.count == 1)
            next = controller.childViewControllers.firstObject;
        if (!next || next == controller) break;
        controller = next;
    }
    return controller;
}

static BOOL repairActiveBrowserPath(void) {
    UIViewController *controller = activeBrowserController();
    SEL currentPathSelector = NSSelectorFromString(@"currentPath");
    SEL setCurrentPathSelector = NSSelectorFromString(@"setCurrentPath:");
    if (![controller respondsToSelector:currentPathSelector] ||
        ![controller respondsToSelector:setCurrentPathSelector]) {
        NSLog(@"[DeviceStorage] waiting for browser controller; active=%@",
            NSStringFromClass(controller.class));
        return NO;
    }
    NSString *currentPath = ((id(*)(id, SEL))objc_msgSend)(controller,
        currentPathSelector);
    NSString *root = MCMFilzaVirtualRoot();
    BOOL insideRoot = [currentPath isEqualToString:root] ||
        [currentPath hasPrefix:[root stringByAppendingString:@"/"]];
    if (!insideRoot) {
        ((void(*)(id, SEL, id))objc_msgSend)(controller,
            setCurrentPathSelector, root);
        controller.navigationItem.title = @"Device Storage";
        NSLog(@"[DeviceStorage] repaired active browser path from %@ to %@ class=%@",
            currentPath, root, NSStringFromClass(controller.class));
    }
    SEL loadSelector = NSSelectorFromString(@"doLoadingPage");
    if ([controller respondsToSelector:loadSelector]) {
        ((void(*)(id, SEL))objc_msgSend)(controller, loadSelector);
        NSLog(@"[DeviceStorage] reloaded active browser path %@ class=%@",
              root, NSStringFromClass(controller.class));
    }
    return YES;
}

static void scheduleInitialBrowserRepair(NSUInteger attemptsRemaining) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 400 * NSEC_PER_MSEC),
        dispatch_get_main_queue(), ^{
            if (!repairActiveBrowserPath() && attemptsRemaining > 1)
                scheduleInitialBrowserRepair(attemptsRemaining - 1);
        });
}

static void runMCMPath(void) {
    MCMFilzaStart();
    if (MCMFilzaIsRunningInLiveContainer()) return;
    PBWallpaperFeatureStart();
    runOptInWriteProbe();
    runOptInPasteCopyProbe();
}

#pragma mark - Entry Point

__attribute__((constructor)) void TweakInit(void) {
    installHooks();
    // Populate the MCM root before Filza restores its initial browser path.
    runMCMPath();
    scheduleInitialBrowserRepair(8);
}
