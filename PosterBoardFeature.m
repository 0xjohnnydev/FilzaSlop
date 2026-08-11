#import "PosterBoardFeature.h"

#import "MCMFilzaIntegration.h"

#import <CommonCrypto/CommonDigest.h>
#import <dirent.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <sys/stdio.h>
#import <unistd.h>

static NSString *const PBErrorDomain = @"local.filzamod.posterboard";
static NSString *const PBPosterBoardIdentifier = @"com.apple.PosterBoard";
static const NSUInteger PBMaximumDescriptors = 10;
static const NSUInteger PBMaximumFiles = 4096;
static const unsigned long long PBMaximumBytes = 256ULL * 1024ULL * 1024ULL;
static const NSInteger PBButtonTag = 0x50424C42;

typedef struct {
    NSUInteger files;
    NSUInteger directories;
    unsigned long long bytes;
} PBTreeStats;

static BOOL PBSetError(NSError **error, NSInteger code, NSString *format, ...)
{
    if (error) {
        va_list arguments;
        va_start(arguments, format);
        NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
        va_end(arguments);
        *error = [NSError errorWithDomain:PBErrorDomain code:code
            userInfo:@{NSLocalizedDescriptionKey: message ?: @"PosterBoard operation failed"}];
    }
    return NO;
}

static NSString *PBWorkspace(void)
{
    return [MCMFilzaVirtualRoot()
        stringByAppendingPathComponent:MCMFilzaWallpaperLabName()];
}

static NSString *PBImportsDirectory(void)
{
    return [PBWorkspace() stringByAppendingPathComponent:@"Imports"];
}

static NSString *PBBackupsDirectory(void)
{
    return [PBWorkspace() stringByAppendingPathComponent:@"Backups"];
}

static NSString *PBReportsDirectory(void)
{
    return [PBWorkspace() stringByAppendingPathComponent:@"Reports"];
}

static NSString *PBCanonicalPath(NSString *path)
{
    NSString *result = path.stringByStandardizingPath;
    if ([result isEqualToString:@"/var"] || [result hasPrefix:@"/var/"])
        result = [@"/private" stringByAppendingString:result];
    return result;
}

static BOOL PBSkippedName(NSString *name)
{
    return [name hasPrefix:@"."] || [name caseInsensitiveCompare:@"__MACOSX"] == NSOrderedSame;
}

static BOOL PBSafeName(NSString *name)
{
    return name.length > 0 && ![name isEqualToString:@"."] &&
        ![name isEqualToString:@".."] && [name rangeOfString:@"/"].location == NSNotFound &&
        [name rangeOfString:@"\0"].location == NSNotFound;
}

static BOOL PBDirectoryNoSymlink(NSString *path, BOOL requireExisting, NSError **error)
{
    struct stat status = {0};
    if (lstat(path.fileSystemRepresentation, &status) != 0) {
        if (errno == ENOENT && !requireExisting) return YES;
        return PBSetError(error, errno, @"Cannot inspect directory %@ (errno %d)", path, errno);
    }
    if (!S_ISDIR(status.st_mode))
        return PBSetError(error, EINVAL, @"Expected a real directory at %@", path);
    return YES;
}

static NSArray<NSString *> *PBDirectoryNames(NSString *path, NSError **error)
{
    DIR *directory = opendir(path.fileSystemRepresentation);
    if (!directory) {
        PBSetError(error, errno, @"Cannot open %@ (errno %d)", path, errno);
        return nil;
    }
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    struct dirent *entry = NULL;
    errno = 0;
    while ((entry = readdir(directory))) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        NSString *name = [NSString stringWithUTF8String:entry->d_name];
        if (!name || !PBSafeName(name)) {
            closedir(directory);
            PBSetError(error, EINVAL, @"Directory contains an unsupported file name: %@", path);
            return nil;
        }
        [names addObject:name];
    }
    int readError = errno;
    closedir(directory);
    if (readError) {
        PBSetError(error, readError, @"Failed while reading %@ (errno %d)", path, readError);
        return nil;
    }
    return [names sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}

static BOOL PBScanTreeRecursive(NSString *base, NSString *relative, NSUInteger depth,
                                NSMutableArray<NSDictionary *> *entries,
                                PBTreeStats *stats, NSError **error)
{
    if (depth > 32) return PBSetError(error, ELOOP, @"Package tree is deeper than 32 levels");
    NSString *directory = relative.length ? [base stringByAppendingPathComponent:relative] : base;
    NSArray<NSString *> *names = PBDirectoryNames(directory, error);
    if (!names) return NO;
    for (NSString *name in names) {
        if (PBSkippedName(name)) continue;
        NSString *childRelative = relative.length
            ? [relative stringByAppendingPathComponent:name] : name;
        NSString *child = [base stringByAppendingPathComponent:childRelative];
        struct stat status = {0};
        if (lstat(child.fileSystemRepresentation, &status) != 0)
            return PBSetError(error, errno, @"Cannot inspect %@ (errno %d)", child, errno);
        if (S_ISDIR(status.st_mode)) {
            stats->directories++;
            [entries addObject:@{@"Path": childRelative, @"Directory": @YES}];
            if (!PBScanTreeRecursive(base, childRelative, depth + 1, entries, stats, error))
                return NO;
        } else if (S_ISREG(status.st_mode)) {
            if (status.st_size < 0) return PBSetError(error, EINVAL, @"Invalid file size at %@", child);
            stats->files++;
            stats->bytes += (unsigned long long)status.st_size;
            if (stats->files > PBMaximumFiles || stats->bytes > PBMaximumBytes)
                return PBSetError(error, EFBIG,
                    @"Package exceeds the %lu-file or 256 MiB safety limit",
                    (unsigned long)PBMaximumFiles);
            [entries addObject:@{@"Path": childRelative, @"Directory": @NO,
                                 @"Size": @((unsigned long long)status.st_size)}];
        } else {
            return PBSetError(error, EINVAL,
                @"Package contains a link or special file, which is not allowed: %@", childRelative);
        }
    }
    return YES;
}

static NSArray<NSDictionary *> *PBScanTree(NSString *root, PBTreeStats *stats,
                                           NSError **error)
{
    memset(stats, 0, sizeof(*stats));
    if (!PBDirectoryNoSymlink(root, YES, error)) return nil;
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    if (!PBScanTreeRecursive(root, @"", 0, entries, stats, error)) return nil;
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [left[@"Path"] compare:right[@"Path"] options:NSLiteralSearch];
    }];
    return entries;
}

static BOOL PBCopyRegularFile(NSString *source, NSString *destination, NSError **error)
{
    int input = open(source.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (input < 0) return PBSetError(error, errno, @"Cannot open %@ (errno %d)", source, errno);
    struct stat status = {0};
    if (fstat(input, &status) != 0 || !S_ISREG(status.st_mode)) {
        int saved = errno ?: EINVAL;
        close(input);
        return PBSetError(error, saved, @"Source changed during import: %@", source);
    }
    int output = open(destination.fileSystemRepresentation,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (output < 0) {
        int saved = errno;
        close(input);
        return PBSetError(error, saved, @"Cannot create %@ (errno %d)", destination, saved);
    }
    BOOL ok = YES;
    uint8_t buffer[64 * 1024];
    for (;;) {
        ssize_t count = read(input, buffer, sizeof(buffer));
        if (count == 0) break;
        if (count < 0) {
            if (errno == EINTR) continue;
            ok = PBSetError(error, errno, @"Read failed for %@ (errno %d)", source, errno);
            break;
        }
        ssize_t offset = 0;
        while (offset < count) {
            ssize_t written = write(output, buffer + offset, (size_t)(count - offset));
            if (written < 0 && errno == EINTR) continue;
            if (written <= 0) {
                ok = PBSetError(error, errno ?: EIO, @"Write failed for %@ (errno %d)",
                    destination, errno ?: EIO);
                break;
            }
            offset += written;
        }
        if (!ok) break;
    }
    if (ok && fsync(output) != 0)
        ok = PBSetError(error, errno, @"Could not flush %@ (errno %d)", destination, errno);
    close(output);
    close(input);
    if (!ok) unlink(destination.fileSystemRepresentation);
    return ok;
}

static BOOL PBCopyTree(NSString *source, NSString *destination,
                       NSArray<NSDictionary *> *entries, NSError **error)
{
    if (mkdir(destination.fileSystemRepresentation, 0700) != 0)
        return PBSetError(error, errno, @"Cannot create staging directory %@ (errno %d)",
            destination, errno);
    for (NSDictionary *entry in entries) {
        if (![entry[@"Directory"] boolValue]) continue;
        NSString *path = [destination stringByAppendingPathComponent:entry[@"Path"]];
        if (mkdir(path.fileSystemRepresentation, 0700) != 0)
            return PBSetError(error, errno, @"Cannot create directory %@ (errno %d)", path, errno);
    }
    for (NSDictionary *entry in entries) {
        if ([entry[@"Directory"] boolValue]) continue;
        NSString *relative = entry[@"Path"];
        if (!PBCopyRegularFile([source stringByAppendingPathComponent:relative],
                               [destination stringByAppendingPathComponent:relative], error))
            return NO;
    }
    return YES;
}

static BOOL PBWritePlist(id plist, NSPropertyListFormat format, NSString *path,
                         NSError **error)
{
    NSError *serializationError = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist
        format:format options:0 error:&serializationError];
    if (!data) {
        if (error) *error = serializationError;
        return NO;
    }
    NSError *writeError = nil;
    if (![data writeToFile:path options:NSDataWritingAtomic error:&writeError]) {
        if (error) *error = writeError;
        return NO;
    }
    return YES;
}

static BOOL PBRewriteDescriptor(NSString *root, NSInteger wallpaperIdentifier,
                                NSError **error)
{
    PBTreeStats stats = {0};
    NSArray<NSDictionary *> *entries = PBScanTree(root, &stats, error);
    if (!entries) return NO;
    for (NSDictionary *entry in entries) {
        if ([entry[@"Directory"] boolValue]) continue;
        NSString *relative = entry[@"Path"];
        NSString *name = relative.lastPathComponent;
        NSString *path = [root stringByAppendingPathComponent:relative];
        if ([name isEqualToString:@"com.apple.posterkit.provider.descriptor.identifier"]) {
            NSData *identifierData = [[NSString stringWithFormat:@"%ld", (long)wallpaperIdentifier]
                dataUsingEncoding:NSUTF8StringEncoding];
            if (![identifierData writeToFile:path options:NSDataWritingAtomic error:error]) return NO;
            continue;
        }
        BOOL userInfo = [name isEqualToString:@"com.apple.posterkit.provider.contents.userInfo"];
        BOOL wallpaperPlist = [name hasSuffix:@"Wallpaper.plist"];
        if (!userInfo && !wallpaperPlist) continue;
        NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:error];
        if (!data) return NO;
        NSPropertyListFormat format = NSPropertyListBinaryFormat_v1_0;
        id plist = [NSPropertyListSerialization propertyListWithData:data
            options:NSPropertyListMutableContainersAndLeaves format:&format error:error];
        if (![plist isKindOfClass:NSMutableDictionary.class])
            return PBSetError(error, EINVAL, @"Expected a dictionary plist at %@", relative);
        NSMutableDictionary *dictionary = plist;
        if (userInfo) {
            dictionary[@"wallpaperRepresentingIdentifier"] = @(wallpaperIdentifier);
        } else {
            dictionary[@"identifier"] = @(wallpaperIdentifier);
            dictionary[@"family"] = @"Marble";
            dictionary[@"name"] = @"Lavender";
            id assets = dictionary[@"assets"];
            id lockAndHome = [assets isKindOfClass:NSMutableDictionary.class]
                ? assets[@"lockAndHome"] : nil;
            id defaultAsset = [lockAndHome isKindOfClass:NSMutableDictionary.class]
                ? lockAndHome[@"default"] : nil;
            if ([defaultAsset isKindOfClass:NSMutableDictionary.class])
                defaultAsset[@"name"] = @"Lavender";
        }
        if (!PBWritePlist(dictionary, format, path, error)) return NO;
    }
    return YES;
}

static NSString *PBHexDigest(const unsigned char digest[CC_SHA256_DIGEST_LENGTH])
{
    NSMutableString *result = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++)
        [result appendFormat:@"%02x", digest[index]];
    return result;
}

static NSString *PBDataDigest(NSData *data)
{
    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    return PBHexDigest(digest);
}

static NSString *PBTreeDigest(NSString *root, PBTreeStats *outStats, NSError **error)
{
    PBTreeStats stats = {0};
    NSArray<NSDictionary *> *entries = PBScanTree(root, &stats, error);
    if (!entries) return nil;
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    for (NSDictionary *entry in entries) {
        BOOL directory = [entry[@"Directory"] boolValue];
        uint8_t type = directory ? 'D' : 'F';
        NSData *pathData = [entry[@"Path"] dataUsingEncoding:NSUTF8StringEncoding];
        uint32_t length = CFSwapInt32HostToBig((uint32_t)pathData.length);
        CC_SHA256_Update(&context, &type, sizeof(type));
        CC_SHA256_Update(&context, &length, sizeof(length));
        CC_SHA256_Update(&context, pathData.bytes, (CC_LONG)pathData.length);
        if (directory) continue;
        NSString *path = [root stringByAppendingPathComponent:entry[@"Path"]];
        int descriptor = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
        if (descriptor < 0) {
            PBSetError(error, errno, @"Cannot hash %@ (errno %d)", path, errno);
            return nil;
        }
        uint8_t buffer[64 * 1024];
        BOOL ok = YES;
        for (;;) {
            ssize_t count = read(descriptor, buffer, sizeof(buffer));
            if (count == 0) break;
            if (count < 0 && errno == EINTR) continue;
            if (count < 0) {
                ok = PBSetError(error, errno, @"Cannot hash %@ (errno %d)", path, errno);
                break;
            }
            CC_SHA256_Update(&context, buffer, (CC_LONG)count);
        }
        close(descriptor);
        if (!ok) return nil;
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
    CC_SHA256_Final(digest, &context);
    if (outStats) *outStats = stats;
    return PBHexDigest(digest);
}

static BOOL PBFindDescriptorContainers(NSString *directory, NSUInteger depth,
                                       NSMutableArray<NSString *> *containers,
                                       NSError **error)
{
    if (depth > 8) return PBSetError(error, ELOOP, @"Package search exceeded 8 levels");
    NSString *lowerName = directory.lastPathComponent.lowercaseString;
    if ([lowerName containsString:@"descriptor"]) {
        [containers addObject:directory];
        return YES;
    }
    NSArray<NSString *> *names = PBDirectoryNames(directory, error);
    if (!names) return NO;
    for (NSString *name in names) {
        if (PBSkippedName(name)) continue;
        NSString *path = [directory stringByAppendingPathComponent:name];
        struct stat status = {0};
        if (lstat(path.fileSystemRepresentation, &status) != 0)
            return PBSetError(error, errno, @"Cannot inspect %@ (errno %d)", path, errno);
        if (S_ISLNK(status.st_mode))
            return PBSetError(error, EINVAL, @"Package links are not allowed: %@", path);
        if (!S_ISDIR(status.st_mode)) continue;
        if ([name caseInsensitiveCompare:@"container"] == NSOrderedSame)
            return PBSetError(error, EPERM,
                @"Unsafe container-style tendies are not supported. Use a descriptor package.");
        if (!PBFindDescriptorContainers(path, depth + 1, containers, error)) return NO;
    }
    return YES;
}

static NSString *PBProviderForContainer(NSString *container)
{
    NSString *name = container.lastPathComponent.lowercaseString;
    if ([name containsString:@"video"] || [name containsString:@"photos"])
        return @"com.apple.PhotosUIPrivate.PhotosPosterProvider";
    if ([name containsString:@"mercury"])
        return @"com.apple.MercuryPoster";
    return @"com.apple.WallpaperKit.CollectionsPoster";
}

static NSArray<NSDictionary *> *PBDiscoverDescriptors(NSString *package,
                                                       NSError **error)
{
    NSMutableArray<NSString *> *containers = [NSMutableArray array];
    if (!PBFindDescriptorContainers(package, 0, containers, error)) return nil;
    if (containers.count == 0) {
        PBSetError(error, ENOENT,
            @"No descriptor or descriptors folder was found in %@", package.lastPathComponent);
        return nil;
    }
    NSMutableArray<NSDictionary *> *descriptors = [NSMutableArray array];
    for (NSString *container in containers) {
        NSString *provider = PBProviderForContainer(container);
        NSArray<NSString *> *names = PBDirectoryNames(container, error);
        if (!names) return nil;
        for (NSString *name in names) {
            if (PBSkippedName(name)) continue;
            NSString *source = [container stringByAppendingPathComponent:name];
            struct stat status = {0};
            if (lstat(source.fileSystemRepresentation, &status) != 0) {
                PBSetError(error, errno, @"Cannot inspect %@ (errno %d)", source, errno);
                return nil;
            }
            if (!S_ISDIR(status.st_mode)) {
                PBSetError(error, EINVAL,
                    @"Descriptor folder contains an unexpected file: %@", source);
                return nil;
            }
            PBTreeStats stats = {0};
            NSArray *entries = PBScanTree(source, &stats, error);
            if (!entries) return nil;
            if (stats.files == 0) {
                PBSetError(error, EINVAL, @"Descriptor is empty: %@", source);
                return nil;
            }
            [descriptors addObject:@{@"Source": source, @"SourceName": name,
                @"Provider": provider, @"Entries": entries,
                @"FileCount": @(stats.files), @"ByteCount": @(stats.bytes)}];
            if (descriptors.count > PBMaximumDescriptors) {
                PBSetError(error, E2BIG, @"A package may contain at most %lu descriptors",
                    (unsigned long)PBMaximumDescriptors);
                return nil;
            }
        }
    }
    if (descriptors.count == 0) {
        PBSetError(error, ENOENT, @"The package contains no descriptor directories");
        return nil;
    }
    return descriptors;
}

static NSDictionary *PBPosterBoardContext(NSError **error)
{
    NSString *activationError = nil;
    NSString *root = MCMFilzaDataContainerPath(PBPosterBoardIdentifier, &activationError);
    if (!root) {
        PBSetError(error, EPERM, @"PosterBoard container activation failed: %@",
            activationError ?: @"unknown error");
        return nil;
    }
    NSString *store = [root stringByAppendingPathComponent:
        @"Library/Application Support/PRBPosterExtensionDataStore"];
    if (!PBDirectoryNoSymlink(store, YES, error)) return nil;
    NSArray<NSString *> *names = PBDirectoryNames(store, error);
    if (!names) return nil;
    NSString *selected = nil;
    long long selectedValue = LLONG_MIN;
    NSCharacterSet *notDigits = NSCharacterSet.decimalDigitCharacterSet.invertedSet;
    for (NSString *name in names) {
        if (name.length == 0 || [name rangeOfCharacterFromSet:notDigits].location != NSNotFound)
            continue;
        NSString *structure = [store stringByAppendingPathComponent:name];
        NSString *extensions = [structure stringByAppendingPathComponent:@"Extensions"];
        if (!PBDirectoryNoSymlink(structure, YES, nil) ||
            !PBDirectoryNoSymlink(extensions, YES, nil)) continue;
        long long value = name.longLongValue;
        if (value > selectedValue) {
            selectedValue = value;
            selected = name;
        }
    }
    if (!selected)
        return PBSetError(error, ENOENT,
            @"No numeric PosterBoard structure with an Extensions directory was found"), nil;
    NSString *extensions = [[store stringByAppendingPathComponent:selected]
        stringByAppendingPathComponent:@"Extensions"];
    return @{@"Root": root, @"Store": store, @"Structure": selected,
             @"Extensions": extensions};
}

static BOOL PBEnsureTargetDirectory(NSString *path, NSMutableArray<NSString *> *created,
                                    NSError **error)
{
    struct stat status = {0};
    if (lstat(path.fileSystemRepresentation, &status) == 0) {
        if (!S_ISDIR(status.st_mode))
            return PBSetError(error, EINVAL, @"Target is not a real directory: %@", path);
        return YES;
    }
    if (errno != ENOENT)
        return PBSetError(error, errno, @"Cannot inspect target %@ (errno %d)", path, errno);
    if (mkdir(path.fileSystemRepresentation, 0700) != 0)
        return PBSetError(error, errno, @"Cannot create target %@ (errno %d)", path, errno);
    [created addObject:path];
    return YES;
}

static void PBRemoveTree(NSString *path)
{
    if (path.length == 0) return;
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}

static void PBCleanupEmptyDirectories(NSArray<NSString *> *directories)
{
    for (NSString *path in directories.reverseObjectEnumerator) {
        NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:nil];
        if (contents.count == 0) rmdir(path.fileSystemRepresentation);
    }
}

static BOOL PBWriteManifest(NSDictionary *manifest, NSString *path, NSError **error)
{
    return [manifest writeToURL:[NSURL fileURLWithPath:path]
        error:error];
}

static NSDictionary *PBApplyRefreshPreferences(NSDictionary *context,
                                                NSString *transaction,
                                                NSError **error)
{
    NSString *preferencePath = [context[@"Root"] stringByAppendingPathComponent:
        @"Library/Preferences/com.apple.PosterBoard.unprotectedUserDefaults.plist"];
    struct stat status = {0};
    int inspectResult = lstat(preferencePath.fileSystemRepresentation, &status);
    if (inspectResult != 0 && errno != ENOENT) {
        PBSetError(error, errno, @"Cannot inspect PosterBoard refresh preferences (errno %d)", errno);
        return nil;
    }
    BOOL originalExisted = inspectResult == 0;
    if (originalExisted && !S_ISREG(status.st_mode)) {
        PBSetError(error, EINVAL, @"PosterBoard refresh preference is not a regular file");
        return nil;
    }
    NSData *original = nil;
    if (originalExisted) {
        original = [NSData dataWithContentsOfFile:preferencePath
            options:NSDataReadingMappedIfSafe error:error];
        if (!original) return nil;
    }

    NSMutableDictionary *preferences = nil;
    if (original.length > 0) {
        NSPropertyListFormat format = NSPropertyListBinaryFormat_v1_0;
        id plist = [NSPropertyListSerialization propertyListWithData:original
            options:NSPropertyListMutableContainersAndLeaves format:&format error:error];
        if (![plist isKindOfClass:NSMutableDictionary.class]) {
            PBSetError(error, EINVAL, @"PosterBoard refresh preference is not a dictionary plist");
            return nil;
        }
        preferences = plist;
    } else {
        preferences = [NSMutableDictionary dictionary];
    }

    // These are Nugget's force-PosterBoard-refresh values for iOS 26.4+.
    preferences[@"PBF_LOCALE_DID_CHANGE"] = @NO;
    preferences[@"PBF_RESET_FILE_PROTECTIONS"] = @YES;
    preferences[@"PersistedPosterContainerBundleIdentifiers"] = @[
        @"com.apple.Posters.CollectionsPosterApp",
    ];
    preferences[@"CompletedPosterBundleIdentifierMigrations"] = @[
        @"com.apple.Posters.UnityPosterApp.ExtragalacticPoster",
        @"com.apple.Posters.WeatherPosterApp.WeatherPoster",
        @"com.apple.Posters.UnityPosterApp.Unity2025Poster",
        @"com.apple.Posters.UnityPosterApp.UnityPosterExtension",
        @"com.apple.Posters.UnityPosterApp.RhizomePoster",
        @"com.apple.Posters.KaleidoscopePosterApp.KaleidoscopePoster",
    ];
    NSData *installed = [NSPropertyListSerialization dataWithPropertyList:preferences
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!installed) return nil;

    NSString *backupPath = @"";
    if (originalExisted) {
        backupPath = [PBBackupsDirectory() stringByAppendingPathComponent:
            [transaction stringByAppendingString:@"-PosterBoardPrefs.bin"]];
        if (![original writeToFile:backupPath options:NSDataWritingAtomic error:error]) return nil;
    }
    if (![installed writeToFile:preferencePath options:NSDataWritingAtomic error:error]) {
        if (backupPath.length) [[NSFileManager defaultManager] removeItemAtPath:backupPath error:nil];
        return nil;
    }
    NSData *roundTrip = [NSData dataWithContentsOfFile:preferencePath
        options:NSDataReadingMappedIfSafe error:error];
    if (!roundTrip || ![roundTrip isEqualToData:installed]) {
        if (originalExisted)
            [original writeToFile:preferencePath options:NSDataWritingAtomic error:nil];
        else
            [[NSFileManager defaultManager] removeItemAtPath:preferencePath error:nil];
        if (backupPath.length) [[NSFileManager defaultManager] removeItemAtPath:backupPath error:nil];
        if (!error || !*error)
            PBSetError(error, EIO, @"PosterBoard refresh preference verification failed");
        return nil;
    }
    return @{
        @"Path": preferencePath,
        @"OriginalExisted": @(originalExisted),
        @"OriginalSHA256": originalExisted ? PBDataDigest(original) : @"",
        @"BackupPath": backupPath,
        @"InstalledSHA256": PBDataDigest(installed),
    };
}

static BOOL PBRestoreRefreshPreferences(NSDictionary *record,
                                        NSDictionary *context,
                                        NSError **error)
{
    if (![record isKindOfClass:NSDictionary.class]) return YES;
    NSString *expectedPath = [context[@"Root"] stringByAppendingPathComponent:
        @"Library/Preferences/com.apple.PosterBoard.unprotectedUserDefaults.plist"];
    NSString *path = [record[@"Path"] isKindOfClass:NSString.class] ? record[@"Path"] : nil;
    if (![path.stringByStandardizingPath isEqualToString:expectedPath.stringByStandardizingPath])
        return PBSetError(error, EPERM, @"Refresh rollback contains an out-of-scope preference path");
    NSData *current = [NSData dataWithContentsOfFile:path
        options:NSDataReadingMappedIfSafe error:error];
    if (!current || ![PBDataDigest(current) isEqualToString:record[@"InstalledSHA256"]])
        return PBSetError(error, EBUSY,
            @"Refusing preference rollback because PosterBoard changed the refresh file");

    if ([record[@"OriginalExisted"] boolValue]) {
        NSString *backupPath = [record[@"BackupPath"] isKindOfClass:NSString.class]
            ? record[@"BackupPath"] : nil;
        NSData *backup = [NSData dataWithContentsOfFile:backupPath
            options:NSDataReadingMappedIfSafe error:error];
        if (!backup || ![PBDataDigest(backup) isEqualToString:record[@"OriginalSHA256"]])
            return PBSetError(error, EINVAL, @"PosterBoard preference backup failed verification");
        if (![backup writeToFile:path options:NSDataWritingAtomic error:error]) return NO;
    } else if (![[NSFileManager defaultManager] removeItemAtPath:path error:error]) {
        return NO;
    }
    return YES;
}

static NSString *PBImportPackage(NSString *package, NSError **outError)
{
    NSError *error = nil;
    NSArray<NSDictionary *> *descriptors = PBDiscoverDescriptors(package, &error);
    if (!descriptors) {
        if (outError) *outError = error;
        return nil;
    }
    NSDictionary *context = PBPosterBoardContext(&error);
    if (!context) {
        if (outError) *outError = error;
        return nil;
    }

    NSMutableArray<NSString *> *createdParents = [NSMutableArray array];
    NSMutableArray<NSString *> *stagingPaths = [NSMutableArray array];
    NSMutableArray<NSString *> *installedPaths = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *manifestEntries = [NSMutableArray array];
    NSMutableSet<NSNumber *> *identifiers = [NSMutableSet set];
    NSString *transaction = NSUUID.UUID.UUIDString.uppercaseString;
    NSDictionary *refreshRecord = nil;
    BOOL success = NO;

    for (NSDictionary *descriptor in descriptors) {
        NSString *providerRoot = [context[@"Extensions"]
            stringByAppendingPathComponent:descriptor[@"Provider"]];
        NSString *descriptorRoot = [providerRoot stringByAppendingPathComponent:@"descriptors"];
        if (!PBEnsureTargetDirectory(providerRoot, createdParents, &error) ||
            !PBEnsureTargetDirectory(descriptorRoot, createdParents, &error)) break;

        NSString *uuid = NSUUID.UUID.UUIDString.uppercaseString;
        NSString *target = [descriptorRoot stringByAppendingPathComponent:uuid];
        NSString *staging = [descriptorRoot stringByAppendingPathComponent:
            [NSString stringWithFormat:@".%@.partial-%@", uuid, NSUUID.UUID.UUIDString]];
        NSInteger wallpaperIdentifier = 0;
        do {
            wallpaperIdentifier = (NSInteger)arc4random_uniform(90001) + 9999;
        } while ([identifiers containsObject:@(wallpaperIdentifier)]);
        [identifiers addObject:@(wallpaperIdentifier)];
        [stagingPaths addObject:staging];

        if (!PBCopyTree(descriptor[@"Source"], staging, descriptor[@"Entries"], &error) ||
            !PBRewriteDescriptor(staging, wallpaperIdentifier, &error)) break;
        PBTreeStats finalStats = {0};
        NSString *digest = PBTreeDigest(staging, &finalStats, &error);
        if (!digest) break;
        if (renameatx_np(AT_FDCWD, staging.fileSystemRepresentation,
                        AT_FDCWD, target.fileSystemRepresentation, RENAME_EXCL) != 0) {
            PBSetError(&error, errno, @"Could not commit descriptor %@ (errno %d)", uuid, errno);
            break;
        }
        [stagingPaths removeObject:staging];
        [installedPaths addObject:target];
        [manifestEntries addObject:@{
            @"SourceName": descriptor[@"SourceName"],
            @"Provider": descriptor[@"Provider"],
            @"DescriptorRoot": descriptorRoot,
            @"UUID": uuid,
            @"WallpaperIdentifier": @(wallpaperIdentifier),
            @"Target": target,
            @"SHA256": digest,
            @"FileCount": @(finalStats.files),
            @"ByteCount": @(finalStats.bytes),
        }];
    }

    if (manifestEntries.count == descriptors.count)
        refreshRecord = PBApplyRefreshPreferences(context, transaction, &error);

    if (manifestEntries.count == descriptors.count && refreshRecord) {
        NSDictionary *manifest = @{
            @"Version": @2,
            @"Status": @"installed",
            @"Transaction": transaction,
            @"CreatedAt": NSDate.date,
            @"Package": package.lastPathComponent ?: @"",
            @"PosterBoardRoot": context[@"Root"],
            @"Structure": context[@"Structure"],
            @"CreatedParents": createdParents,
            @"Entries": manifestEntries,
            @"RefreshPreference": refreshRecord,
        };
        NSString *manifestPath = [PBBackupsDirectory() stringByAppendingPathComponent:
            [transaction stringByAppendingPathExtension:@"plist"]];
        if (PBWriteManifest(manifest, manifestPath, &error)) success = YES;
    }

    if (!success) {
        if (refreshRecord) PBRestoreRefreshPreferences(refreshRecord, context, nil);
        NSString *backupPath = refreshRecord[@"BackupPath"];
        if (backupPath.length) [[NSFileManager defaultManager] removeItemAtPath:backupPath error:nil];
        for (NSString *path in stagingPaths) PBRemoveTree(path);
        for (NSString *path in installedPaths.reverseObjectEnumerator) PBRemoveTree(path);
        PBCleanupEmptyDirectories(createdParents);
        if (!error) PBSetError(&error, EIO, @"Import transaction did not complete");
        if (outError) *outError = error;
        return nil;
    }
    return [NSString stringWithFormat:
        @"Imported %lu descriptor%@ into PosterBoard structure %@ and applied the backed-up refresh preferences. Open Settings > Wallpaper.",
        (unsigned long)manifestEntries.count, manifestEntries.count == 1 ? @"" : @"s",
        context[@"Structure"]];
}

static NSArray<NSString *> *PBManifestPaths(void)
{
    NSArray<NSString *> *names = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:PBBackupsDirectory() error:nil] ?: @[];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSString *name in names) {
        if (![name.pathExtension.lowercaseString isEqualToString:@"plist"]) continue;
        [paths addObject:[PBBackupsDirectory() stringByAppendingPathComponent:name]];
    }
    [paths sortUsingComparator:^NSComparisonResult(NSString *left, NSString *right) {
        NSDictionary *leftAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:left error:nil];
        NSDictionary *rightAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:right error:nil];
        return [rightAttributes[NSFileModificationDate]
            compare:leftAttributes[NSFileModificationDate]];
    }];
    return paths;
}

static BOOL PBPathIsInside(NSString *path, NSString *root)
{
    NSString *candidate = path.stringByStandardizingPath;
    NSString *base = root.stringByStandardizingPath;
    return [candidate hasPrefix:[base stringByAppendingString:@"/"]];
}

static NSString *PBRollBackLatest(NSError **outError)
{
    NSString *manifestPath = PBManifestPaths().firstObject;
    if (!manifestPath) {
        PBSetError(outError, ENOENT, @"There is no installed wallpaper transaction to roll back");
        return nil;
    }
    NSDictionary *manifest = [NSDictionary dictionaryWithContentsOfFile:manifestPath];
    NSArray<NSDictionary *> *entries = [manifest[@"Entries"] isKindOfClass:NSArray.class]
        ? manifest[@"Entries"] : nil;
    if ((![[manifest objectForKey:@"Version"] isEqual:@1] &&
         ![[manifest objectForKey:@"Version"] isEqual:@2]) || entries.count == 0) {
        PBSetError(outError, EINVAL, @"The newest rollback manifest is invalid");
        return nil;
    }
    NSError *error = nil;
    NSDictionary *context = PBPosterBoardContext(&error);
    if (!context) {
        if (outError) *outError = error;
        return nil;
    }
    for (NSDictionary *entry in entries) {
        NSString *target = [entry[@"Target"] isKindOfClass:NSString.class] ? entry[@"Target"] : nil;
        NSString *descriptorRoot = [entry[@"DescriptorRoot"] isKindOfClass:NSString.class]
            ? entry[@"DescriptorRoot"] : nil;
        NSString *uuid = [entry[@"UUID"] isKindOfClass:NSString.class] ? entry[@"UUID"] : nil;
        NSUUID *parsedUUID = [[NSUUID alloc] initWithUUIDString:uuid];
        if (!target || !descriptorRoot || !parsedUUID ||
            ![descriptorRoot.lastPathComponent isEqualToString:@"descriptors"] ||
            !PBPathIsInside(descriptorRoot, context[@"Extensions"]) ||
            ![target.stringByStandardizingPath isEqualToString:
                [descriptorRoot stringByAppendingPathComponent:uuid].stringByStandardizingPath]) {
            PBSetError(outError, EPERM, @"Rollback manifest contains an out-of-scope target");
            return nil;
        }
        PBTreeStats stats = {0};
        NSString *digest = PBTreeDigest(target, &stats, &error);
        if (!digest || ![digest isEqualToString:entry[@"SHA256"]]) {
            if (!error) PBSetError(&error, EBUSY,
                @"Refusing rollback because %@ changed after import", target.lastPathComponent);
            if (outError) *outError = error;
            return nil;
        }
    }

    NSString *reportPath = [PBReportsDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"Rollback-%@", manifestPath.lastPathComponent]];
    NSMutableDictionary *report = [manifest mutableCopy];
    report[@"Status"] = @"rollback-pending";
    report[@"RollbackStartedAt"] = NSDate.date;
    if (!PBWriteManifest(report, reportPath, &error)) {
        if (outError) *outError = error;
        return nil;
    }
    NSDictionary *refreshRecord = [manifest[@"RefreshPreference"]
        isKindOfClass:NSDictionary.class] ? manifest[@"RefreshPreference"] : nil;
    if (refreshRecord && !PBRestoreRefreshPreferences(refreshRecord, context, &error)) {
        if (outError) *outError = error;
        return nil;
    }
    NSUInteger removed = 0;
    for (NSDictionary *entry in entries.reverseObjectEnumerator) {
        if (![[NSFileManager defaultManager] removeItemAtPath:entry[@"Target"] error:&error]) break;
        removed++;
    }
    if (removed != entries.count) {
        if (outError) *outError = error ?: [NSError errorWithDomain:PBErrorDomain code:EIO
            userInfo:@{NSLocalizedDescriptionKey: @"Rollback stopped before all descriptors were removed"}];
        return nil;
    }
    PBCleanupEmptyDirectories(manifest[@"CreatedParents"] ?: @[]);
    NSString *preferenceBackup = refreshRecord[@"BackupPath"];
    if (preferenceBackup.length)
        [[NSFileManager defaultManager] removeItemAtPath:preferenceBackup error:nil];
    report[@"Status"] = @"rolled-back";
    report[@"RolledBackAt"] = NSDate.date;
    PBWriteManifest(report, reportPath, nil);
    [[NSFileManager defaultManager] removeItemAtPath:manifestPath error:nil];
    return [NSString stringWithFormat:@"Removed %lu imported descriptor%@ and restored the refresh preferences.",
        (unsigned long)removed, removed == 1 ? @"" : @"s"];
}

static NSString *PBInspection(NSError **outError)
{
    NSError *error = nil;
    NSDictionary *context = PBPosterBoardContext(&error);
    if (!context) {
        if (outError) *outError = error;
        return nil;
    }
    NSArray *providers = @[
        @"com.apple.WallpaperKit.CollectionsPoster",
        @"com.apple.PhotosUIPrivate.PhotosPosterProvider",
        @"com.apple.MercuryPoster",
    ];
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObject:
        [NSString stringWithFormat:@"Active structure: %@", context[@"Structure"]]];
    for (NSString *provider in providers) {
        NSString *path = [[context[@"Extensions"] stringByAppendingPathComponent:provider]
            stringByAppendingPathComponent:@"descriptors"];
        NSArray<NSString *> *names = PBDirectoryNames(path, nil) ?: @[];
        NSUInteger count = 0;
        for (NSString *name in names) {
            struct stat status = {0};
            NSString *child = [path stringByAppendingPathComponent:name];
            if (lstat(child.fileSystemRepresentation, &status) == 0 && S_ISDIR(status.st_mode))
                count++;
        }
        [lines addObject:[NSString stringWithFormat:@"%@: %lu descriptors",
            provider.lastPathComponent, (unsigned long)count]];
    }
    [lines addObject:@"Inspection is read-only."];
    return [lines componentsJoinedByString:@"\n"];
}

static NSArray<NSString *> *PBPackageDirectories(void)
{
    NSArray<NSString *> *names = PBDirectoryNames(PBImportsDirectory(), nil) ?: @[];
    NSMutableArray<NSString *> *packages = [NSMutableArray array];
    for (NSString *name in names) {
        if (PBSkippedName(name)) continue;
        NSString *path = [PBImportsDirectory() stringByAppendingPathComponent:name];
        struct stat status = {0};
        if (lstat(path.fileSystemRepresentation, &status) == 0 && S_ISDIR(status.st_mode))
            [packages addObject:path];
        if (packages.count == 10) break;
    }
    return packages;
}

static void PBInstallBundledSamples(void)
{
    NSString *sampleRoot = [NSBundle.mainBundle.resourcePath
        stringByAppendingPathComponent:@"WallpaperSamples"];
    if (!PBDirectoryNoSymlink(sampleRoot, YES, nil)) return;
    NSArray<NSString *> *names = PBDirectoryNames(sampleRoot, nil) ?: @[];
    NSFileManager *manager = NSFileManager.defaultManager;
    for (NSString *name in names) {
        if (PBSkippedName(name)) continue;
        NSString *source = [sampleRoot stringByAppendingPathComponent:name];
        NSString *destination = [PBImportsDirectory() stringByAppendingPathComponent:name];
        if (![manager fileExistsAtPath:destination]) {
            NSError *error = nil;
            if ([manager copyItemAtPath:source toPath:destination error:&error])
                NSLog(@"[WallpaperLab] installed bundled sample %@", name);
            else
                NSLog(@"[WallpaperLab] bundled sample copy failed %@ detail=%@", name, error);
        }
    }
}

static void PBStartAutomaticCipherImport(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *package = [PBImportsDirectory()
            stringByAppendingPathComponent:@"Cipher by mightycooldude12"];
        NSString *reportPath = [PBReportsDirectory()
            stringByAppendingPathComponent:@"Automatic-Cipher-Import.plist"];
        NSDictionary *existing = [NSDictionary dictionaryWithContentsOfFile:reportPath];
        if ([existing[@"Status"] isEqualToString:@"success"]) return;
        if (!PBDirectoryNoSymlink(package, YES, nil)) return;
        for (NSString *manifestPath in PBManifestPaths()) {
            NSDictionary *manifest = [NSDictionary dictionaryWithContentsOfFile:manifestPath];
            if ([manifest[@"Status"] isEqualToString:@"installed"] &&
                [manifest[@"Version"] isEqual:@2] &&
                [manifest[@"Package"] isEqualToString:package.lastPathComponent]) {
                NSString *message = @"Cipher was already imported with refresh preferences. Open Settings > Wallpaper.";
                NSDictionary *report = @{@"Version": @1, @"Package": package.lastPathComponent,
                    @"Status": @"success", @"AttemptedAt": NSDate.date, @"Message": message};
                PBWriteManifest(report, reportPath, nil);
                [message writeToFile:[PBWorkspace() stringByAppendingPathComponent:
                    @"CIPHER READY - OPEN SETTINGS.txt"] atomically:YES
                    encoding:NSUTF8StringEncoding error:nil];
                return;
            }
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
            dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSError *error = nil;
                NSString *result = PBImportPackage(package, &error);
                BOOL success = result != nil;
                NSDictionary *report = @{
                    @"Version": @1,
                    @"Package": package.lastPathComponent,
                    @"Status": success ? @"success" : @"failed",
                    @"AttemptedAt": NSDate.date,
                    @"Message": result ?: error.localizedDescription ?: @"Unknown failure",
                };
                PBWriteManifest(report, reportPath, nil);
                NSString *readyPath = [PBWorkspace()
                    stringByAppendingPathComponent:@"CIPHER READY - OPEN SETTINGS.txt"];
                NSString *failurePath = [PBWorkspace()
                    stringByAppendingPathComponent:@"CIPHER IMPORT FAILED.txt"];
                NSFileManager *manager = NSFileManager.defaultManager;
                if (success) {
                    [manager removeItemAtPath:failurePath error:nil];
                    [result writeToFile:readyPath atomically:YES
                        encoding:NSUTF8StringEncoding error:nil];
                    NSLog(@"[WallpaperLab] automatic Cipher import succeeded: %@", result);
                } else {
                    [manager removeItemAtPath:readyPath error:nil];
                    [error.localizedDescription writeToFile:failurePath atomically:YES
                        encoding:NSUTF8StringEncoding error:nil];
                    NSLog(@"[WallpaperLab] automatic Cipher import failed: %@", error);
                }
            });
    });
}

static UIViewController *PBTopController(UIViewController *controller)
{
    while (controller) {
        UIViewController *next = controller.presentedViewController;
        if (!next && [controller isKindOfClass:UINavigationController.class])
            next = ((UINavigationController *)controller).visibleViewController;
        if (!next && [controller isKindOfClass:UITabBarController.class])
            next = ((UITabBarController *)controller).selectedViewController;
        if (!next || next == controller) break;
        controller = next;
    }
    return controller;
}

@interface PBWallpaperFeatureController : NSObject
@property(nonatomic, weak) UIViewController *presenter;
@property(nonatomic) dispatch_queue_t operationQueue;
+ (instancetype)sharedController;
- (void)showMenu:(UIBarButtonItem *)sender;
@end

@implementation PBWallpaperFeatureController

+ (instancetype)sharedController
{
    static PBWallpaperFeatureController *controller;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        controller = [PBWallpaperFeatureController new];
        controller.operationQueue = dispatch_queue_create(
            "local.filzamod.posterboard", DISPATCH_QUEUE_SERIAL);
    });
    return controller;
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message
{
    UIViewController *presenter = PBTopController(self.presenter);
    if (!presenter) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)runOperationWithTitle:(NSString *)title block:(NSString *(^)(NSError **error))block
{
    dispatch_async(self.operationQueue, ^{
        NSError *error = nil;
        NSString *message = block(&error);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showAlertWithTitle:message ? title : @"Wallpaper operation failed"
                message:message ?: error.localizedDescription ?: @"Unknown error"];
        });
    });
}

- (void)confirmImport:(NSString *)package
{
    UIViewController *presenter = PBTopController(self.presenter);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Import wallpaper package?"
        message:[NSString stringWithFormat:
            @"%@ will add only new descriptor directories. Existing PosterBoard files are not overwritten.",
            package.lastPathComponent]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Import" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            [weakSelf runOperationWithTitle:@"Wallpaper imported"
                block:^NSString *(NSError **error) { return PBImportPackage(package, error); }];
        }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)confirmRollback
{
    UIViewController *presenter = PBTopController(self.presenter);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Roll back last import?"
        message:@"Rollback removes only descriptors from the newest Filza Mod manifest, and refuses if their hashes changed."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Roll Back" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) {
            [weakSelf runOperationWithTitle:@"Wallpaper rollback complete"
                block:^NSString *(NSError **error) { return PBRollBackLatest(error); }];
        }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)showMenu:(UIBarButtonItem *)sender
{
    UIViewController *presenter = PBTopController(self.presenter);
    if (!presenter) return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Wallpaper Lab"
        message:@"Bounded Nugget-style PosterBoard descriptor import"
        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Inspect PosterBoard"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [weakSelf runOperationWithTitle:@"PosterBoard inspection"
                block:^NSString *(NSError **error) { return PBInspection(error); }];
        }]];
    for (NSString *package in PBPackageDirectories()) {
        [sheet addAction:[UIAlertAction actionWithTitle:
            [@"Import " stringByAppendingString:package.lastPathComponent]
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                [weakSelf confirmImport:package];
            }]];
    }
    if (PBManifestPaths().count > 0) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Roll Back Last Import"
            style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
                [weakSelf confirmRollback];
            }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Help" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            [weakSelf showAlertWithTitle:@"Wallpaper Lab"
                message:@"Cipher imports automatically on first launch. Other extracted .tendies packages can be placed in [MHA-C2] Wallpaper Lab/Imports. Container-style packages are rejected. Imports are capped at 10 descriptors and 256 MiB. The refresh preference is backed up for rollback; the PosterBoard database is not changed."];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.barButtonItem = sender;
    [presenter presentViewController:sheet animated:YES completion:nil];
}

@end

void PBWallpaperFeatureStart(void)
{
    NSFileManager *manager = NSFileManager.defaultManager;
    for (NSString *directory in @[PBWorkspace(), PBImportsDirectory(), PBBackupsDirectory(),
                                   PBReportsDirectory()]) {
        [manager createDirectoryAtPath:directory withIntermediateDirectories:YES
            attributes:@{NSFilePosixPermissions: @0700} error:nil];
    }
    PBInstallBundledSamples();
    NSString *readme = [PBWorkspace() stringByAppendingPathComponent:@"README.txt"];
    NSString *text = @"Wallpaper Lab\n\n"
        @"Primitive: MHA-MCM class 2 application-data lookup for com.apple.PosterBoard.\n"
        @"This folder is local staging. PosterBoard access starts only during a Wallpaper Lab action.\n\n"
        @"The bundled GPL-licensed Cipher wallpaper imports automatically on first launch.\n"
        @"When CIPHER READY appears here, open Settings > Wallpaper.\n\n"
        @"Other descriptor-style .tendies packages may be extracted into Imports.\n"
        @"Only descriptor-style packages are supported. Container-style packages are rejected.\n"
        @"Imports add new UUID directories and never overwrite the PosterBoard database or an existing descriptor.\n"
        @"Nugget's refresh keys are merged into the preference file after an exact backup is saved.\n"
        @"Rollback verifies SHA-256 hashes before restoring the preference and removing the descriptor.\n";
    [text writeToFile:readme atomically:YES encoding:NSUTF8StringEncoding error:nil];
    PBStartAutomaticCipherImport();
}

void PBWallpaperConfigureBrowser(UIViewController *controller, NSString *currentPath)
{
    if (!controller) return;
    PBWallpaperFeatureController *feature = [PBWallpaperFeatureController sharedController];
    NSString *workspace = PBCanonicalPath(PBWorkspace());
    BOOL visible = [PBCanonicalPath(currentPath) isEqualToString:workspace];
    NSMutableArray<UIBarButtonItem *> *items =
        [NSMutableArray arrayWithArray:controller.navigationItem.rightBarButtonItems ?: @[]];
    NSIndexSet *ours = [items indexesOfObjectsPassingTest:
        ^BOOL(UIBarButtonItem *item, __unused NSUInteger index, __unused BOOL *stop) {
            return item.tag == PBButtonTag;
        }];
    [items removeObjectsAtIndexes:ours];
    if (visible) {
        feature.presenter = controller;
        UIBarButtonItem *button = [[UIBarButtonItem alloc] initWithTitle:@"Wallpaper"
            style:UIBarButtonItemStylePlain target:feature action:@selector(showMenu:)];
        button.tag = PBButtonTag;
        // Filza continuously restores its Edit item. At the lab root the
        // wallpaper action replaces it; Edit returns in child directories.
        [items removeAllObjects];
        [items addObject:button];
        NSLog(@"[WallpaperLab] installed navigation action class=%@ path=%@ canonical=%@",
            NSStringFromClass(controller.class), currentPath, PBCanonicalPath(currentPath));
    }
    controller.navigationItem.rightBarButtonItems = items;
}
