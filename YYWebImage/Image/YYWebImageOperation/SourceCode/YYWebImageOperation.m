//
//  YYWebImageOperation.m
//  YYWebImage <https://github.com/ibireme/YYWebImage>
//
//  Created by ibireme on 15/2/15.
//  Copyright (c) 2015 ibireme.
//
//  This source code is licensed under the MIT-style license found in the
//  LICENSE file in the root directory of this source tree.
//

#import "YYWebImageOperation.h"
#import "UIImage+YYWebImage.h"
#import <ImageIO/ImageIO.h>
#import <libkern/OSAtomic.h>

#if __has_include(<YYImage/YYImage.h>)
#import <YYImage/YYImage.h>
#else
#import "YYImage.h"
#endif


#define MIN_PROGRESSIVE_TIME_INTERVAL 0.2
#define MIN_PROGRESSIVE_BLUR_TIME_INTERVAL 0.4


/// Returns nil in App Extension.
static UIApplication *_YYSharedApplication() {
    static BOOL isAppExtension = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = NSClassFromString(@"UIApplication");
        if(!cls || ![cls respondsToSelector:@selector(sharedApplication)]) isAppExtension = YES;
        if ([[[NSBundle mainBundle] bundlePath] hasSuffix:@".appex"]) isAppExtension = YES;
    });
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
    return isAppExtension ? nil : [UIApplication performSelector:@selector(sharedApplication)];
#pragma clang diagnostic pop
}

/// Returns YES if the right-bottom pixel is filled.
static BOOL YYCGImageLastPixelFilled(CGImageRef image) {
    if (!image) return NO;
    //获取图片宽高
    size_t width = CGImageGetWidth(image);
    size_t height = CGImageGetHeight(image);
    if (width == 0 || height == 0) return NO;
    //创建一个width为1 height为1 的位图上下文
    CGContextRef ctx = CGBitmapContextCreate(NULL, 1, 1, 8, 0, YYCGColorSpaceGetDeviceRGB(), kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrderDefault);
    if (!ctx) return NO;
    //从左侧往右漏一点点
    CGContextDrawImage(ctx, CGRectMake( -(int)width + 1, 0, width, height), image);
    uint8_t *bytes = CGBitmapContextGetData(ctx);
    BOOL isAlpha = bytes && bytes[0] == 0;
    CFRelease(ctx);
    //获取是否能成功创建
    return !isAlpha;
}

/// Returns JPEG SOS (Start Of Scan) Marker
static NSData *JPEGSOSMarker() {
    // "Start Of Scan" Marker
    static NSData *marker = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        uint8_t bytes[2] = {0xFF, 0xDA};
        marker = [NSData dataWithBytes:bytes length:2];
    });
    return marker;
}


static NSMutableSet *URLBlacklist;
static dispatch_semaphore_t URLBlacklistLock;

static void URLBlacklistInit() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        URLBlacklist = [NSMutableSet new];
        URLBlacklistLock = dispatch_semaphore_create(1);
    });
}

static BOOL URLBlackListContains(NSURL *url) {
    if (!url || url == (id)[NSNull null]) return NO;
    URLBlacklistInit();
    dispatch_semaphore_wait(URLBlacklistLock, DISPATCH_TIME_FOREVER);
    BOOL contains = [URLBlacklist containsObject:url];
    dispatch_semaphore_signal(URLBlacklistLock);
    return contains;
}

static void URLInBlackListAdd(NSURL *url) {
    if (!url || url == (id)[NSNull null]) return;
    URLBlacklistInit();
    dispatch_semaphore_wait(URLBlacklistLock, DISPATCH_TIME_FOREVER);
    [URLBlacklist addObject:url];
    dispatch_semaphore_signal(URLBlacklistLock);
}


/// A proxy used to hold a weak object.
@interface _YYWebImageWeakProxy : NSProxy
@property (nonatomic, weak, readonly) id target;
- (instancetype)initWithTarget:(id)target;
+ (instancetype)proxyWithTarget:(id)target;
@end

@implementation _YYWebImageWeakProxy
- (instancetype)initWithTarget:(id)target {
    _target = target;
    return self;
}
+ (instancetype)proxyWithTarget:(id)target {
    return [[_YYWebImageWeakProxy alloc] initWithTarget:target];
}
- (id)forwardingTargetForSelector:(SEL)selector {
    return _target;
}
- (void)forwardInvocation:(NSInvocation *)invocation {
    void *null = NULL;
    [invocation setReturnValue:&null];
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return [NSObject instanceMethodSignatureForSelector:@selector(init)];
}
- (BOOL)respondsToSelector:(SEL)aSelector {
    return [_target respondsToSelector:aSelector];
}
- (BOOL)isEqual:(id)object {
    return [_target isEqual:object];
}
- (NSUInteger)hash {
    return [_target hash];
}
- (Class)superclass {
    return [_target superclass];
}
- (Class)class {
    return [_target class];
}
- (BOOL)isKindOfClass:(Class)aClass {
    return [_target isKindOfClass:aClass];
}
- (BOOL)isMemberOfClass:(Class)aClass {
    return [_target isMemberOfClass:aClass];
}
- (BOOL)conformsToProtocol:(Protocol *)aProtocol {
    return [_target conformsToProtocol:aProtocol];
}
- (BOOL)isProxy {
    return YES;
}
- (NSString *)description {
    return [_target description];
}
- (NSString *)debugDescription {
    return [_target debugDescription];
}
@end


@interface YYWebImageOperation() <NSURLConnectionDelegate>
@property (readwrite, getter=isExecuting) BOOL executing;
@property (readwrite, getter=isFinished) BOOL finished;
@property (readwrite, getter=isCancelled) BOOL cancelled;
@property (readwrite, getter=isStarted) BOOL started;
@property (nonatomic, strong) NSRecursiveLock *lock;
@property (nonatomic, strong) NSURLConnection *connection;
@property (nonatomic, strong) NSMutableData *data;
@property (nonatomic, assign) NSInteger expectedSize;
@property (nonatomic, assign) UIBackgroundTaskIdentifier taskID;

@property (nonatomic, assign) NSTimeInterval lastProgressiveDecodeTimestamp;
@property (nonatomic, strong) YYImageDecoder *progressiveDecoder;
@property (nonatomic, assign) BOOL progressiveIgnored;
@property (nonatomic, assign) BOOL progressiveDetected;
@property (nonatomic, assign) NSUInteger progressiveScanedLength;
@property (nonatomic, assign) NSUInteger progressiveDisplayCount;

@property (nonatomic, copy) YYWebImageProgressBlock progress;
@property (nonatomic, copy) YYWebImageTransformBlock transform;
@property (nonatomic, copy) YYWebImageCompletionBlock completion;
@end


@implementation YYWebImageOperation
@synthesize executing = _executing;
@synthesize finished = _finished;
@synthesize cancelled = _cancelled;

/// Network thread entry point.
+ (void)_networkThreadMain:(id)object {
    @autoreleasepool {
        //因为不能让runloop空转或者直接自动退出 所以添加了一个端口监听 让其保存存活
        [[NSThread currentThread] setName:@"com.ibireme.webimage.request"];
        NSRunLoop *runLoop = [NSRunLoop currentRunLoop];
        [runLoop addPort:[NSMachPort port] forMode:NSDefaultRunLoopMode];
        [runLoop run];
    }
}

/// Global image request network thread, used by NSURLConnection delegate.
+ (NSThread *)_networkThread {
    static NSThread *thread = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        //创建一个线程
        thread = [[NSThread alloc] initWithTarget:self selector:@selector(_networkThreadMain:) object:nil];
        if ([thread respondsToSelector:@selector(setQualityOfService:)]) {
            thread.qualityOfService = NSQualityOfServiceBackground;
        }
        [thread start];
    });
    return thread;
}

/// Global image queue, used for image reading and decoding.
+ (dispatch_queue_t)_imageQueue {
    #define MAX_QUEUE_COUNT 16
    static int queueCount;
    static dispatch_queue_t queues[MAX_QUEUE_COUNT];
    static dispatch_once_t onceToken;
    static int32_t counter = 0;
    dispatch_once(&onceToken, ^{
        //获取手机上可用的内核数量
        queueCount = (int)[NSProcessInfo processInfo].activeProcessorCount;
        //假如现可用内核数量大于MAX_QUEUE_COUNT 则queuecount为MAX_QUEUE_COUNT 否则为现可用内核数量
        queueCount = queueCount < 1 ? 1 : queueCount > MAX_QUEUE_COUNT ? MAX_QUEUE_COUNT : queueCount;
        //假如手机系统大于iOS8 则进入下面的判断
        if ([UIDevice currentDevice].systemVersion.floatValue >= 8.0) {
            for (NSUInteger i = 0; i < queueCount; i++) {
                //创建一个qos为QOS_CLASS_UTILITY的串行队列里
                //QOS_CLASS_USER_INTERACTIVE 指的是 由该线程执行的工作是与用户交互的
                //QOS_CLASS_USER_INITIATED 指的是 由该线程执行的工作是由用户发起的 并且用户会可能会等待其结果
                //QOS_CLASS_DEFAULT 指的是 系统在缺少更具体的QOS分类信息的情况下使用的默认QOS分类。 有时候跟关于用其他api创建的线程有关
                //QOS_CLASS_UTILITY 指的是 由该线程执行的工作可以或不可以由用户发起，并且用户不可能立即等待结果。
                //QOS_CLASS_BACKGROUND 指的是 由该线程执行的工作不可以由用户发起，而且用户可能不会意识到其结果
                //QOS_CLASS_UNSPECIFIED 指的是 可能由传统的api创建的线程 所以与QOS_CLASS产生相应的conflict或者incompatibale 导致缺乏关于QOS_CLASS的信息
                dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
                queues[i] = dispatch_queue_create("com.ibireme.image.decode", attr);
            }
        } else {
            for (NSUInteger i = 0; i < queueCount; i++) {
                //创建一个优先度低的串行队列
                queues[i] = dispatch_queue_create("com.ibireme.image.decode", DISPATCH_QUEUE_SERIAL);
                dispatch_set_target_queue(queues[i], dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0));
            }
        }
    });
    //随机获取一个32位的值 从而随机使用queues中某一个索引的queue
    int32_t cur = OSAtomicIncrement32(&counter);
    if (cur < 0) cur = -cur;
    return queues[(cur) % queueCount];
    #undef MAX_QUEUE_COUNT
}

- (instancetype)init {
    @throw [NSException exceptionWithName:@"YYWebImageOperation init error" reason:@"YYWebImageOperation must be initialized with a request. Use the designated initializer to init." userInfo:nil];
    return [self initWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@""]] options:0 cache:nil cacheKey:nil progress:nil transform:nil completion:nil];
}

- (instancetype)initWithRequest:(NSURLRequest *)request
                        options:(YYWebImageOptions)options
                          cache:(YYImageCache *)cache
                       cacheKey:(NSString *)cacheKey
                       progress:(YYWebImageProgressBlock)progress
                      transform:(YYWebImageTransformBlock)transform
                     completion:(YYWebImageCompletionBlock)completion {
    self = [super init];
    if (!self) return nil;
    if (!request) return nil;
    _request = request;
    _options = options;
    _cache = cache;
    _cacheKey = cacheKey ? cacheKey : request.URL.absoluteString;
    _shouldUseCredentialStorage = YES;
    _progress = progress;
    _transform = transform;
    _completion = completion;
    _executing = NO;
    _finished = NO;
    _cancelled = NO;
    _taskID = UIBackgroundTaskInvalid;
    //递归锁在这里的使用 其实可以用互斥锁进行 因为我觉得好像没有什么地方同一个线程递归调用
    _lock = [NSRecursiveLock new];
    return self;
}

- (void)dealloc {
    [_lock lock];
    if (_taskID != UIBackgroundTaskInvalid) {
        [_YYSharedApplication() endBackgroundTask:_taskID];
        _taskID = UIBackgroundTaskInvalid;
    }
    if ([self isExecuting]) {
        self.cancelled = YES;
        self.finished = YES;
        if (_connection) {
            [_connection cancel];
            if (![_request.URL isFileURL] && (_options & YYWebImageOptionShowNetworkActivity)) {
                [YYWebImageManager decrementNetworkActivityCount];
            }
        }
        if (_completion) {
            @autoreleasepool {
                _completion(nil, _request.URL, YYWebImageFromNone, YYWebImageStageCancelled, nil);
            }
        }
    }
    [_lock unlock];
}

- (void)_endBackgroundTask {
    //用递归锁上锁
    [_lock lock];
    //结束后台任务的处理
    if (_taskID != UIBackgroundTaskInvalid) {
        [_YYSharedApplication() endBackgroundTask:_taskID];
        _taskID = UIBackgroundTaskInvalid;
    }
    [_lock unlock];
}

#pragma mark - Runs in operation thread

- (void)_finish {
    //设置executing的值为no 设置finished的值为yes
    //代表该operation已完成
    self.executing = NO;
    self.finished = YES;
    [self _endBackgroundTask];
}

// runs on network thread
- (void)_startOperation {
    if ([self isCancelled]) return;
    @autoreleasepool {
        // get image from cache
        //从缓存中获取图片
        //如果有_cache实例
        //并且 _options 不含有 YYWebImageOptionUseNSURLCache 即不使用NSURLCache的缓存机制
        //并且 _options 不含有 YYWebImageOptionRefreshImageCache 即不需要强制更新该图片的缓存
        if (_cache &&
            !(_options & YYWebImageOptionUseNSURLCache) &&
            !(_options & YYWebImageOptionRefreshImageCache)) {
            UIImage *image = [_cache getImageForKey:_cacheKey withType:YYImageCacheTypeMemory];
            if (image) {
                [_lock lock];
                //如果没有被取消 则进入下面的判断
                if (![self isCancelled]) {
                    //调用_completionblock 返回图片 并告诉外面是通过YYWebImageFromMemoryCache获取图片
                    if (_completion) _completion(image, _request.URL, YYWebImageFromMemoryCache, YYWebImageStageFinished, nil);
                }
                [self _finish];
                [_lock unlock];
                return;
            }
            //如果_options 不含有 YYWebImageOptionIgnoreDiskCache 即表示不在本地上读取图片
            if (!(_options & YYWebImageOptionIgnoreDiskCache)) {
                __weak typeof(self) _self = self;
                //随机使用一条已创建的队列 异步执行下面的block
                dispatch_async([self.class _imageQueue], ^{
                    __strong typeof(_self) self = _self;
                    if (!self || [self isCancelled]) return;
                    //从本地上获取图片 若能成功获取到图片 则进入下面的判断
                    UIImage *image = [self.cache getImageForKey:self.cacheKey withType:YYImageCacheTypeDisk];
                    if (image) {
                        //将图片存储到缓存的链表开头上
                        [self.cache setImage:image imageData:nil forKey:self.cacheKey withType:YYImageCacheTypeMemory];
                        //在com.ibireme.webimage.request线程下执行调用_completionblock
                        [self performSelector:@selector(_didReceiveImageFromDiskCache:) onThread:[self.class _networkThread] withObject:image waitUntilDone:NO];
                    } else {
                        //若在本地上没有找到 则在com.ibireme.webimage.request线程执行请求图片数据
                        [self performSelector:@selector(_startRequest:) onThread:[self.class _networkThread] withObject:nil waitUntilDone:NO];
                    }
                });
                return;
            }
        }
    }
    [self performSelector:@selector(_startRequest:) onThread:[self.class _networkThread] withObject:nil waitUntilDone:NO];
}

// runs on network thread
- (void)_startRequest:(id)object {
    if ([self isCancelled]) return;
    @autoreleasepool {
        //如果黑名单里含有该url 而且 _options含有YYWebImageOptionIgnoreFailedURL 即限制被拉进黑名单的url时 则进入下面的判断
        if ((_options & YYWebImageOptionIgnoreFailedURL) && URLBlackListContains(_request.URL)) {
            NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorFileDoesNotExist userInfo:@{ NSLocalizedDescriptionKey : @"Failed to load URL, blacklisted." }];
            [_lock lock];
            //上锁 并调用_completionblock 告诉外面没图
            if (![self isCancelled]) {
                if (_completion) _completion(nil, _request.URL, YYWebImageFromNone, YYWebImageStageFinished, error);
            }
            [self _finish];
            [_lock unlock];
            return;
        }
        //判断该url是不是一个file://开头的 若是 则进入下面的判断
        if (_request.URL.isFileURL) {
            NSArray *keys = @[NSURLFileSizeKey];
            NSDictionary *attr = [_request.URL resourceValuesForKeys:keys error:nil];
            NSNumber *fileSize = attr[NSURLFileSizeKey];
            //通过url 获取到文件 并通过获取文件信息 获知文件大小
            _expectedSize = (fileSize != nil) ? fileSize.unsignedIntegerValue : -1;
        }
        
        // request image from web
        [_lock lock];
        if (![self isCancelled]) {
            //调用这个方法后 就会立刻向_request发出请求并从这请求里读取数据 后面就是根据NSURLConnectionDelegate的方法来处理数据
            _connection = [[NSURLConnection alloc] initWithRequest:_request delegate:[_YYWebImageWeakProxy proxyWithTarget:self]];
            if (![_request.URL isFileURL] && (_options & YYWebImageOptionShowNetworkActivity)) {
                //为判断是否需要的转菊花的值加一
                [YYWebImageManager incrementNetworkActivityCount];
            }
        }
        [_lock unlock];
    }
}

// runs on network thread, called from outer "cancel"
- (void)_cancelOperation {
    //当operation被外部取消时 则在名为com.ibireme.webimage.request的线程处理取消操作
    @autoreleasepool {
        //当urlconnection存在时 则进入下面的判断
        //NSURLConnection 是一个链接对应一个实例
        //NSURLSession 是多个task对应一个实例
        if (_connection) {
            //假如_requset的url是符合file://开头的 而且 当下载的时候要在状态码显示转菊花
            if (![_request.URL isFileURL] && (_options & YYWebImageOptionShowNetworkActivity)) {
                //减少一个链接个数 假如个数为0 则告诉修改状态栏转菊花的显示
                [YYWebImageManager decrementNetworkActivityCount];
            }
        }
        //取消_connection 并置空
        [_connection cancel];
        _connection = nil;
        //调用_completion block 被告诉外部block是被取消的信息
        if (_completion) _completion(nil, _request.URL, YYWebImageFromNone, YYWebImageStageCancelled, nil);
        [self _endBackgroundTask];
    }
}


// runs on network thread
- (void)_didReceiveImageFromDiskCache:(UIImage *)image {
    @autoreleasepool {
        [_lock lock];
        if (![self isCancelled]) {
            if (image) {
                //调用_completionblock 将图片返回 并告诉外面是通过本地获取的图片
                if (_completion) _completion(image, _request.URL, YYWebImageFromDiskCache, YYWebImageStageFinished, nil);
                //修改标识符
                [self _finish];
            } else {
                //若无图片 则走请求图片的执行 这里的话基本上不会走下面 只不过写多一个else做补充而已
                [self _startRequest:nil];
            }
        }
        [_lock unlock];
    }
}

- (void)_didReceiveImageFromWeb:(UIImage *)image {
    @autoreleasepool {
        [_lock lock];
        if (![self isCancelled]) {
            //如果_cache存在 则进入下面的判断
            if (_cache) {
                //如果imagea存在 或者 _options存在YYWebImageOptionRefreshImageCache 即强制刷新图片缓存
                if (image || (_options & YYWebImageOptionRefreshImageCache)) {
                    //获取的图片的完整数据
                    NSData *data = _data;
                    dispatch_async([YYWebImageOperation _imageQueue], ^{
                        //判断_options是否存在YYWebImageOptionIgnoreDiskCache 即不需要对本地缓存进行存取操作
                        YYImageCacheType cacheType = (_options & YYWebImageOptionIgnoreDiskCache) ? YYImageCacheTypeMemory : YYImageCacheTypeAll;
                        //进行本地或者缓存的存储处理
                        [_cache setImage:image imageData:data forKey:_cacheKey withType:cacheType];
                    });
                }
            }
            _data = nil;
            NSError *error = nil;
            //如果图片不存在 则进入下面的判断
            if (!image) {
                error = [NSError errorWithDomain:@"com.ibireme.image" code:-1 userInfo:@{ NSLocalizedDescriptionKey : @"Web image decode fail." }];
                //判断_options 是否含有YYWebImageOptionIgnoreFailedURL 即针对失败的url保存在黑名单里
                if (_options & YYWebImageOptionIgnoreFailedURL) {
                    if (URLBlackListContains(_request.URL)) {
                        error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorFileDoesNotExist userInfo:@{ NSLocalizedDescriptionKey : @"Failed to load URL, blacklisted." }];
                    } else {
                        URLInBlackListAdd(_request.URL);
                    }
                }
            }
            //调用_copletionblock
            if (_completion) _completion(image, _request.URL, YYWebImageFromRemote, YYWebImageStageFinished, error);
            //修改标志符
            [self _finish];
        }
        [_lock unlock];
    }
}

#pragma mark - NSURLConnectionDelegate runs in operation thread

- (BOOL)connectionShouldUseCredentialStorage:(NSURLConnection *)connection {
    //默认是YES
    return _shouldUseCredentialStorage;
}

- (void)connection:(NSURLConnection *)connection willSendRequestForAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge {
    @autoreleasepool {
        //如果验证方式是通过判断服务器证书是否合法 若是则进入下面的判断
        if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
            //如果_options不含有YYWebImageOptionAllowInvalidSSLCertificates 即不允许信任不可信ssl证书 而且  则进入下面的判断
            if (!(_options & YYWebImageOptionAllowInvalidSSLCertificates) &&
                [challenge.sender respondsToSelector:@selector(performDefaultHandlingForAuthenticationChallenge:)]) {
                //则challenge的发送方 即自定义的NSURLProtocol子类的实例来调用此方法。 执行默认的处理
                [challenge.sender performDefaultHandlingForAuthenticationChallenge:challenge];
            } else {
                //创建一个新的authentication credential 让客户端对该credential做处理
                NSURLCredential *credential = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];
                [[challenge sender] useCredential:credential forAuthenticationChallenge:challenge];
            }
        } else {
            //判断服务器是否拒绝过_credential 若无 则进入下面的判断
            if ([challenge previousFailureCount] == 0) {
                //尝试通过自定义的NSURLProtocol子类的实例向服务器发送该_credential
                if (_credential) {
                    [[challenge sender] useCredential:_credential forAuthenticationChallenge:challenge];
                } else {
                    //不使用_credential去发送验证
                    [[challenge sender] continueWithoutCredentialForAuthenticationChallenge:challenge];
                }
            } else {
                //不使用_credential去发送验证
                [[challenge sender] continueWithoutCredentialForAuthenticationChallenge:challenge];
            }
        }
    }
}

- (NSCachedURLResponse *)connection:(NSURLConnection *)connection willCacheResponse:(NSCachedURLResponse *)cachedResponse {
    if (!cachedResponse) return cachedResponse;
    //如果允许使用NSURLCache 则返回NSURLCache所存储到的响应缓存
    if (_options & YYWebImageOptionUseNSURLCache) {
        return cachedResponse;
    } else {
        // ignore NSURLCache
        return nil;
    }
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    @autoreleasepool {
        NSError *error = nil;
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSHTTPURLResponse *httpResponse = (id) response;
            NSInteger statusCode = httpResponse.statusCode;
            if (statusCode >= 400 || statusCode == 304) {
                //服务器错误
                error = [NSError errorWithDomain:NSURLErrorDomain code:statusCode userInfo:nil];
            }
        }
        if (error) {
            //当发生错误直接取消
            [_connection cancel];
            //并调用代理方法
            [self connection:_connection didFailWithError:error];
        } else {
            //获取预计图片大小
            if (response.expectedContentLength) {
                _expectedSize = (NSInteger)response.expectedContentLength;
                if (_expectedSize < 0) _expectedSize = -1;
            }
            //通过该预计大小 创建一个NSMutableData类的实例
            _data = [NSMutableData dataWithCapacity:_expectedSize > 0 ? _expectedSize : 0];
            //如果有_progress block 调用_progress
            if (_progress) {
                [_lock lock];
                if (![self isCancelled]) _progress(0, _expectedSize);
                [_lock unlock];
            }
        }
    }
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    @autoreleasepool {
        [_lock lock];
        BOOL canceled = [self isCancelled];
        [_lock unlock];
        if (canceled) return;
        //拼接数据
        if (data) [_data appendData:data];
        //调用_progress
        if (_progress) {
            [_lock lock];
            if (![self isCancelled]) {
                _progress(_data.length, _expectedSize);
            }
            [_lock unlock];
        }
        
        //渐进式的处理
        /*--------------------------- progressive ----------------------------*/
        //判断是否需要渐进式展示的下载
        BOOL progressive = (_options & YYWebImageOptionProgressive) > 0;
        //判断是否需要渐进式展示时模糊
        BOOL progressiveBlur = (_options & YYWebImageOptionProgressiveBlur) > 0;
        //如果不含有_completion 或者 progressive为false 或者 progressiveBlur为false 则return
        if (!_completion || !(progressive || progressiveBlur)) return;
        //走到下面的都是要渐进式显示处理
        //假如获取到的图片数据少于16bytes return
        if (data.length <= 16) return;
        //当获取到的图片数据超过预计图片的总大小的0.99时 return
        if (_expectedSize > 0 && data.length >= _expectedSize * 0.99) return;
        //当_progressiveIgnored为true return
        if (_progressiveIgnored) return;
        
        NSTimeInterval min = progressiveBlur ? MIN_PROGRESSIVE_BLUR_TIME_INTERVAL : MIN_PROGRESSIVE_TIME_INTERVAL;
        NSTimeInterval now = CACurrentMediaTime();
        //当现在的时间 减去 上次渐进式解码的timestamp 少于 min时 则 return
        if (now - _lastProgressiveDecodeTimestamp < min) return;
        
        if (!_progressiveDecoder) {
            _progressiveDecoder = [[YYImageDecoder alloc] initWithScale:[UIScreen mainScreen].scale];
        }
        //对图片进行解码 并更新每一帧的内容
        [_progressiveDecoder updateData:_data final:NO];
        if ([self isCancelled]) return;
        //通过获取到的图片数据 知道个图片的类型 然后再判断类型是不是 YYImageTypeUnknown 或者 YYImageTypeWebP 或者 YYImageTypeOther 若是 则进入下面的判断
        if (_progressiveDecoder.type == YYImageTypeUnknown ||
            _progressiveDecoder.type == YYImageTypeWebP ||
            _progressiveDecoder.type == YYImageTypeOther) {
            //将_progressiveDecoder置为nil 并且再下一次进来这个方法的时候不需要再做渐进式处理
            _progressiveDecoder = nil;
            _progressiveIgnored = YES;
            return;
        }
        //若需要做渐进式模糊 才进入下面的判断
        if (progressiveBlur) { // only support progressive JPEG and interlaced PNG
            if (_progressiveDecoder.type != YYImageTypeJPEG &&
                _progressiveDecoder.type != YYImageTypePNG) {
                _progressiveDecoder = nil;
                _progressiveIgnored = YES;
                return;
            }
        }
        //若解码后的帧数组仍为0 则直接return
        if (_progressiveDecoder.frameCount == 0) return;
        
        //要做渐进式 就会对每次获取到的数据进行图片合成 然后调用completionblock告诉外面
        //若不需要progressiveBlur
        if (!progressiveBlur) {
            //获取出第一帧的信息 并已经进行解压缩
            YYImageFrame *frame = [_progressiveDecoder frameAtIndex:0 decodeForDisplay:YES];
            if (frame.image) {
                [_lock lock];
                if (![self isCancelled]) {
                    //调用_completionblock 先返回第一帧的
                    _completion(frame.image, _request.URL, YYWebImageFromRemote, YYWebImageStageProgress, nil);
                    _lastProgressiveDecodeTimestamp = now;
                }
                [_lock unlock];
            }
            return;
        } else {
            //下面就是做progressiveBlur处理
            //如果是jpeg类型 则进入下面的判断
            if (_progressiveDecoder.type == YYImageTypeJPEG) {
                //_progressiveDetected 判断是否经过关于渐进式信息的获取
                if (!_progressiveDetected) {
                    NSDictionary *dic = [_progressiveDecoder framePropertiesAtIndex:0];
                    NSDictionary *jpeg = dic[(id)kCGImagePropertyJFIFDictionary];
                    //kCGImagePropertyJFIFIsProgressive 是否支持渐进式
                    NSNumber *isProg = jpeg[(id)kCGImagePropertyJFIFIsProgressive];
                    if (!isProg.boolValue) {
                        _progressiveIgnored = YES;
                        _progressiveDecoder = nil;
                        return;
                    }
                    _progressiveDetected = YES;
                }
                
                //这里处理的是 将每次新获取到的数据 然后通过截取新数据的一部分内容 寻找第一次出现有0xFF, 0xDA的范围 如果没找到或者被取消 则return
                //等于手动做隔行扫描的处理 判断他有没有隔行
                NSInteger scanLength = (NSInteger)_data.length - (NSInteger)_progressiveScanedLength - 4;
                if (scanLength <= 2) return;
                NSRange scanRange = NSMakeRange(_progressiveScanedLength, scanLength);
                NSRange markerRange = [_data rangeOfData:JPEGSOSMarker() options:kNilOptions range:scanRange];
                _progressiveScanedLength = _data.length;
                if (markerRange.location == NSNotFound) return;
                if ([self isCancelled]) return;
                
            } else if (_progressiveDecoder.type == YYImageTypePNG) {
                if (!_progressiveDetected) {
                    NSDictionary *dic = [_progressiveDecoder framePropertiesAtIndex:0];
                    NSDictionary *png = dic[(id)kCGImagePropertyPNGDictionary];
                    //获取其是否有隔行扫描的功能
                    NSNumber *isProg = png[(id)kCGImagePropertyPNGInterlaceType];
                    if (!isProg.boolValue) {
                        _progressiveIgnored = YES;
                        _progressiveDecoder = nil;
                        return;
                    }
                    _progressiveDetected = YES;
                }
            }
            
            YYImageFrame *frame = [_progressiveDecoder frameAtIndex:0 decodeForDisplay:YES];
            UIImage *image = frame.image;
            if (!image) return;
            if ([self isCancelled]) return;
            
            //判断是否能创建出一条线 有图片的线
            if (!YYCGImageLastPixelFilled(image.CGImage)) return;
            _progressiveDisplayCount++;
            
            CGFloat radius = 32;
            //这里的radius算出来不是很懂
            if (_expectedSize > 0) {
                radius *= 1.0 / (3 * _data.length / (CGFloat)_expectedSize + 0.6) - 0.25;
            } else {
                radius /= (_progressiveDisplayCount);
            }
            //对图片进行模糊 饱和度的处理
            image = [image yy_imageByBlurRadius:radius tintColor:nil tintMode:0 saturation:1 maskImage:nil];
            
            if (image) {
                [_lock lock];
                if (![self isCancelled]) {
                    //上锁 并调用completionblock
                    _completion(image, _request.URL, YYWebImageFromRemote, YYWebImageStageProgress, nil);
                    //设置_lastProgressiveDecodeTimestamp的时间戳
                    _lastProgressiveDecodeTimestamp = now;
                }
                [_lock unlock];
            }
        }
    }
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    @autoreleasepool {
        [_lock lock];
        _connection = nil;
        if (![self isCancelled]) {
            __weak typeof(self) _self = self;
            dispatch_async([self.class _imageQueue], ^{
                __strong typeof(_self) self = _self;
                if (!self) return;
                
                //判断是否需要解码
                BOOL shouldDecode = (self.options & YYWebImageOptionIgnoreImageDecoding) == 0;
                //是否不需要对动态图进行解码 即将动态码都当静态图处理
                BOOL allowAnimation = (self.options & YYWebImageOptionIgnoreAnimatedImage) == 0;
                UIImage *image;
                BOOL hasAnimation = NO;
                if (allowAnimation) {
                    //假如是动态图 调用下面的方法会将动态图的一些信息保存
                    image = [[YYImage alloc] initWithData:self.data scale:[UIScreen mainScreen].scale];
                    //解码
                    if (shouldDecode) image = [image yy_imageByDecoded];
                    if ([((YYImage *)image) animatedImageFrameCount] > 1) {
                        hasAnimation = YES;
                    }
                } else {
                    //
                    YYImageDecoder *decoder = [YYImageDecoder decoderWithData:self.data scale:[UIScreen mainScreen].scale];
                    image = [decoder frameAtIndex:0 decodeForDisplay:shouldDecode].image;
                }
                
                /*
                 If the image has animation, save the original image data to disk cache.
                 If the image is not PNG or JPEG, re-encode the image to PNG or JPEG for
                 better decoding performance.
                 */
                YYImageType imageType = YYImageDetectType((__bridge CFDataRef)self.data);
                switch (imageType) {
                    case YYImageTypeJPEG:
                    case YYImageTypeGIF:
                    case YYImageTypePNG:
                    case YYImageTypeWebP: { // save to disk cache
                        //如果不是动态图 就进入下面的判断
                        if (!hasAnimation) {
                            //如果其类型是gif 或者 webp 则清除所有获取到的图片数据 让他在本地缓存重编码
                            if (imageType == YYImageTypeGIF ||
                                imageType == YYImageTypeWebP) {
                                self.data = nil; // clear the data, re-encode for disk cache
                            }
                        }
                        //如果是动态图 就啥都没搞自动break
                    } break;
                    default: {
                        self.data = nil; // clear the data, re-encode for disk cache
                    } break;
                }
                if ([self isCancelled]) return;
                
                if (self.transform && image) {
                    //调用tranformblock 让外部对图片进行操作
                    UIImage *newImage = self.transform(image, self.request.URL);
                    if (newImage != image) {
                        self.data = nil;
                    }
                    image = newImage;
                    if ([self isCancelled]) return;
                }
                
                [self performSelector:@selector(_didReceiveImageFromWeb:) onThread:[self.class _networkThread] withObject:image waitUntilDone:NO];
            });
            if (![self.request.URL isFileURL] && (self.options & YYWebImageOptionShowNetworkActivity)) {
                [YYWebImageManager decrementNetworkActivityCount];
            }
        }
        [_lock unlock];
    }
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    //连接失败的时候的回调
    @autoreleasepool {
        [_lock lock];
        //判断是否被取消
        if (![self isCancelled]) {
            //调用_completionblock
            if (_completion) {
                _completion(nil, _request.URL, YYWebImageFromNone, YYWebImageStageFinished, error);
            }
            //解除对_connection的强引用
            _connection = nil;
            //解除对_data的强引用
            _data = nil;
            if (![_request.URL isFileURL] && (_options & YYWebImageOptionShowNetworkActivity)) {
                [YYWebImageManager decrementNetworkActivityCount];
            }
            //修改标志符
            [self _finish];
            
            if (_options & YYWebImageOptionIgnoreFailedURL) {
                //如果不是都下面的原因而连接失败 则将url添加黑名单
                if (error.code != NSURLErrorNotConnectedToInternet &&
                    error.code != NSURLErrorCancelled &&
                    error.code != NSURLErrorTimedOut &&
                    error.code != NSURLErrorUserCancelledAuthentication &&
                    error.code != NSURLErrorNetworkConnectionLost) {
                    URLInBlackListAdd(_request.URL);
                }
            }
        }
        [_lock unlock];
    }
}

#pragma mark - Override NSOperation

- (void)start {
    //重写start方法 则需要自行处理所有属性的值
    @autoreleasepool {
        //两个框架重写的start方法好像都要写一个锁来锁住
        [_lock lock];
        self.started = YES;
        //如果已经被取消 则进入下面的判断
        if (![self isCancelled]) {
            //在_networkThread线程下调用_cancelOperation方法
            [self performSelector:@selector(_cancelOperation) onThread:[[self class] _networkThread] withObject:nil waitUntilDone:NO modes:@[NSDefaultRunLoopMode]];
            self.finished = YES;
            //如果ready为true finish为false executing为false 即完美等待执行的状态 则进入下面的判断
        } else if ([self isReady] && ![self isFinished] && ![self isExecuting]) {
            //如果没传_request 那就直接调用_comloetionblock 并返回错误出去
            if (!_request) {
                self.finished = YES;
                if (_completion) {
                    NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorFileDoesNotExist userInfo:@{NSLocalizedDescriptionKey:@"request in nil"}];
                    _completion(nil, _request.URL, YYWebImageFromNone, YYWebImageStageFinished, error);
                }
            } else {
                //设置executing为true
                self.executing = YES;
                [self performSelector:@selector(_startOperation) onThread:[[self class] _networkThread] withObject:nil waitUntilDone:NO modes:@[NSDefaultRunLoopMode]];
                //如果_options含有 YYWebImageOptionAllowBackgroundTask 即允许在app进入后台的时候下载图片 并且 不是shared extesion下打开的 进入下面的判断
                if ((_options & YYWebImageOptionAllowBackgroundTask) && _YYSharedApplication()) {
                    __weak __typeof__ (self) _self = self;
                    if (_taskID == UIBackgroundTaskInvalid) {
                        //启动后台处理模式 并设置过期的响应
                        _taskID = [_YYSharedApplication() beginBackgroundTaskWithExpirationHandler:^{
                            __strong __typeof (_self) self = _self;
                            if (self) {
                                [self cancel];
                                self.finished = YES;
                            }
                        }];
                    }
                }
            }
        }
        [_lock unlock];
    }
}

- (void)cancel {
    //当NSOperationQueue中的operation被取消时 就会调用该方法
    
    [_lock lock];
    //如果没有被取消
    if (![self isCancelled]) {
        //则执行父类的cancel方法
        [super cancel];
        //将cancelled设为yes
        self.cancelled = YES;
        //如果已经在执行 即执行到start的内部
        if ([self isExecuting]) {
            //将executing设为no 然后在另一个线程上调用_cancelOperation方法
            self.executing = NO;
            [self performSelector:@selector(_cancelOperation) onThread:[[self class] _networkThread] withObject:nil waitUntilDone:NO modes:@[NSDefaultRunLoopMode]];
        }
        //如果只是刚开始执行start方法
        if (self.started) {
            //则直接设finished为yes就行了
            self.finished = YES;
        }
    }
    [_lock unlock];
}

- (void)setExecuting:(BOOL)executing {
    [_lock lock];
    if (_executing != executing) {
        [self willChangeValueForKey:@"isExecuting"];
        _executing = executing;
        [self didChangeValueForKey:@"isExecuting"];
    }
    [_lock unlock];
}

- (BOOL)isExecuting {
    [_lock lock];
    BOOL executing = _executing;
    [_lock unlock];
    return executing;
}

- (void)setFinished:(BOOL)finished {
    [_lock lock];
    if (_finished != finished) {
        [self willChangeValueForKey:@"isFinished"];
        _finished = finished;
        [self didChangeValueForKey:@"isFinished"];
    }
    [_lock unlock];
}

- (BOOL)isFinished {
    [_lock lock];
    BOOL finished = _finished;
    [_lock unlock];
    return finished;
}

- (void)setCancelled:(BOOL)cancelled {
    [_lock lock];
    if (_cancelled != cancelled) {
        [self willChangeValueForKey:@"isCancelled"];
        _cancelled = cancelled;
        [self didChangeValueForKey:@"isCancelled"];
    }
    [_lock unlock];
}

- (BOOL)isCancelled {
    [_lock lock];
    BOOL cancelled = _cancelled;
    [_lock unlock];
    return cancelled;
}

- (BOOL)isConcurrent {
    return YES;
}

- (BOOL)isAsynchronous {
    return YES;
}

+ (BOOL)automaticallyNotifiesObserversForKey:(NSString *)key {
    if ([key isEqualToString:@"isExecuting"] ||
        [key isEqualToString:@"isFinished"] ||
        [key isEqualToString:@"isCancelled"]) {
        return NO;
    }
    return [super automaticallyNotifiesObserversForKey:key];
}

- (NSString *)description {
    NSMutableString *string = [NSMutableString stringWithFormat:@"<%@: %p ",self.class, self];
    [string appendFormat:@" executing:%@", [self isExecuting] ? @"YES" : @"NO"];
    [string appendFormat:@" finished:%@", [self isFinished] ? @"YES" : @"NO"];
    [string appendFormat:@" cancelled:%@", [self isCancelled] ? @"YES" : @"NO"];
    [string appendString:@">"];
    return string;
}

@end
