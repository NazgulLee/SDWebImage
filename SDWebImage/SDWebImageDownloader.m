/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "SDWebImageDownloader.h"
#import "SDWebImageDownloaderOperation.h"
#import <ImageIO/ImageIO.h>

@implementation SDWebImageDownloadToken
@end


@interface SDWebImageDownloader () <NSURLSessionTaskDelegate, NSURLSessionDataDelegate>

@property (strong, nonatomic, nonnull) NSOperationQueue *downloadQueue;//NSOperationQueue
@property (weak, nonatomic, nullable) NSOperation *lastAddedOperation;
@property (assign, nonatomic, nullable) Class operationClass;
@property (strong, nonatomic, nonnull) NSMutableDictionary<NSURL *, SDWebImageDownloaderOperation *> *URLOperations;// 存储图片url与其对应的下载operation的键值对
@property (strong, nonatomic, nullable) SDHTTPHeadersMutableDictionary *HTTPHeaders;
// This queue is used to serialize the handling of the network responses of all the download operation in a single queue
@property (SDDispatchQueueSetterSementics, nonatomic, nullable) dispatch_queue_t barrierQueue;//dispatch_queue_t

// The session in which data tasks will run
@property (strong, nonatomic) NSURLSession *session;

@end

@implementation SDWebImageDownloader
//在SDWebImageDownloader类或实例第一次被发送消息时执行，初始化网络活动指示器
+ (void)initialize {
    // Bind SDNetworkActivityIndicator if available (download it here: http://github.com/rs/SDNetworkActivityIndicator )
    // To use it, just add #import "SDNetworkActivityIndicator.h" in addition to the SDWebImage import
    if (NSClassFromString(@"SDNetworkActivityIndicator")) {

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id activityIndicator = [NSClassFromString(@"SDNetworkActivityIndicator") performSelector:NSSelectorFromString(@"sharedActivityIndicator")];
#pragma clang diagnostic pop

        // Remove observer in case it was previously added.
        [[NSNotificationCenter defaultCenter] removeObserver:activityIndicator name:SDWebImageDownloadStartNotification object:nil];
        [[NSNotificationCenter defaultCenter] removeObserver:activityIndicator name:SDWebImageDownloadStopNotification object:nil];
        // 监听下载活动开始与结束
        // 在startActivity中增加下载计数，若下载计数大于零，则使activityIndicator处于活动状态
        // 在stopActivity中减少下载计数，若下载计数等于零，则使activityIndicator处于静止状态
        [[NSNotificationCenter defaultCenter] addObserver:activityIndicator
                                                 selector:NSSelectorFromString(@"startActivity")
                                                     name:SDWebImageDownloadStartNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:activityIndicator
                                                 selector:NSSelectorFromString(@"stopActivity")
                                                     name:SDWebImageDownloadStopNotification object:nil];
    }
}

+ (nonnull instancetype)sharedDownloader {
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{
        instance = [self new];
    });
    return instance;
}

- (nonnull instancetype)init {
    return [self initWithSessionConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]];
}

- (nonnull instancetype)initWithSessionConfiguration:(nullable NSURLSessionConfiguration *)sessionConfiguration {
    if ((self = [super init])) {
        _operationClass = [SDWebImageDownloaderOperation class];
        _shouldDecompressImages = YES;
        _executionOrder = SDWebImageDownloaderFIFOExecutionOrder;
        _downloadQueue = [NSOperationQueue new];
        _downloadQueue.maxConcurrentOperationCount = 6;
        _downloadQueue.name = @"com.hackemist.SDWebImageDownloader";
        _URLOperations = [NSMutableDictionary new];
#ifdef SD_WEBP
        _HTTPHeaders = [@{@"Accept": @"image/webp,image/*;q=0.8"} mutableCopy];
#else
        _HTTPHeaders = [@{@"Accept": @"image/*;q=0.8"} mutableCopy];
#endif
        _barrierQueue = dispatch_queue_create("com.hackemist.SDWebImageDownloaderBarrierQueue", DISPATCH_QUEUE_CONCURRENT);
        _downloadTimeout = 15.0;

        sessionConfiguration.timeoutIntervalForRequest = _downloadTimeout;

        /**
         *  Create the session for this task
         *  We send nil as delegate queue so that the session creates a serial operation queue for performing all delegate
         *  method calls and completion handler calls.
         */
        self.session = [NSURLSession sessionWithConfiguration:sessionConfiguration
                                                     delegate:self
                                                delegateQueue:nil];
    }
    return self;
}

- (void)dealloc {
    [self.session invalidateAndCancel];
    self.session = nil;

    [self.downloadQueue cancelAllOperations];//把queue中所有operation状态isCancelled设为YES，但是还是要执行这些operation，这样这些operation才知道自己被cancell了，才能把finished状态设为YES（这样依赖它的operation才能被执行），以及执行completedBlock，执行完才会从queue中移除
    SDDispatchQueueRelease(_barrierQueue);
}

- (void)setValue:(nullable NSString *)value forHTTPHeaderField:(nullable NSString *)field {
    if (value) {
        self.HTTPHeaders[field] = value;
    }
    else {
        [self.HTTPHeaders removeObjectForKey:field];
    }
}

- (nullable NSString *)valueForHTTPHeaderField:(nullable NSString *)field {
    return self.HTTPHeaders[field];
}

- (void)setMaxConcurrentDownloads:(NSInteger)maxConcurrentDownloads {
    _downloadQueue.maxConcurrentOperationCount = maxConcurrentDownloads;
}

- (NSUInteger)currentDownloadCount {
    return _downloadQueue.operationCount;// operation执行完才会从_downloadQueue中移除，正在执行的还不会被移除
}

- (NSInteger)maxConcurrentDownloads {
    return _downloadQueue.maxConcurrentOperationCount;// 正在同时执行的operation的最大数量
}
// 若框架提供的SDWebImageDownloaderOperation类不能满足需求，用户可自己提供一个服从SDWebImageDownloaderOperationInterface的NSOperation子类作为一个SDWebImageDownloder实例构建下载operation的类
- (void)setOperationClass:(nullable Class)operationClass {
    if (operationClass && [operationClass isSubclassOfClass:[NSOperation class]] && [operationClass conformsToProtocol:@protocol(SDWebImageDownloaderOperationInterface)]) {
        _operationClass = operationClass;
    } else {
        _operationClass = [SDWebImageDownloaderOperation class];
    }
}

- (nullable SDWebImageDownloadToken *)downloadImageWithURL:(nullable NSURL *)url
                                                   options:(SDWebImageDownloaderOptions)options
                                                  progress:(nullable SDWebImageDownloaderProgressBlock)progressBlock
                                                 completed:(nullable SDWebImageDownloaderCompletedBlock)completedBlock {
    __weak SDWebImageDownloader *wself = self;

    return [self addProgressCallback:progressBlock completedBlock:completedBlock forURL:url createCallback:^SDWebImageDownloaderOperation *{// 用url及相关属性构建一个NSMutableURLRequest实例，使用这个URLRequest和self.session构建downloaderOperation实例，设置它的queuePriority和依赖，然后返回它
        __strong __typeof (wself) sself = wself;
        NSTimeInterval timeoutInterval = sself.downloadTimeout;
        if (timeoutInterval == 0.0) {
            timeoutInterval = 15.0;
        }

        // In order to prevent from potential duplicate caching (NSURLCache + SDImageCache) we disable the cache for image requests if told otherwise
        NSURLRequestCachePolicy cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        if (options & SDWebImageDownloaderUseNSURLCache) {
            if (options & SDWebImageDownloaderIgnoreCachedResponse) {
                cachePolicy = NSURLRequestReturnCacheDataDontLoad;// 去现有的数据缓存中找，没找到算下载失败
            } else {
                cachePolicy = NSURLRequestUseProtocolCachePolicy;
            }
        }
        
        NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:url cachePolicy:cachePolicy timeoutInterval:timeoutInterval];
        
        request.HTTPShouldHandleCookies = (options & SDWebImageDownloaderHandleCookies);
        request.HTTPShouldUsePipelining = YES;
        if (sself.headersFilter) {
            request.allHTTPHeaderFields = sself.headersFilter(url, [sself.HTTPHeaders copy]);
        }
        else {
            request.allHTTPHeaderFields = sself.HTTPHeaders;
        }
        SDWebImageDownloaderOperation *operation = [[sself.operationClass alloc] initWithRequest:request inSession:sself.session options:options];
        operation.shouldDecompressImages = sself.shouldDecompressImages;
        
        if (sself.urlCredential) {
            operation.credential = sself.urlCredential;
        } else if (sself.username && sself.password) {
            operation.credential = [NSURLCredential credentialWithUser:sself.username password:sself.password persistence:NSURLCredentialPersistenceForSession];
        }
        
        if (options & SDWebImageDownloaderHighPriority) {
            operation.queuePriority = NSOperationQueuePriorityHigh;
        } else if (options & SDWebImageDownloaderLowPriority) {
            operation.queuePriority = NSOperationQueuePriorityLow;
        }

        [sself.downloadQueue addOperation:operation];
        if (sself.executionOrder == SDWebImageDownloaderLIFOExecutionOrder) {
            // Emulate LIFO execution order by systematically adding new operations as last operation's dependency
            [sself.lastAddedOperation addDependency:operation];//若sself.lastAddedOperation已经在执行，添加依赖不产生任何作用。若还没开始执行，则使其依赖于新加入的这个operation，这样后加入的operation会先执行
            sself.lastAddedOperation = operation;
        }

        return operation;
    }];
}

- (void)cancel:(nullable SDWebImageDownloadToken *)token {
    dispatch_barrier_async(self.barrierQueue, ^{
        SDWebImageDownloaderOperation *operation = self.URLOperations[token.url];
        BOOL canceled = [operation cancel:token.downloadOperationCancelToken];
        if (canceled) {
            [self.URLOperations removeObjectForKey:token.url];
        }
    });
}
// 从self.URLOperations获取此url对应的下载operation（若不存在则使用createCallback参数创建一个operation），把progressBlock和completedBlock作为operation封装的下载操作的progressBlocks之一和completedBlocks之一，operation本身的completedBlock是把自己从self.URLOperations移除。以url为键operation为值添加到self.URLOperations中。返回包含url和下载url内容时的progressBlock和completedBlock的SDWebImageDownloadToken
- (nullable SDWebImageDownloadToken *)addProgressCallback:(SDWebImageDownloaderProgressBlock)progressBlock
                                           completedBlock:(SDWebImageDownloaderCompletedBlock)completedBlock
                                                   forURL:(nullable NSURL *)url
                                           createCallback:(SDWebImageDownloaderOperation *(^)())createCallback {
    // The URL will be used as the key to the callbacks dictionary so it cannot be nil. If it is nil immediately call the completed block with no image or data.
    if (url == nil) {
        if (completedBlock != nil) {
            completedBlock(nil, nil, nil, NO);
        }
        return nil;
    }

    __block SDWebImageDownloadToken *token = nil;
    //dispatch_barrier_参数中的block在到达参数queue的最前端时，要等待之前已开始执行的block执行完，然后执行自己，自己执行完后，才开始并发执行排在自己后面的block
    dispatch_barrier_sync(self.barrierQueue, ^{
        SDWebImageDownloaderOperation *operation = self.URLOperations[url];
        if (!operation) {// 若此url对应的下载operation未创建，则执行createCallback()创建一个
            operation = createCallback();
            self.URLOperations[url] = operation;

            __weak SDWebImageDownloaderOperation *woperation = operation;
            operation.completionBlock = ^{// operation执行完后将此自己从self.URLOperations中移除
              SDWebImageDownloaderOperation *soperation = woperation;
              if (!soperation) return;
              if (self.URLOperations[url] == soperation) {
                  [self.URLOperations removeObjectForKey:url];
              };
            };
        }
        // downloadOperationCancelToken其实是包含progressBlock和completedBlock的字典
        id downloadOperationCancelToken = [operation addHandlersForProgress:progressBlock completed:completedBlock];

        token = [SDWebImageDownloadToken new];
        token.url = url;
        token.downloadOperationCancelToken = downloadOperationCancelToken;
        // token包含url和下载url内容时的progressBlock和completedBlock
    });

    return token;
}

- (void)setSuspended:(BOOL)suspended {
    (self.downloadQueue).suspended = suspended;
}

- (void)cancelAllDownloads {
    [self.downloadQueue cancelAllOperations];
}

#pragma mark Helper methods
// 在downloadQueue中的operations中查找具有指定task的operation
- (SDWebImageDownloaderOperation *)operationWithTask:(NSURLSessionTask *)task {
    SDWebImageDownloaderOperation *returnOperation = nil;
    for (SDWebImageDownloaderOperation *operation in self.downloadQueue.operations) {
        if (operation.dataTask.taskIdentifier == task.taskIdentifier) {
            returnOperation = operation;
            break;
        }
    }
    return returnOperation;
}

//先找到dataTask对应的downloadOperation，再转交给它执行
#pragma mark NSURLSessionDataDelegate 


- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {

    // Identify the operation that runs this task and pass it the delegate method
    SDWebImageDownloaderOperation *dataOperation = [self operationWithTask:dataTask];

    [dataOperation URLSession:session dataTask:dataTask didReceiveResponse:response completionHandler:completionHandler];
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {

    // Identify the operation that runs this task and pass it the delegate method
    SDWebImageDownloaderOperation *dataOperation = [self operationWithTask:dataTask];

    [dataOperation URLSession:session dataTask:dataTask didReceiveData:data];
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
 willCacheResponse:(NSCachedURLResponse *)proposedResponse
 completionHandler:(void (^)(NSCachedURLResponse *cachedResponse))completionHandler {

    // Identify the operation that runs this task and pass it the delegate method
    SDWebImageDownloaderOperation *dataOperation = [self operationWithTask:dataTask];

    [dataOperation URLSession:session dataTask:dataTask willCacheResponse:proposedResponse completionHandler:completionHandler];
}

#pragma mark NSURLSessionTaskDelegate
//除了willPerformHTTPRedirection， 全部转交给task对应的downloadOperation执行

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    // Identify the operation that runs this task and pass it the delegate method
    SDWebImageDownloaderOperation *dataOperation = [self operationWithTask:task];

    [dataOperation URLSession:session task:task didCompleteWithError:error];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    
    completionHandler(request);
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completionHandler {

    // Identify the operation that runs this task and pass it the delegate method
    SDWebImageDownloaderOperation *dataOperation = [self operationWithTask:task];

    [dataOperation URLSession:session task:task didReceiveChallenge:challenge completionHandler:completionHandler];
}

@end
