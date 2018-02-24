# SDWebImageDownloader

这个就是负责下载方面的管理工作啦～ 先看它的init方法

```objective-c
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
        //_operationClass 获取SDWebImageDownloaderOperation 的类对象 暂时没看出有什么用
        _operationClass = [SDWebImageDownloaderOperation class];
        //_shouldDecompressImages 是否解压缩图片
        _shouldDecompressImages = YES;
        //_executionOrder 下载的执行顺序 默认为队列
        _executionOrder = SDWebImageDownloaderFIFOExecutionOrder;
        //_downloadQueue 下载队列
        _downloadQueue = [NSOperationQueue new];
        //设置最大并发数
        _downloadQueue.maxConcurrentOperationCount = 6;
        _downloadQueue.name = @"com.hackemist.SDWebImageDownloader";
        //_URLOperations 针对每个url保存其operation
        _URLOperations = [NSMutableDictionary new];
        //_HTTPHeaders 请求头
#ifdef SD_WEBP
        _HTTPHeaders = [@{@"Accept": @"image/webp,image/*;q=0.8"} mutableCopy];
#else
        _HTTPHeaders = [@{@"Accept": @"image/*;q=0.8"} mutableCopy];
#endif
        //_barrierQueue 创建并发队列 这个队列基本上用于添加operation或者解除operation的工作 在单独的队列上处理可以防止处理被延误的问题 也可以避免队列层级死锁
        _barrierQueue = dispatch_queue_create("com.hackemist.SDWebImageDownloaderBarrierQueue", DISPATCH_QUEUE_CONCURRENT);
        _downloadTimeout = 15.0;

        [self createNewSessionWithConfiguration:sessionConfiguration];
    }
    return self;
}

- (void)createNewSessionWithConfiguration:(NSURLSessionConfiguration *)sessionConfiguration {
    //在SDWebImageDownloader单例创建时 先把下载队列所有operation停止
    [self cancelAllDownloads];
    
    //将以前的session invalidate并Cancel
    if (self.session) {
        [self.session invalidateAndCancel];
    }

    sessionConfiguration.timeoutIntervalForRequest = self.downloadTimeout;

    /**
     *  Create the session for this task
     *  We send nil as delegate queue so that the session creates a serial operation queue for performing all delegate
     *  method calls and completion handler calls.
     */
    //将delegate queue设为了nil 则the session自动创建一个串行队列去执行所以代理的方法和回调调用
    
    self.session = [NSURLSession sessionWithConfiguration:sessionConfiguration
                                                 delegate:self
                                            delegateQueue:nil];
}
```

 注意点：

1. 在downloader里面已经提供了一个session去执行所有的网络请求操作 所以在后面分析的SDWebImageDownloaderOperation类里面则不需要再去创建session来进行网络请求啦

在之前的SDWebImageManager的第三部分里 是调用了下面的方法去执行下载的操作

```objective-c
- (nullable SDWebImageDownloadToken *)downloadImageWithURL:(nullable NSURL *)url
                                        options:(SDWebImageDownloaderOptions)options
                                   		progress:(nullable SDWebImageDownloaderProgressBlock)progressBlock
                                        completed:(nullable SDWebImageDownloaderCompletedBlock)completedBlock;
```

方法的内部实现实现其实是调用下面的方法

```objective-c
- (nullable SDWebImageDownloadToken *)addProgressCallback:(SDWebImageDownloaderProgressBlock)progressBlock
                                   completedBlock:(SDWebImageDownloaderCompletedBlock)completedBlock
                                   forURL:(nullable NSURL *)url
                                   createCallback:(SDWebImageDownloaderOperation *(^)(void))createCallback;
```

先看看整个方法的内部实现：

```objective-c
if (url == nil) {
        if (completedBlock != nil) {
            completedBlock(nil, nil, nil, NO);
        }
        return nil;
    }

    __block SDWebImageDownloadToken *token = nil;
    
    //在并列队列里sync执行token创建以及执行下载的operation
    dispatch_barrier_sync(self.barrierQueue, ^{
        SDWebImageDownloaderOperation *operation = self.URLOperations[url];
        if (!operation) {
            operation = createCallback(); //在这个callback上创建了一个SDWebImageDownloaderOperation类的operation
            self.URLOperations[url] = operation;//URLOperations也强引用operation

            __weak SDWebImageDownloaderOperation *woperation = operation;
            //这个completionBlock调用是会在 operation 设置finish为yes的时候
            operation.completionBlock = ^{
                //若operation完成时 通过调用barrierQueue来解除URLOperations对operation的引用
				dispatch_barrier_sync(self.barrierQueue, ^{
					SDWebImageDownloaderOperation *soperation = woperation;
					if (!soperation) return;
					if (self.URLOperations[url] == soperation) {
						[self.URLOperations removeObjectForKey:url];
					};
				});
            };
        }
        //这个downloadOperationCancelToken 只是一个NSMutableDictionary 不过引用着progressBlock和completedBlock
        id downloadOperationCancelToken = [operation addHandlersForProgress:progressBlock completed:completedBlock];
        //这个SDWebImageDownloadToken 就是个NSObject 不过就是可以强引用着url和downloadOperationCancelToken
        
        token = [SDWebImageDownloadToken new];
        token.url = url;
        token.downloadOperationCancelToken = downloadOperationCancelToken;
    });

    return token;
```

其中：

createCallback里面的内容是前面downloadImageWithURL方法实现的：

```objective-c
__strong __typeof (wself) sself = wself;
        NSTimeInterval timeoutInterval = sself.downloadTimeout;
        if (timeoutInterval == 0.0) {
            timeoutInterval = 15.0;
        }
        
        //为了阻止潜在的相同缓存机制 我们禁止图片请求时使用nsurlcache 除非option设置了SDWebImageDownloaderUseNSURLCache
        // In order to prevent from potential duplicate caching (NSURLCache + SDImageCache) we disable the cache for image requests if told otherwise
        NSURLRequestCachePolicy cachePolicy = options & SDWebImageDownloaderUseNSURLCache ? NSURLRequestUseProtocolCachePolicy : NSURLRequestReloadIgnoringLocalCacheData;
        NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:url                                                 cachePolicy:cachePolicy timeoutInterval:timeoutInterval];
        
        request.HTTPShouldHandleCookies = (options & SDWebImageDownloaderHandleCookies);
        //HTTPShouldUsePipelining 指的是是否等待在上一个response后再发送请求
        request.HTTPShouldUsePipelining = YES;
        //headersFilter指的是可以重新选择修改请求头
        if (sself.headersFilter) {
            request.allHTTPHeaderFields = sself.headersFilter(url, [sself.HTTPHeaders copy]);
        }
        else {
            request.allHTTPHeaderFields = sself.HTTPHeaders;
        }
		//SDWebImageDownloaderOperation 在另一个地方再解释 现在理解成一个NSOperation去处理下载图片的行为
        SDWebImageDownloaderOperation *operation = [[sself.operationClass alloc] initWithRequest:request inSession:sself.session options:options];
        operation.shouldDecompressImages = sself.shouldDecompressImages;
        
        //判断有无凭证
        if (sself.urlCredential) {
            operation.credential = sself.urlCredential;
        } else if (sself.username && sself.password) {
            operation.credential = [NSURLCredential credentialWithUser:sself.username password:sself.password persistence:NSURLCredentialPersistenceForSession];
        }
        
		//如果SDWebImageDownloaderHighPriority 则优先处理权为高
        if (options & SDWebImageDownloaderHighPriority) {
            operation.queuePriority = NSOperationQueuePriorityHigh;
        } else if (options & SDWebImageDownloaderLowPriority) {
            operation.queuePriority = NSOperationQueuePriorityLow;
        }
        
        //这里强引用该operation 并让operation开始执行 调用start方法
        [sself.downloadQueue addOperation:operation];
        if (sself.executionOrder == SDWebImageDownloaderLIFOExecutionOrder) {
            // Emulate LIFO execution order by systematically adding new operations as last operation's dependency
            //模拟先进后出的执行顺序 就是给上一个最后的operation加上一个依赖operation 这样就可以先进后出
            [sself.lastAddedOperation addDependency:operation];
            sself.lastAddedOperation = operation;
        }

        return operation;
```

整个downloadImageWithURL调用完后 则回到SDWebImageManager的3.1部分中 让SDWebImageCombinedOperation类的实例跟这个token有所关联 其中假如operation被取消的时候会调用SDWebImageDownloader的cancel方法 以下为其实现内容：

```objective-c
- (void)cancel:(nullable SDWebImageDownloadToken *)token {
    //每个token通过webimagedownloader来cancel
    dispatch_barrier_async(self.barrierQueue, ^{
        //通过token获取该url 然后在通过downloader的URLOperations找到相应的operation 然后取消
        SDWebImageDownloaderOperation *operation = self.URLOperations[token.url];
        BOOL canceled = [operation cancel:token.downloadOperationCancelToken];
        if (canceled) {
            [self.URLOperations removeObjectForKey:token.url];
        }
    });
}
```

当调用cancel方法后 SDWebImageDownloaderOperation的实例operation也会调用其cancel方法 把内部的实例变量所部解除引用 并且修改其标识符finish 让其知道并调用completeBlock 解除downloader对operation的引用

由于下载的大部分内容都在SDWebImageDownloaderOperation中 所以需要从SDWebImageDownloaderOperation类看起