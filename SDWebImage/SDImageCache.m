/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "SDImageCache.h"
#import "SDWebImageDecoder.h"
#import "UIImage+MultiFormat.h"
#import <CommonCrypto/CommonDigest.h>
#import "UIImage+GIF.h"
#import "NSData+ImageContentType.h"
#import "NSImage+WebCache.h"

// See https://github.com/rs/SDWebImage/pull/1141 for discussion
@interface AutoPurgeCache : NSCache
@end
// 注册了UIApplicationDidReceiveMemoryWarningNotification的NSCache
@implementation AutoPurgeCache

- (nonnull instancetype)init {
    self = [super init];
    if (self) {
#if SD_UIKIT
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(removeAllObjects) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
#endif
    }
    return self;
}

- (void)dealloc {
#if SD_UIKIT
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
#endif
}

@end


FOUNDATION_STATIC_INLINE NSUInteger SDCacheCostForImage(UIImage *image) {
#if SD_MAC
    return image.size.height * image.size.width;
#elif SD_UIKIT || SD_WATCH
    return image.size.height * image.size.width * image.scale * image.scale;
#endif
}

@interface SDImageCache ()

#pragma mark - Properties
@property (strong, nonatomic, nonnull) NSCache *memCache; //默认名为@"com.hackemist.SDWebImageCache.default"
@property (strong, nonatomic, nonnull) NSString *diskCachePath; // /NSCachesDirectory/default/com.hackemist.SDWebImageCache.default
@property (strong, nonatomic, nullable) NSMutableArray<NSString *> *customPaths;
@property (SDDispatchQueueSetterSementics, nonatomic, nullable) dispatch_queue_t ioQueue;

@end


@implementation SDImageCache {
    NSFileManager *_fileManager;
}

#pragma mark - Singleton, init, dealloc

+ (nonnull instancetype)sharedImageCache {
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{
        instance = [self new];
    });
    return instance;
}

- (instancetype)init {
    return [self initWithNamespace:@"default"];
}

- (nonnull instancetype)initWithNamespace:(nonnull NSString *)ns {
    NSString *path = [self makeDiskCachePath:ns]; // 返回NSCachesDirectory路径附加ns
    return [self initWithNamespace:ns diskCacheDirectory:path];
}

- (nonnull instancetype)initWithNamespace:(nonnull NSString *)ns
                       diskCacheDirectory:(nonnull NSString *)directory {
    if ((self = [super init])) {
        NSString *fullNamespace = [@"com.hackemist.SDWebImageCache." stringByAppendingString:ns];
        
        // Create IO serial queue
        _ioQueue = dispatch_queue_create("com.hackemist.SDWebImageCache", DISPATCH_QUEUE_SERIAL);
        
        _config = [[SDImageCacheConfig alloc] init];
        
        // Init the memory cache
        _memCache = [[AutoPurgeCache alloc] init];// 注册了UIApplicationDidReceiveMemoryWarningNotification的NSCache
        _memCache.name = fullNamespace;

        // Init the disk cache
        if (directory != nil) {
            _diskCachePath = [directory stringByAppendingPathComponent:fullNamespace];
        } else {
            NSString *path = [self makeDiskCachePath:ns];
            _diskCachePath = path;
        }

        dispatch_sync(_ioQueue, ^{
            _fileManager = [NSFileManager new];
        });

#if SD_UIKIT
        // Subscribe to app events
        // 内存快用完时清理内存缓存
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(clearMemory)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];
        // 用户强制关闭应用时清理磁盘缓存
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(deleteOldFiles)
                                                     name:UIApplicationWillTerminateNotification
                                                   object:nil];
        // 一进入后台就清理磁盘缓存
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(backgroundDeleteOldFiles)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
#endif
    }

    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    SDDispatchQueueRelease(_ioQueue);
}
// 检查当前所在queue是否是self.ioQueue
- (void)checkIfQueueIsIOQueue {
    const char *currentQueueLabel = dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL);
    const char *ioQueueLabel = dispatch_queue_get_label(self.ioQueue);
    if (strcmp(currentQueueLabel, ioQueueLabel) != 0) {
        NSLog(@"This method should be called from the ioQueue");
    }
}

#pragma mark - Cache paths

- (void)addReadOnlyCachePath:(nonnull NSString *)path {
    if (!self.customPaths) {
        self.customPaths = [NSMutableArray new];
    }

    if (![self.customPaths containsObject:path]) {
        [self.customPaths addObject:path];
    }
}

- (nullable NSString *)cachePathForKey:(nullable NSString *)key inPath:(nonnull NSString *)path {
    NSString *filename = [self cachedFileNameForKey:key];
    return [path stringByAppendingPathComponent:filename];
}
//key对应的文件在默认缓存文件夹下的文件路径，/NSCachesDirectory/default/com.hackemist.SDWebImageCache.default／MD5.extension（可能没有.extension）
- (nullable NSString *)defaultCachePathForKey:(nullable NSString *)key {
    return [self cachePathForKey:key inPath:self.diskCachePath];
}
// key用MD5加密的结果加格式作为文件名，MD5.extension（可能没有.extension）
- (nullable NSString *)cachedFileNameForKey:(nullable NSString *)key {
    const char *str = key.UTF8String;
    if (str == NULL) {
        str = "";
    }
    unsigned char r[CC_MD5_DIGEST_LENGTH];// CC_MD5_DIGEST_LENGTH定义为16
    CC_MD5(str, (CC_LONG)strlen(str), r);
    NSString *filename = [NSString stringWithFormat:@"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%@",
                          r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9], r[10],
                          r[11], r[12], r[13], r[14], r[15], [key.pathExtension isEqualToString:@""] ? @"" : [NSString stringWithFormat:@".%@", key.pathExtension]];

    return filename;
}
// 返回/NSCachesDirectory/fullNamespace
- (nullable NSString *)makeDiskCachePath:(nonnull NSString*)fullNamespace {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    return [paths[0] stringByAppendingPathComponent:fullNamespace];
}

#pragma mark - Store Ops

- (void)storeImage:(nullable UIImage *)image
            forKey:(nullable NSString *)key
        completion:(nullable SDWebImageNoParamsBlock)completionBlock {
    [self storeImage:image imageData:nil forKey:key toDisk:YES completion:completionBlock];
}

- (void)storeImage:(nullable UIImage *)image
            forKey:(nullable NSString *)key
            toDisk:(BOOL)toDisk
        completion:(nullable SDWebImageNoParamsBlock)completionBlock {
    [self storeImage:image imageData:nil forKey:key toDisk:toDisk completion:completionBlock];
}
// 异步在self.ioQueue上保存为/NSCachesDirectory/default/com.hackemist.SDWebImageCache.default／MD5.extension，若设置保存到内存缓存，则也保存一份到self.memCache
- (void)storeImage:(nullable UIImage *)image
         imageData:(nullable NSData *)imageData
            forKey:(nullable NSString *)key
            toDisk:(BOOL)toDisk
        completion:(nullable SDWebImageNoParamsBlock)completionBlock {
    if (!image || !key) {
        if (completionBlock) {
            completionBlock();
        }
        return;
    }
    // if memory cache is enabled
    if (self.config.shouldCacheImagesInMemory) {
        NSUInteger cost = SDCacheCostForImage(image);
        [self.memCache setObject:image forKey:key cost:cost];
    }
    
    if (toDisk) {
        dispatch_async(self.ioQueue, ^{
            NSData *data = imageData;
            
            if (!data && image) {
                SDImageFormat imageFormatFromData = [NSData sd_imageFormatForImageData:data];
                data = [image sd_imageDataAsFormat:imageFormatFromData];
            }
            
            [self storeImageDataToDisk:data forKey:key];
            if (completionBlock) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionBlock();
                });
            }
        });
    } else {
        if (completionBlock) {
            completionBlock();
        }
    }
}
// 同步在self.ioQueue上保存为/NSCachesDirectory/default/com.hackemist.SDWebImageCache.default／MD5.extension
- (void)storeImageDataToDisk:(nullable NSData *)imageData forKey:(nullable NSString *)key {
    if (!imageData || !key) {
        return;
    }
    
    [self checkIfQueueIsIOQueue];
    
    if (![_fileManager fileExistsAtPath:_diskCachePath]) {
        [_fileManager createDirectoryAtPath:_diskCachePath withIntermediateDirectories:YES attributes:nil error:NULL];
    }
    
    // get cache Path for image key
    NSString *cachePathForKey = [self defaultCachePathForKey:key];
    // transform to NSUrl
    NSURL *fileURL = [NSURL fileURLWithPath:cachePathForKey];
    
    [_fileManager createFileAtPath:cachePathForKey contents:imageData attributes:nil];
    
    // disable iCloud backup
    if (self.config.shouldDisableiCloud) {
        [fileURL setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    }
}

#pragma mark - Query and Retrieve Ops

- (void)diskImageExistsWithKey:(nullable NSString *)key completion:(nullable SDWebImageCheckCacheCompletionBlock)completionBlock {
    dispatch_async(_ioQueue, ^{
        BOOL exists = [_fileManager fileExistsAtPath:[self defaultCachePathForKey:key]];

        // fallback because of https://github.com/rs/SDWebImage/pull/976 that added the extension to the disk file name
        // checking the key with and without the extension
        if (!exists) {
            exists = [_fileManager fileExistsAtPath:[self defaultCachePathForKey:key].stringByDeletingPathExtension];
        }

        if (completionBlock) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionBlock(exists);
            });
        }
    });
}

- (nullable UIImage *)imageFromMemoryCacheForKey:(nullable NSString *)key {
    return [self.memCache objectForKey:key];
}

- (nullable UIImage *)imageFromDiskCacheForKey:(nullable NSString *)key {
    UIImage *diskImage = [self diskImageForKey:key];
    if (diskImage && self.config.shouldCacheImagesInMemory) {
        NSUInteger cost = SDCacheCostForImage(diskImage);
        [self.memCache setObject:diskImage forKey:key cost:cost];
    }

    return diskImage;
}

- (nullable UIImage *)imageFromCacheForKey:(nullable NSString *)key {
    // First check the in-memory cache...
    UIImage *image = [self imageFromMemoryCacheForKey:key];
    if (image) {
        return image;
    }
    
    // Second check the disk cache...
    image = [self imageFromDiskCacheForKey:key];
    return image;
}
// 先在默认文件夹中找，再到自定义的文件夹中找
- (nullable NSData *)diskImageDataBySearchingAllPathsForKey:(nullable NSString *)key {
    NSString *defaultPath = [self defaultCachePathForKey:key];
    NSData *data = [NSData dataWithContentsOfFile:defaultPath];
    if (data) {
        return data;
    }

    // fallback because of https://github.com/rs/SDWebImage/pull/976 that added the extension to the disk file name
    // checking the key with and without the extension
    data = [NSData dataWithContentsOfFile:defaultPath.stringByDeletingPathExtension];
    if (data) {
        return data;
    }

    NSArray<NSString *> *customPaths = [self.customPaths copy];
    for (NSString *path in customPaths) {
        NSString *filePath = [self cachePathForKey:key inPath:path];
        NSData *imageData = [NSData dataWithContentsOfFile:filePath];
        if (imageData) {
            return imageData;
        }

        // fallback because of https://github.com/rs/SDWebImage/pull/976 that added the extension to the disk file name
        // checking the key with and without the extension
        imageData = [NSData dataWithContentsOfFile:filePath.stringByDeletingPathExtension];
        if (imageData) {
            return imageData;
        }
    }

    return nil;
}
// 根据key在磁盘缓存中找到imageData，然后将其转化为image，调整scale，根据需要解压，返回
- (nullable UIImage *)diskImageForKey:(nullable NSString *)key {
    NSData *data = [self diskImageDataBySearchingAllPathsForKey:key];
    if (data) {
        UIImage *image = [UIImage sd_imageWithData:data];
        image = [self scaledImageForKey:key image:image];
        if (self.config.shouldDecompressImages) {
            image = [UIImage decodedImageWithImage:image];
        }
        return image;
    }
    else {
        return nil;
    }
}
// 从key中获取image的scale信息（是否包含"@2x."/@"3x."），然后将image转化为对应scale的image
- (nullable UIImage *)scaledImageForKey:(nullable NSString *)key image:(nullable UIImage *)image {
    return SDScaledImageForKey(key, image);
}
// 先在内存缓存中中查找，若找到了，同步执行completedBlock；若未找到，则返回一个operation，异步到self.ioQueue中去磁盘缓存查询，找到后，在内存缓存中缓存，然后返回到mainQueue中执行completedBlock
- (nullable NSOperation *)queryCacheOperationForKey:(nullable NSString *)key done:(nullable SDCacheQueryCompletedBlock)doneBlock {
    if (!key) {
        if (doneBlock) {
            doneBlock(nil, nil, SDImageCacheTypeNone);
        }
        return nil;
    }

    // First check the in-memory cache...
    UIImage *image = [self imageFromMemoryCacheForKey:key];
    if (image) {
        NSData *diskData = nil;
        if ([image isGIF]) {
            diskData = [self diskImageDataBySearchingAllPathsForKey:key];
        }
        if (doneBlock) {
            doneBlock(image, diskData, SDImageCacheTypeMemory);
        }
        return nil;
    }

    NSOperation *operation = [NSOperation new];
    dispatch_async(self.ioQueue, ^{
        if (operation.isCancelled) {
            // do not call the completion if cancelled
            return;
        }

        @autoreleasepool {
            NSData *diskData = [self diskImageDataBySearchingAllPathsForKey:key];
            UIImage *diskImage = [self diskImageForKey:key];
            if (diskImage && self.config.shouldCacheImagesInMemory) {
                NSUInteger cost = SDCacheCostForImage(diskImage);
                [self.memCache setObject:diskImage forKey:key cost:cost];
            }

            if (doneBlock) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    doneBlock(diskImage, diskData, SDImageCacheTypeDisk);
                });
            }
        }
    });

    return operation;
}

#pragma mark - Remove Ops

- (void)removeImageForKey:(nullable NSString *)key withCompletion:(nullable SDWebImageNoParamsBlock)completion {
    [self removeImageForKey:key fromDisk:YES withCompletion:completion];
}
// 内存缓存中有image，移除，然后异步到从磁盘缓存中移除image，移除后再回到主线程执行completionBlock
- (void)removeImageForKey:(nullable NSString *)key fromDisk:(BOOL)fromDisk withCompletion:(nullable SDWebImageNoParamsBlock)completion {
    if (key == nil) {
        return;
    }

    if (self.config.shouldCacheImagesInMemory) {
        [self.memCache removeObjectForKey:key];
    }

    if (fromDisk) {
        dispatch_async(self.ioQueue, ^{
            [_fileManager removeItemAtPath:[self defaultCachePathForKey:key] error:nil];
            
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion();
                });
            }
        });
    } else if (completion){
        completion();
    }
    
}

# pragma mark - Mem Cache settings

- (void)setMaxMemoryCost:(NSUInteger)maxMemoryCost {
    self.memCache.totalCostLimit = maxMemoryCost;
}

- (NSUInteger)maxMemoryCost {
    return self.memCache.totalCostLimit;
}

- (NSUInteger)maxMemoryCountLimit {
    return self.memCache.countLimit;
}

- (void)setMaxMemoryCountLimit:(NSUInteger)maxCountLimit {
    self.memCache.countLimit = maxCountLimit;
}

#pragma mark - Cache clean Ops

- (void)clearMemory {
    [self.memCache removeAllObjects];
}
//直接将整个/NSCachesDirectory/default/com.hackemist.SDWebImageCache.default文件夹删掉，然后建一个空的文件夹
- (void)clearDiskOnCompletion:(nullable SDWebImageNoParamsBlock)completion {
    dispatch_async(self.ioQueue, ^{
        [_fileManager removeItemAtPath:self.diskCachePath error:nil];
        [_fileManager createDirectoryAtPath:self.diskCachePath
                withIntermediateDirectories:YES
                                 attributes:nil
                                      error:NULL];

        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion();
            });
        }
    });
}

- (void)deleteOldFiles {
    [self deleteOldFilesWithCompletionBlock:nil];
}
// 删除磁盘缓存中的过期文件，若剩下的文件总大小比self.config.maxCacheSize大，则按修改日期从远到近删除文件直到总大小小于self.config.maxCacheSize的一半
- (void)deleteOldFilesWithCompletionBlock:(nullable SDWebImageNoParamsBlock)completionBlock {
    dispatch_async(self.ioQueue, ^{
        NSURL *diskCacheURL = [NSURL fileURLWithPath:self.diskCachePath isDirectory:YES];
        NSArray<NSString *> *resourceKeys = @[NSURLIsDirectoryKey, NSURLContentModificationDateKey, NSURLTotalFileAllocatedSizeKey];

        // This enumerator prefetches useful properties for our cache files.
        NSDirectoryEnumerator *fileEnumerator = [_fileManager enumeratorAtURL:diskCacheURL
                                                   includingPropertiesForKeys:resourceKeys
                                                                      options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                 errorHandler:NULL];

        NSDate *expirationDate = [NSDate dateWithTimeIntervalSinceNow:-self.config.maxCacheAge];
        NSMutableDictionary<NSURL *, NSDictionary<NSString *, id> *> *cacheFiles = [NSMutableDictionary dictionary];
        NSUInteger currentCacheSize = 0;

        // Enumerate all of the files in the cache directory.  This loop has two purposes:
        //
        //  1. Removing files that are older than the expiration date.
        //  2. Storing file attributes for the size-based cleanup pass.
        NSMutableArray<NSURL *> *urlsToDelete = [[NSMutableArray alloc] init];
        for (NSURL *fileURL in fileEnumerator) {
            NSError *error;
            NSDictionary<NSString *, id> *resourceValues = [fileURL resourceValuesForKeys:resourceKeys error:&error];

            // Skip directories and errors.
            if (error || !resourceValues || [resourceValues[NSURLIsDirectoryKey] boolValue]) {
                continue;
            }

            // Remove files that are older than the expiration date;
            NSDate *modificationDate = resourceValues[NSURLContentModificationDateKey];
            if ([[modificationDate laterDate:expirationDate] isEqualToDate:expirationDate]) {
                [urlsToDelete addObject:fileURL];
                continue;
            }

            // Store a reference to this file and account for its total size.
            NSNumber *totalAllocatedSize = resourceValues[NSURLTotalFileAllocatedSizeKey];
            currentCacheSize += totalAllocatedSize.unsignedIntegerValue;
            cacheFiles[fileURL] = resourceValues;
        }
        
        for (NSURL *fileURL in urlsToDelete) {
            [_fileManager removeItemAtURL:fileURL error:nil];
        }

        // If our remaining disk cache exceeds a configured maximum size, perform a second
        // size-based cleanup pass.  We delete the oldest files first.
        if (self.config.maxCacheSize > 0 && currentCacheSize > self.config.maxCacheSize) {
            // Target half of our maximum cache size for this cleanup pass.
            const NSUInteger desiredCacheSize = self.config.maxCacheSize / 2;

            // Sort the remaining cache files by their last modification time (oldest first).
            NSArray<NSURL *> *sortedFiles = [cacheFiles keysSortedByValueWithOptions:NSSortConcurrent
                                                                     usingComparator:^NSComparisonResult(id obj1, id obj2) {
                                                                         return [obj1[NSURLContentModificationDateKey] compare:obj2[NSURLContentModificationDateKey]];
                                                                     }];

            // Delete files until we fall below our desired cache size.
            // for in 在NSArray中的枚举顺序是按index枚举，所以老文件在前
            for (NSURL *fileURL in sortedFiles) {
                if ([_fileManager removeItemAtURL:fileURL error:nil]) {
                    NSDictionary<NSString *, id> *resourceValues = cacheFiles[fileURL];
                    NSNumber *totalAllocatedSize = resourceValues[NSURLTotalFileAllocatedSizeKey];
                    currentCacheSize -= totalAllocatedSize.unsignedIntegerValue;

                    if (currentCacheSize < desiredCacheSize) {
                        break;
                    }
                }
            }
        }
        if (completionBlock) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionBlock();
            });
        }
    });
}

#if SD_UIKIT
// 在后台开启任务，做删除磁盘缓存工作
- (void)backgroundDeleteOldFiles {
    Class UIApplicationClass = NSClassFromString(@"UIApplication");
    if(!UIApplicationClass || ![UIApplicationClass respondsToSelector:@selector(sharedApplication)]) {
        return;
    }
    UIApplication *application = [UIApplication performSelector:@selector(sharedApplication)];
    __block UIBackgroundTaskIdentifier bgTask = [application beginBackgroundTaskWithExpirationHandler:^{
        // Clean up any unfinished task business by marking where you
        // stopped or ending the task outright.
        [application endBackgroundTask:bgTask];
        bgTask = UIBackgroundTaskInvalid;
    }];

    // Start the long-running task and return immediately.
    [self deleteOldFilesWithCompletionBlock:^{
        [application endBackgroundTask:bgTask];
        bgTask = UIBackgroundTaskInvalid;
    }];
}
#endif

#pragma mark - Cache Info
// 获取self.diskCachePath 文件夹中缓存的图片总大小
- (NSUInteger)getSize {
    __block NSUInteger size = 0;
    dispatch_sync(self.ioQueue, ^{
        NSDirectoryEnumerator *fileEnumerator = [_fileManager enumeratorAtPath:self.diskCachePath];
        for (NSString *fileName in fileEnumerator) {
            NSString *filePath = [self.diskCachePath stringByAppendingPathComponent:fileName];
            NSDictionary<NSString *, id> *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:nil];
            size += [attrs fileSize];
        }
    });
    return size;
}
// 获取self.diskCachePath 文件夹中缓存的图片数量
- (NSUInteger)getDiskCount {
    __block NSUInteger count = 0;
    dispatch_sync(self.ioQueue, ^{
        NSDirectoryEnumerator *fileEnumerator = [_fileManager enumeratorAtPath:self.diskCachePath];
        count = fileEnumerator.allObjects.count;
    });
    return count;
}

- (void)calculateSizeWithCompletionBlock:(nullable SDWebImageCalculateSizeBlock)completionBlock {
    NSURL *diskCacheURL = [NSURL fileURLWithPath:self.diskCachePath isDirectory:YES];

    dispatch_async(self.ioQueue, ^{
        NSUInteger fileCount = 0;
        NSUInteger totalSize = 0;

        NSDirectoryEnumerator *fileEnumerator = [_fileManager enumeratorAtURL:diskCacheURL
                                                   includingPropertiesForKeys:@[NSFileSize]
                                                                      options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                 errorHandler:NULL];

        for (NSURL *fileURL in fileEnumerator) {
            NSNumber *fileSize;
            [fileURL getResourceValue:&fileSize forKey:NSURLFileSizeKey error:NULL];
            totalSize += fileSize.unsignedIntegerValue;
            fileCount += 1;
        }

        if (completionBlock) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionBlock(fileCount, totalSize);
            });
        }
    });
}

@end

