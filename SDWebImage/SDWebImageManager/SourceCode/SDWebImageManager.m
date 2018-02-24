/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "SDWebImageManager.h"
#import "NSImage+WebCache.h"
#import <objc/message.h>

@interface SDWebImageCombinedOperation : NSObject <SDWebImageOperation>

@property (assign, nonatomic, getter = isCancelled) BOOL cancelled;
@property (copy, nonatomic, nullable) SDWebImageNoParamsBlock cancelBlock;
@property (strong, nonatomic, nullable) NSOperation *cacheOperation;

@end

@interface SDWebImageManager ()

@property (strong, nonatomic, readwrite, nonnull) SDImageCache *imageCache;
@property (strong, nonatomic, readwrite, nonnull) SDWebImageDownloader *imageDownloader;
@property (strong, nonatomic, nonnull) NSMutableSet<NSURL *> *failedURLs;
@property (strong, nonatomic, nonnull) NSMutableArray<SDWebImageCombinedOperation *> *runningOperations;

@end

@implementation SDWebImageManager

+ (nonnull instancetype)sharedManager {
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{
        instance = [self new];
    });
    return instance;
}

- (nonnull instancetype)init {
    SDImageCache *cache = [SDImageCache sharedImageCache];
    SDWebImageDownloader *downloader = [SDWebImageDownloader sharedDownloader];
    return [self initWithCache:cache downloader:downloader];
}

- (nonnull instancetype)initWithCache:(nonnull SDImageCache *)cache downloader:(nonnull SDWebImageDownloader *)downloader {
    if ((self = [super init])) {
        _imageCache = cache;
        _imageDownloader = downloader;
        _failedURLs = [NSMutableSet new];
        _runningOperations = [NSMutableArray new];
    }
    return self;
}

- (nullable NSString *)cacheKeyForURL:(nullable NSURL *)url {
    if (!url) {
        return @"";
    }

    if (self.cacheKeyFilter) {
        return self.cacheKeyFilter(url);
    } else {
        return url.absoluteString;
    }
}

- (nullable UIImage *)scaledImageForKey:(nullable NSString *)key image:(nullable UIImage *)image {
    return SDScaledImageForKey(key, image);
}

- (void)cachedImageExistsForURL:(nullable NSURL *)url
                     completion:(nullable SDWebImageCheckCacheCompletionBlock)completionBlock {
    NSString *key = [self cacheKeyForURL:url];
    
    BOOL isInMemoryCache = ([self.imageCache imageFromMemoryCacheForKey:key] != nil);
    
    if (isInMemoryCache) {
        // making sure we call the completion block on the main queue
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completionBlock) {
                completionBlock(YES);
            }
        });
        return;
    }
    
    [self.imageCache diskImageExistsWithKey:key completion:^(BOOL isInDiskCache) {
        // the completion block of checkDiskCacheForImageWithKey:completion: is always called on the main queue, no need to further dispatch
        if (completionBlock) {
            completionBlock(isInDiskCache);
        }
    }];
}

- (void)diskImageExistsForURL:(nullable NSURL *)url
                   completion:(nullable SDWebImageCheckCacheCompletionBlock)completionBlock {
    NSString *key = [self cacheKeyForURL:url];
    
    [self.imageCache diskImageExistsWithKey:key completion:^(BOOL isInDiskCache) {
        // the completion block of checkDiskCacheForImageWithKey:completion: is always called on the main queue, no need to further dispatch
        if (completionBlock) {
            completionBlock(isInDiskCache);
        }
    }];
}

- (id <SDWebImageOperation>)loadImageWithURL:(nullable NSURL *)url
                                     options:(SDWebImageOptions)options
                                    progress:(nullable SDWebImageDownloaderProgressBlock)progressBlock
                                   completed:(nullable SDInternalCompletionBlock)completedBlock {
    //completedBlock是必须要存在的
    
    // Invoking this method without a completedBlock is pointless
    NSAssert(completedBlock != nil, @"If you mean to prefetch the image, use -[SDWebImagePrefetcher prefetchURLs] instead");
    
    //由于很多人都会传一个字符串而不是nsurl 由于xcode不会因为这个类型不匹配而报错 所以这样做一个failsafe处理
    // Very common mistake is to send the URL using NSString object instead of NSURL. For some strange reason, Xcode won't
    // throw any warning for this type mismatch. Here we failsafe this error by allowing URLs to be passed as NSString.
    if ([url isKindOfClass:NSString.class]) {
        url = [NSURL URLWithString:(NSString *)url];
    }
    
    //假如传的不是nsurl类的 则会将url置为nil 防止后面的崩溃
    // Prevents app crashing on argument type error like sending NSNull instead of NSURL
    if (![url isKindOfClass:NSURL.class]) {
        url = nil;
    }
    
    //创建了一个以SDWebImageOperation为协议的SDWebImageCombinedOperation类的实例 这个operation是用来取消在缓存寻找和下载的operation的 这个只是nsobject 缓存和下载的是nsoperation 它把控制这两个操作的operation封装在这个SDWebImageCombinedOperation类的实例里 倘若外面要取消 可以统一取消两种不同的处理
    __block SDWebImageCombinedOperation *operation = [SDWebImageCombinedOperation new];
    __weak SDWebImageCombinedOperation *weakOperation = operation;

    BOOL isFailedUrl = NO;
    if (url) {
        //判断在manager的failedURLs里是否含有该failed url
        @synchronized (self.failedURLs) {
            isFailedUrl = [self.failedURLs containsObject:url];
        }
    }
    
    //如果整个url的absoluteString为0 即整个url为空 或者!(options & SDWebImageRetryFailed) 和 isfailedurl同时为true 则会进入下面的判断
    //说说!(options & SDWebImageRetryFailed) 假如options设置了SDWebImageRetryFailed 则会无视isFailedUrl 跳过下面的判断 假如options为0 而由于SDWebImageRetryFailed为1 所以会返回为0 ps:0 & 1 = 0
    if (url.absoluteString.length == 0 || (!(options & SDWebImageRetryFailed) && isFailedUrl)) {
        //调用completionblock 该block 带一个error回去 并且返回方法的返回值operation
        [self callCompletionBlockForOperation:operation completion:completedBlock error:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorFileDoesNotExist userInfo:nil] url:url];
        return operation;
    }
    
    //同步锁self.runningOperations 并对其添加一个operation 这里是唯一强引用着这个operation的地方
    @synchronized (self.runningOperations) {
        [self.runningOperations addObject:operation];
    }
    //可以通过调用cacheKeyFilter对url进行动态化过滤url的东西 例如querystring
    NSString *key = [self cacheKeyForURL:url];
    
    //imagecache 是在初始化时创建的成员变量之一 属于sdimagecache类的 是异步搞缓存或者硬盘存储的操作的
    //queryCacheOperationForKey 方法是一个先在缓存寻找是否有该图像 假如没有 则会在别的队列里异步寻找硬盘是否有该图像 有则经过压缩后返回该图像 并会存在缓存里 寻找成功时会调用doneblock
    operation.cacheOperation = [self.imageCache queryCacheOperationForKey:key done:^(UIImage *cachedImage, NSData *cachedData, SDImageCacheType cacheType) {
        //判断假如该operation已经被cancel了 那就执行下面的方法
        if (operation.isCancelled) {
            //解除runningOperations对operation的强引用
            [self safelyRemoveOperationFromRunning:operation];
            return;
        }
        
        //判断假如没有找到图片时 或者options有SDWebImageRefreshCached时 并且 self.delegate 上没有实现imageManager:shouldDownloadImageForURL:时 或者shouldDownloadImageForURL方法返回yes时 则进入下面的方法
        
        if ((!cachedImage || options & SDWebImageRefreshCached) && (![self.delegate respondsToSelector:@selector(imageManager:shouldDownloadImageForURL:)] || [self.delegate imageManager:self shouldDownloadImageForURL:url])) {
            
            //如果有图片 可是options有SDWebImageRefreshCached时 则需要重新下载图片了 进入下面的判断
            if (cachedImage && options & SDWebImageRefreshCached) {
                // If image was found in the cache but SDWebImageRefreshCached is provided, notify about the cached image
                // AND try to re-download it in order to let a chance to NSURLCache to refresh it from server.
                
                //该方法就是在主线程调用completeblock 先告诉调用者找到了之前的缓存图片 可是接下来会继续下载新的图片
                //
                [self callCompletionBlockForOperation:weakOperation completion:completedBlock image:cachedImage data:cachedData error:nil cacheType:cacheType finished:YES url:url];
            }
            
            //能走下面的 都是要不没找到图片 要不就是要请求刷新 或者被delegate允许下载
            // download if no image or requested to refresh anyway, and download allowed by delegate
            
            //针对options 来换成对应的SDWebImageDownloaderOptions
            SDWebImageDownloaderOptions downloaderOptions = 0;
            //SDWebImageLowPriority 指的是先做完交互再下载
            if (options & SDWebImageLowPriority) downloaderOptions |= SDWebImageDownloaderLowPriority;
            //SDWebImageProgressiveDownload 指的是渐进式下载 即下载多少就看多少 默认是下载完才能看到
            if (options & SDWebImageProgressiveDownload) downloaderOptions |= SDWebImageDownloaderProgressiveDownload;
            //SDWebImageRefreshCached 指的是刷新缓存 就算有缓存也要重新下载
            if (options & SDWebImageRefreshCached) downloaderOptions |= SDWebImageDownloaderUseNSURLCache;
            //SDWebImageContinueInBackground 指的是就算app进入后台后也可以继续下载 若在后台执行超出限定时间则任务cancel
            if (options & SDWebImageContinueInBackground) downloaderOptions |= SDWebImageDownloaderContinueInBackground;
            //SDWebImageHandleCookies 指的是将cookies存在NSHTTPCookieStore
            if (options & SDWebImageHandleCookies) downloaderOptions |= SDWebImageDownloaderHandleCookies;
            //SDWebImageAllowInvalidSSLCertificates 指的是允许是非法ssl证书的网址也能下载
            if (options & SDWebImageAllowInvalidSSLCertificates) downloaderOptions |= SDWebImageDownloaderAllowInvalidSSLCertificates;
            //SDWebImageHighPriority 指的是将该下载提前到队列的最前面 默认是按照请求顺序来排列
            if (options & SDWebImageHighPriority) downloaderOptions |= SDWebImageDownloaderHighPriority;
            //SDWebImageScaleDownLargeImages 指的是图片在下载后会根据设备的约束内存来进行缩小 默认是下载图片的原始大小
            if (options & SDWebImageScaleDownLargeImages) downloaderOptions |= SDWebImageDownloaderScaleDownLargeImages;
            
            //如果options中有SDWebImageRefreshCached 则进入下面的判断
            if (cachedImage && options & SDWebImageRefreshCached) {
                //因为图片已经缓存了只是因为强制刷新 所以没必要渐进式下载 所以强制关闭SDWebImageDownloaderProgressiveDownload
                // force progressive off if image already cached but forced refreshing
                downloaderOptions &= ~SDWebImageDownloaderProgressiveDownload;
                // ignore image read from NSURLCache if image if cached but force refreshing
                
                //如果图片被缓存但强制刷新 忽略从nsurlcache读取的图片 所以要设置SDWebImageDownloaderIgnoreCachedResponse
                downloaderOptions |= SDWebImageDownloaderIgnoreCachedResponse;
            }
            
            SDWebImageDownloadToken *subOperationToken = [self.imageDownloader downloadImageWithURL:url options:downloaderOptions progress:progressBlock completed:^(UIImage *downloadedImage, NSData *downloadedData, NSError *error, BOOL finished) {
                __strong __typeof(weakOperation) strongOperation = weakOperation;
                //如果operation被cancel了或者被销毁
                if (!strongOperation || strongOperation.isCancelled) {
                    //如果这里调用了completedBlock 会跟新的completedBlock有产生竟态 假如这个completedBlock后调用 则会修改了新的completedBlock改变的状态
                    
                    
                    // Do nothing if the operation was cancelled
                    // See #699 for more details
                    // if we would call the completedBlock, there could be a race condition between this block and another completedBlock for the same object, so if this one is called second, we will overwrite the new data
                } else if (error) {
                    //在主线程下调用completedBlock
                    [self callCompletionBlockForOperation:strongOperation completion:completedBlock error:error url:url];
                    
                    //如果发生的错误不属于以下的问题 则将url添加到failedURLs中
                    if (   error.code != NSURLErrorNotConnectedToInternet
                        && error.code != NSURLErrorCancelled
                        && error.code != NSURLErrorTimedOut
                        && error.code != NSURLErrorInternationalRoamingOff
                        && error.code != NSURLErrorDataNotAllowed
                        && error.code != NSURLErrorCannotFindHost
                        && error.code != NSURLErrorCannotConnectToHost
                        && error.code != NSURLErrorNetworkConnectionLost) {
                        @synchronized (self.failedURLs) {
                            [self.failedURLs addObject:url];
                        }
                    }
                }
                else {
                    //假使它以前有错 现在进入回这里 因为SDWebImageRetryFailed之前的逻辑才能继续执行 所以可以在failedURLs下删除url
                    if ((options & SDWebImageRetryFailed)) {
                        @synchronized (self.failedURLs) {
                            [self.failedURLs removeObject:url];
                        }
                    }
                    
                    BOOL cacheOnDisk = !(options & SDWebImageCacheMemoryOnly);
                    
                    // We've done the scale process in SDWebImageDownloader with the shared manager, this is used for custom manager and avoid extra scale.
                    //如果是自定义的manager并有缓存键的筛选
                    if (self != [SDWebImageManager sharedManager] && self.cacheKeyFilter && downloadedImage) {
                        downloadedImage = [self scaledImageForKey:key image:downloadedImage];
                    }
                    
                    //如果找到缓存图片 并且因为SDWebImageRefreshCached才刷新 而且没有新的图 则无需做任何操作
                    if (options & SDWebImageRefreshCached && cachedImage && !downloadedImage) {
                        // Image refresh hit the NSURLCache cache, do not call the completion block
                        //图片刷新后跟NSURLCache的缓存有对比过 所以不用调用任何completionBlock
                        
                      //如果有新图 而且 不是动态图或者options设置了SDWebImageTransformAnimatedImage 而且有实现代理方法transformDownloadedImage 则进入下面的判断
                      //默认是不对动态图进行转换 因为通常这样做会损坏它 设置了SDWebImageTransformAnimatedImage 代表无论如何都要转换
                    } else if (downloadedImage && (!downloadedImage.images || (options & SDWebImageTransformAnimatedImage)) && [self.delegate respondsToSelector:@selector(imageManager:transformDownloadedImage:withURL:)]) {
                        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                            UIImage *transformedImage = [self.delegate imageManager:self transformDownloadedImage:downloadedImage withURL:url];

                            if (transformedImage && finished) {
                                BOOL imageWasTransformed = ![transformedImage isEqual:downloadedImage];
                                //假如图片被转换 会可能传递nil 所以我们可以重新从图片里计算图片数据大小
                                // pass nil if the image was transformed, so we can recalculate the data from the image
                                //可是这里没传comloeteBlock 是为了后面的调用
                                //判断是否将新图片保存在内存和硬盘里
                                [self.imageCache storeImage:transformedImage imageData:(imageWasTransformed ? nil : downloadedData) forKey:key toDisk:cacheOnDisk completion:nil];
                            }
                            
                            [self callCompletionBlockForOperation:strongOperation completion:completedBlock image:transformedImage data:downloadedData error:nil cacheType:SDImageCacheTypeNone finished:finished url:url];
                        });
                    } else {
                        if (downloadedImage && finished) {
                            //也是判断是否将新图片保存在内存和硬盘里
                            [self.imageCache storeImage:downloadedImage imageData:downloadedData forKey:key toDisk:cacheOnDisk completion:nil];
                        }
                        [self callCompletionBlockForOperation:strongOperation completion:completedBlock image:downloadedImage data:downloadedData error:nil cacheType:SDImageCacheTypeNone finished:finished url:url];
                    }
                }
                
                if (finished) {
                    [self safelyRemoveOperationFromRunning:strongOperation];
                }
            }];
            
            
            @synchronized(operation) {
                //保证每个operation都有自己的cancelBlock
                // Need same lock to ensure cancelBlock called because cancel method can be called in different queue
                operation.cancelBlock = ^{
                    //解除imageDownloader对下载operation的强引用 和解除下载operation本身属性的引用
                    [self.imageDownloader cancel:subOperationToken];
                    __strong __typeof(weakOperation) strongOperation = weakOperation;
                    //解除runningOperations对operation的强引用
                    [self safelyRemoveOperationFromRunning:strongOperation];
                };
            }
            //如果不需要下载 并找到cachedImage时
        } else if (cachedImage) {
            __strong __typeof(weakOperation) strongOperation = weakOperation;
            [self callCompletionBlockForOperation:strongOperation completion:completedBlock image:cachedImage data:cachedData error:nil cacheType:cacheType finished:YES url:url];
            [self safelyRemoveOperationFromRunning:operation];
            //既不需要下载 也找不到缓存图片
        } else {
            // Image not in cache and download disallowed by delegate
            __strong __typeof(weakOperation) strongOperation = weakOperation;
            [self callCompletionBlockForOperation:strongOperation completion:completedBlock image:nil data:nil error:nil cacheType:SDImageCacheTypeNone finished:YES url:url];
            [self safelyRemoveOperationFromRunning:operation];
        }
    }];

    return operation;
}

- (void)saveImageToCache:(nullable UIImage *)image forURL:(nullable NSURL *)url {
    if (image && url) {
        NSString *key = [self cacheKeyForURL:url];
        [self.imageCache storeImage:image forKey:key toDisk:YES completion:nil];
    }
}

- (void)cancelAll {
    @synchronized (self.runningOperations) {
        NSArray<SDWebImageCombinedOperation *> *copiedOperations = [self.runningOperations copy];
        [copiedOperations makeObjectsPerformSelector:@selector(cancel)];
        [self.runningOperations removeObjectsInArray:copiedOperations];
    }
}

- (BOOL)isRunning {
    BOOL isRunning = NO;
    @synchronized (self.runningOperations) {
        isRunning = (self.runningOperations.count > 0);
    }
    return isRunning;
}

- (void)safelyRemoveOperationFromRunning:(nullable SDWebImageCombinedOperation*)operation {
    //解除runningOperations对operation的强引用
    @synchronized (self.runningOperations) {
        if (operation) {
            [self.runningOperations removeObject:operation];
        }
    }
}

- (void)callCompletionBlockForOperation:(nullable SDWebImageCombinedOperation*)operation
                             completion:(nullable SDInternalCompletionBlock)completionBlock
                                  error:(nullable NSError *)error
                                    url:(nullable NSURL *)url {
    [self callCompletionBlockForOperation:operation completion:completionBlock image:nil data:nil error:error cacheType:SDImageCacheTypeNone finished:YES url:url];
}

- (void)callCompletionBlockForOperation:(nullable SDWebImageCombinedOperation*)operation
                             completion:(nullable SDInternalCompletionBlock)completionBlock
                                  image:(nullable UIImage *)image
                                   data:(nullable NSData *)data
                                  error:(nullable NSError *)error
                              cacheType:(SDImageCacheType)cacheType
                               finished:(BOOL)finished
                                    url:(nullable NSURL *)url {
    dispatch_main_async_safe(^{
        if (operation && !operation.isCancelled && completionBlock) {
            completionBlock(image, data, error, cacheType, finished, url);
        }
    });
}

@end


@implementation SDWebImageCombinedOperation

- (void)setCancelBlock:(nullable SDWebImageNoParamsBlock)cancelBlock {
    // check if the operation is already cancelled, then we just call the cancelBlock
    if (self.isCancelled) {
        if (cancelBlock) {
            cancelBlock();
        }
        _cancelBlock = nil; // don't forget to nil the cancelBlock, otherwise we will get crashes
    } else {
        _cancelBlock = [cancelBlock copy];
    }
}

- (void)cancel {
    @synchronized(self) {
        self.cancelled = YES;
        if (self.cacheOperation) {
            [self.cacheOperation cancel];
            self.cacheOperation = nil;
        }
        if (self.cancelBlock) {
            self.cancelBlock();
            self.cancelBlock = nil;
        }
    }
}

@end
