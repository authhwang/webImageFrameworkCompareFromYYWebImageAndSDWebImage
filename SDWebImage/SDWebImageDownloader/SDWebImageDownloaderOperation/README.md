# SDWebImageDownloaderOperation

这个类是继承于NSOperation 所以可以理解为多线程下的网络请求工作

先从init方法看起

```objective-c
- (nonnull instancetype)init {
    return [self initWithRequest:nil inSession:nil options:0];
}

- (nonnull instancetype)initWithRequest:(nullable NSURLRequest *)request
                              inSession:(nullable NSURLSession *)session
                                options:(SDWebImageDownloaderOptions)options {
    if ((self = [super init])) {
        _request = [request copy];
        _shouldDecompressImages = YES;
        _options = options;
        _callbackBlocks = [NSMutableArray new];
        _executing = NO;
        _finished = NO;
        _expectedSize = 0;
        _unownedSession = session;
        _barrierQueue = dispatch_queue_create("com.hackemist.SDWebImageDownloaderOperationBarrierQueue", DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}
```

注意点:

1. init方法调用时 会创建7个**成员变量**
   * _request变量 是对构建方法传过来的参数NSURLRequest实例进行强引用或保存
   * _shouldDecompressImages变量 默认为yes 需要下载后解压缩图片
   * _options变量 是对构建方法传过来的参数SDWebImageDownloaderOptions的设置
   * _callbackBlocks变量 是一个NSMutableArray实例 用来保存针对每一个url下的progressBlock和completeBlock 即SDWebImageManager的3.1部分
   * _executing变量 原本NSOperation下的标志符
   * _finished变量 原本NSOperation下的标志符
   * _expectedSize变量 进行url请求后 获得的图片总大小
   * _unownedSession变量 是对构建方法传过来的参数NSURLSession实例进行强引用
   * _barrierQueue队列 该队列用于处理添加和删除\_callbackBlocks下的元素 可以不需要因为别的操作而被延误

看这个类主要可以分为四个部分来看 第一个是开始启动部分

```objective-c
- (void)start {
    @synchronized (self) {
        //可能因为低优先度 所以可能会一直被延误开始 到后来真的要开始的时候可能就已经被取消了
      
        if (self.isCancelled) {
            self.finished = YES;
            [self reset];
            return;
        }

#if SD_UIKIT
        Class UIApplicationClass = NSClassFromString(@"UIApplication");
        BOOL hasApplication = UIApplicationClass && [UIApplicationClass respondsToSelector:@selector(sharedApplication)];
        //假如有UIApplication 而且 可以在后台继续执行任务
        if (hasApplication && [self shouldContinueWhenAppEntersBackground]) {
            __weak __typeof__ (self) wself = self;
            UIApplication * app = [UIApplicationClass performSelector:@selector(sharedApplication)];
            self.backgroundTaskId = [app beginBackgroundTaskWithExpirationHandler:^{
                __strong __typeof (wself) sself = wself;

                if (sself) {
                    [sself cancel];

                    [app endBackgroundTask:sself.backgroundTaskId];
                    sself.backgroundTaskId = UIBackgroundTaskInvalid;
                }
            }];
        }
#endif
        //从这里开始 到下面的endBackgroundTask调用前的部分都可以在后台执行
        
        //如果设置里有SDWebImageDownloaderIgnoreCachedResponse 即有设置了要从默认策略下读取缓存数据
        if (self.options & SDWebImageDownloaderIgnoreCachedResponse) {
            //为了之后的检查抓取缓存数据
            // Grab the cached data for later check
            NSCachedURLResponse *cachedResponse = [[NSURLCache sharedURLCache] cachedResponseForRequest:self.request];
            if (cachedResponse) {
                self.cachedData = cachedResponse.data;
            }
        }
        
        //假如没设置外置session 就用自身创建的内置Session
        NSURLSession *session = self.unownedSession;
        if (!self.unownedSession) {
            NSURLSessionConfiguration *sessionConfig = [NSURLSessionConfiguration defaultSessionConfiguration];
            sessionConfig.timeoutIntervalForRequest = 15;
            
            /**
             *  Create the session for this task
             *  We send nil as delegate queue so that the session creates a serial operation queue for performing all delegate
             *  method calls and completion handler calls.
             */
            self.ownedSession = [NSURLSession sessionWithConfiguration:sessionConfig
                                                              delegate:self
                                                         delegateQueue:nil];
            session = self.ownedSession;
        }
        
        //创建一个NSURLSessionTask实例
        self.dataTask = [session dataTaskWithRequest:self.request];
        self.executing = YES;
    }
    
    //开启NSURLSessionTask实例 进行对url请求的操作
    [self.dataTask resume];

    if (self.dataTask) {
        //循环获取callbackBlocks里的kProgressCallbackKey调用
        for (SDWebImageDownloaderProgressBlock progressBlock in [self callbacksForKey:kProgressCallbackKey]) {
            progressBlock(0, NSURLResponseUnknownLength, self.request.URL);
        }
        __weak typeof(self) weakSelf = self;
        //在主线程发出SDWebImageDownloadStartNotification通知
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:SDWebImageDownloadStartNotification object:weakSelf];
        });
    } else {
        //如果没有dataTask 证明该dataTask无法生成 那就可能外置session有问题
        [self callCompletionBlocksWithError:[NSError errorWithDomain:NSURLErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey : @"Connection can't be initialized"}]];
    }

#if SD_UIKIT
    Class UIApplicationClass = NSClassFromString(@"UIApplication");
    if(!UIApplicationClass || ![UIApplicationClass respondsToSelector:@selector(sharedApplication)]) {
        return;
    }
    if (self.backgroundTaskId != UIBackgroundTaskInvalid) {
        UIApplication * app = [UIApplication performSelector:@selector(sharedApplication)];
        //当执行到这里时 结束后台任务
        [app endBackgroundTask:self.backgroundTaskId];
        self.backgroundTaskId = UIBackgroundTaskInvalid;
    }
#endif
}
```

第二部分是NSURLSessionDataDelegate部分

```objective-c
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    
    //进入这个方法时 我觉得基本上能拿图片的总大小
    
    //'304 Not Modified' is an exceptional one
    //response的状态吗小于400而且不会等于304时 进入下面的判断
    if (![response respondsToSelector:@selector(statusCode)] || (((NSHTTPURLResponse *)response).statusCode < 400 && ((NSHTTPURLResponse *)response).statusCode != 304)) {
        //获取response的内容大小 不一定是准确 或大或小
        NSInteger expected = (NSInteger)response.expectedContentLength;
        expected = expected > 0 ? expected : 0;
        self.expectedSize = expected;
        //调用callbackBlocks里的progressBlock 告诉调用者的进度
        for (SDWebImageDownloaderProgressBlock progressBlock in [self callbacksForKey:kProgressCallbackKey]) {
            progressBlock(0, expected, self.request.URL);
        }
        
        //创建imageData的NSMutableData实例 以此expected的容量
        self.imageData = [[NSMutableData alloc] initWithCapacity:expected];
        self.response = response;
        __weak typeof(self) weakSelf = self;
        //发送SDWebImageDownloadReceiveResponseNotification通知
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:SDWebImageDownloadReceiveResponseNotification object:weakSelf];
        });
    } else {
        //进入这里要是出错 要是304 即没修改 这代表远端图片没有变 这个304是服务器那边返回给我们的 假如没返回通常都是200
        NSUInteger code = ((NSHTTPURLResponse *)response).statusCode;
        
        //This is the case when server returns '304 Not Modified'. It means that remote image is not changed.
        //如果是304 我们只需要取消operation就用回原来缓存里的图片
        //In case of 304 we need just cancel the operation and return cached image from the cache.
        if (code == 304) {
            [self cancelInternal];
        } else {
            //如果是出错 则直接cencel dataTask
            [self.dataTask cancel];
        }
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:SDWebImageDownloadStopNotification object:weakSelf];
        });
        
        //调用之前放在callbackBlocks中的completedBlock
        [self callCompletionBlocksWithError:[NSError errorWithDomain:NSURLErrorDomain code:((NSHTTPURLResponse *)response).statusCode userInfo:nil]];

        [self done];
    }
    
    //默认调用completionHandler
    if (completionHandler) {
        completionHandler(NSURLSessionResponseAllow);
    }
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    //会将数据一节一节的传进来
    [self.imageData appendData:data];

    if ((self.options & SDWebImageDownloaderProgressiveDownload) && self.expectedSize > 0) {
        //获取增加后的数据 判断是否已完成
        // Get the image data
        NSData *imageData = [self.imageData copy];
        // Get the total bytes downloaded
        const NSInteger totalSize = imageData.length;
        // Get the finish status
        BOOL finished = (totalSize >= self.expectedSize);
        
        //假如需要渐进式下载 则需要创建一个progressiveCoder
        if (!self.progressiveCoder) {
            // We need to create a new instance for progressive decoding to avoid conflicts
            for (id<SDWebImageCoder>coder in [SDWebImageCodersManager sharedInstance].coders) {
                if ([coder conformsToProtocol:@protocol(SDWebImageProgressiveCoder)] &&
                    [((id<SDWebImageProgressiveCoder>)coder) canIncrementallyDecodeFromData:imageData]) {
                    self.progressiveCoder = [[[coder class] alloc] init];
                    break;
                }
            }
        }
        
        UIImage *image = [self.progressiveCoder incrementallyDecodedImageWithData:imageData finished:finished];
        if (image) {
            NSString *key = [[SDWebImageManager sharedManager] cacheKeyForURL:self.request.URL];
            image = [self scaledImageForKey:key image:image];
            //是否需要解压缩图片
            if (self.shouldDecompressImages) {
                image = [[SDWebImageCodersManager sharedInstance] decompressedImageWithImage:image data:&data options:@{SDWebImageCoderScaleDownLargeImagesKey: @(NO)}];
            }
            //如果是渐进式下载 每次都要调用completionBlock返回图片
            [self callCompletionBlocksWithImage:image imageData:nil error:nil finished:NO];
        }
    }

    for (SDWebImageDownloaderProgressBlock progressBlock in [self callbacksForKey:kProgressCallbackKey]) {
        //每次调用progressBlock 会根据imageData长度不断增长而变化
        progressBlock(self.imageData.length, self.expectedSize, self.request.URL);
    }
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
 willCacheResponse:(NSCachedURLResponse *)proposedResponse
 completionHandler:(void (^)(NSCachedURLResponse *cachedResponse))completionHandler {
    
    //nsurlcache 是一个骚机制 就是当你向服务器请求 获取到服务器的response时候 它会调用该方法 询问你是否需要将该response缓存起来 作用： 下次请求该路径时就不需要等待服务器 直接使用缓存response即可
    //sdwebimage默认是不用nsurlcache 则将cachedResponse设置为nil 并返回给completionHandler即可
    
    NSCachedURLResponse *cachedResponse = proposedResponse;

    if (self.request.cachePolicy == NSURLRequestReloadIgnoringLocalCacheData) {
        // Prevents caching of responses
        cachedResponse = nil;
    }
    if (completionHandler) {
        completionHandler(cachedResponse);
    }
}

```

注意点：

1. done方法的内部实现:

```objective-c
- (void)done {
    self.finished = YES;
    self.executing = NO;
    [self reset];
}
```

2. 针对finish和excuting的标志符设置

```objective-c
//当finish设置为yes时 就会让外面对自己的强引用解除
- (void)setFinished:(BOOL)finished {
    //手动调用willChangeValueForKey 和 didChangeValueForKey
    //假如是对于属性来说 其实只是会调用kvo两次 因为存储方法会自动调用willChangeValueForKey 和 didChangeValueForKey
    //可是现在的情况 因为用了@synthesize 所以原本赋值给finshed 现在就变成赋值给_finished 但也要告诉比人finish已经被设置 所以才会这样写
    [self willChangeValueForKey:@"isFinished"];
    _finished = finished;
    [self didChangeValueForKey:@"isFinished"];
}

- (void)setExecuting:(BOOL)executing {
    [self willChangeValueForKey:@"isExecuting"];
    _executing = executing;
    [self didChangeValueForKey:@"isExecuting"];
}
```

第三部分是NSURLSessionTaskDelegate

```objective-c
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    //当完成task的时候调用 即获取完所有数据
    
    @synchronized(self) {
        //解除当前dataTask的引用
        self.dataTask = nil;
        __weak typeof(self) weakSelf = self;
        //发送SDWebImageDownloadStopNotification通知 和 SDWebImageDownloadFinishNotification通知
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:SDWebImageDownloadStopNotification object:weakSelf];
            if (!error) {
                [[NSNotificationCenter defaultCenter] postNotificationName:SDWebImageDownloadFinishNotification object:weakSelf];
            }
        });
    }
    
    if (error) {
        //调用completeBlock
        [self callCompletionBlocksWithError:error];
    } else {
        //成功完成dataTask
        if ([self callbacksForKey:kCompletedCallbackKey].count > 0) {
            /**
             *  If you specified to use `NSURLCache`, then the response you get here is what you need.
             */
            NSData *imageData = [self.imageData copy];
            if (imageData) {
                /**  if you specified to only use cached data via `SDWebImageDownloaderIgnoreCachedResponse`,
                 *  then we should check if the cached data is equal to image data
                 */
                //如果指定了缓存数据 例如有SDWebImageDownloaderIgnoreCachedResponse
                //那么我们会用缓存数据判断是否等于图片数据 如果等于 就没必要返回图像了
                
                if (self.options & SDWebImageDownloaderIgnoreCachedResponse && [self.cachedData isEqualToData:imageData]) {
                    // call completion block with nil
                    [self callCompletionBlocksWithImage:nil imageData:nil error:nil finished:YES];
                } else {
                    //将图片数据编码成image
                    UIImage *image = [[SDWebImageCodersManager sharedInstance] decodedImageWithData:imageData];
                    //获取url的absoluteString
                    NSString *key = [[SDWebImageManager sharedManager] cacheKeyForURL:self.request.URL];
                    image = [self scaledImageForKey:key image:image];
                    
                    BOOL shouldDecode = YES;
                    // Do not force decoding animated GIFs and WebPs
                    if (image.images) {
                        shouldDecode = NO;
                    } else {
#ifdef SD_WEBP
                        SDImageFormat imageFormat = [NSData sd_imageFormatForImageData:imageData];
                        if (imageFormat == SDImageFormatWebP) {
                            shouldDecode = NO;
                        }
#endif
                    }
                    //针对动态GIFs和WebPs 都不需要解压缩 非此 则需要判断shouldDecompressImages
                    if (shouldDecode) {
                        if (self.shouldDecompressImages) {
                            BOOL shouldScaleDown = self.options & SDWebImageDownloaderScaleDownLargeImages;
                            image = [[SDWebImageCodersManager sharedInstance] decompressedImageWithImage:image data:&imageData options:@{SDWebImageCoderScaleDownLargeImagesKey: @(shouldScaleDown)}];
                        }
                    }
                    //如果得到的图片没有大小 则证明0 pixels
                    if (CGSizeEqualToSize(image.size, CGSizeZero)) {
                        [self callCompletionBlocksWithError:[NSError errorWithDomain:SDWebImageErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey : @"Downloaded image has 0 pixels"}]];
                    } else {
                        [self callCompletionBlocksWithImage:image imageData:imageData error:nil finished:YES];
                    }
                }
            } else {
                //imageData没数据则进入下面
                [self callCompletionBlocksWithError:[NSError errorWithDomain:SDWebImageErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey : @"Image data is nil"}]];
            }
        }
    }
    [self done];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completionHandler {
    //针对是否使用ssl加密的网址进行判断
    
    NSURLSessionAuthChallengeDisposition disposition = NSURLSessionAuthChallengePerformDefaultHandling;
    __block NSURLCredential *credential = nil;
    
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        if (!(self.options & SDWebImageDownloaderAllowInvalidSSLCertificates)) {
            disposition = NSURLSessionAuthChallengePerformDefaultHandling;
        } else {
            credential = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];
            disposition = NSURLSessionAuthChallengeUseCredential;
        }
    } else {
        if (challenge.previousFailureCount == 0) {
            if (self.credential) {
                credential = self.credential;
                disposition = NSURLSessionAuthChallengeUseCredential;
            } else {
                disposition = NSURLSessionAuthChallengeCancelAuthenticationChallenge;
            }
        } else {
            disposition = NSURLSessionAuthChallengeCancelAuthenticationChallenge;
        }
    }
    
    if (completionHandler) {
        completionHandler(disposition, credential);
    }
}
```

第四部分是取消operation部分:

```objective-c
- (void)cancel {
    @synchronized (self) {
        [self cancelInternal];
    }
}

- (void)cancelInternal {
    if (self.isFinished) return;
    [super cancel];
    

    if (self.dataTask) {
        //判断里整个就是先将dataTask cancel
        //然后再发送SDWebImageDownloadStopNotification通知
        //因为当取消了connection 那它的callback也不会被调用 因此也需要主动改变其executing和finished标志
        [self.dataTask cancel];
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:SDWebImageDownloadStopNotification object:weakSelf];
        });
        
        // As we cancelled the connection, its callback won't be called and thus won't
        // maintain the isFinished and isExecuting flags.
        if (self.isExecuting) self.executing = NO;
        if (!self.isFinished) self.finished = YES;
    }

    [self reset];
}

- (void)reset {
    
    //清空callbackBlocks数组 并将dataTask置为nil
    
    __weak typeof(self) weakSelf = self;
    dispatch_barrier_async(self.barrierQueue, ^{
        [weakSelf.callbackBlocks removeAllObjects];
    });
    self.dataTask = nil;
    
    //然后通过获取session（不管是unowned还是owned）其delegateQueue来将imageData置为nil
    NSOperationQueue *delegateQueue;
    if (self.unownedSession) {
        delegateQueue = self.unownedSession.delegateQueue;
    } else {
        delegateQueue = self.ownedSession.delegateQueue;
    }
    if (delegateQueue) {
        NSAssert(delegateQueue.maxConcurrentOperationCount == 1, @"NSURLSession delegate queue should be a serial queue");
        [delegateQueue addOperationWithBlock:^{
            weakSelf.imageData = nil;
        }];
    }
    
    //管理其ownedSession的invalidate和cancel
    if (self.ownedSession) {
        [self.ownedSession invalidateAndCancel];
        self.ownedSession = nil;
    }
}
```

这四部分加起来就是整个内容啦~只能感叹一句 很屌很屌