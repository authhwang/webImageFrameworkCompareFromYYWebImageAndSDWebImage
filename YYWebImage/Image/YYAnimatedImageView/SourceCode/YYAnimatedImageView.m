//
//  YYAnimatedImageView.m
//  YYImage <https://github.com/ibireme/YYImage>
//
//  Created by ibireme on 14/10/19.
//  Copyright (c) 2015 ibireme.
//
//  This source code is licensed under the MIT-style license found in the
//  LICENSE file in the root directory of this source tree.
//

#import "YYAnimatedImageView.h"
#import "YYImageCoder.h"
#import <pthread.h>
#import <mach/mach.h>


#define BUFFER_SIZE (10 * 1024 * 1024) // 10MB (minimum memory buffer size)

#define LOCK(...) dispatch_semaphore_wait(self->_lock, DISPATCH_TIME_FOREVER); \
__VA_ARGS__; \
dispatch_semaphore_signal(self->_lock);

#define LOCK_VIEW(...) dispatch_semaphore_wait(view->_lock, DISPATCH_TIME_FOREVER); \
__VA_ARGS__; \
dispatch_semaphore_signal(view->_lock);


static int64_t _YYDeviceMemoryTotal() {
    int64_t mem = [[NSProcessInfo processInfo] physicalMemory];
    if (mem < -1) mem = -1;
        return mem;
}

static int64_t _YYDeviceMemoryFree() {
    mach_port_t host_port = mach_host_self();
    mach_msg_type_number_t host_size = sizeof(vm_statistics_data_t) / sizeof(integer_t);
    vm_size_t page_size;
    vm_statistics_data_t vm_stat;
    kern_return_t kern;
    
    kern = host_page_size(host_port, &page_size);
    if (kern != KERN_SUCCESS) return -1;
    kern = host_statistics(host_port, HOST_VM_INFO, (host_info_t)&vm_stat, &host_size);
    if (kern != KERN_SUCCESS) return -1;
    return vm_stat.free_count * page_size;
}

/**
 A proxy used to hold a weak object.
 It can be used to avoid retain cycles, such as the target in NSTimer or CADisplayLink.
 */
@interface _YYImageWeakProxy : NSProxy
@property (nonatomic, weak, readonly) id target;
- (instancetype)initWithTarget:(id)target;
+ (instancetype)proxyWithTarget:(id)target;
@end

@implementation _YYImageWeakProxy
- (instancetype)initWithTarget:(id)target {
    _target = target;
    return self;
}
+ (instancetype)proxyWithTarget:(id)target {
    return [[_YYImageWeakProxy alloc] initWithTarget:target];
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




typedef NS_ENUM(NSUInteger, YYAnimatedImageType) {
    YYAnimatedImageTypeNone = 0,
    YYAnimatedImageTypeImage,
    YYAnimatedImageTypeHighlightedImage,
    YYAnimatedImageTypeImages,
    YYAnimatedImageTypeHighlightedImages,
};

@interface YYAnimatedImageView() {
    @package
    UIImage <YYAnimatedImage> *_curAnimatedImage;
    
    dispatch_semaphore_t _lock; ///< lock for _buffer
    NSOperationQueue *_requestQueue; ///< image request queue, serial
    
    CADisplayLink *_link; ///< ticker for change frame
    NSTimeInterval _time; ///< time after last frame
    
    UIImage *_curFrame; ///< current frame to display
    NSUInteger _curIndex; ///< current frame index (from 0)
    NSUInteger _totalFrameCount; ///< total frame count
    
    BOOL _loopEnd; ///< whether the loop is end.
    NSUInteger _curLoop; ///< current loop count (from 0)
    NSUInteger _totalLoop; ///< total loop count, 0 means infinity
    
    NSMutableDictionary *_buffer; ///< frame buffer
    BOOL _bufferMiss; ///< whether miss frame on last opportunity
    NSUInteger _maxBufferCount; ///< maximum buffer count
    NSInteger _incrBufferCount; ///< current allowed buffer count (will increase by step)
    
    CGRect _curContentsRect;
    BOOL _curImageHasContentsRect; ///< image has implementated "animatedImageContentsRectAtIndex:"
}
@property (nonatomic, readwrite) BOOL currentIsPlayingAnimation;
- (void)calcMaxBufferCount;
@end

/// An operation for image fetch
@interface _YYAnimatedImageViewFetchOperation : NSOperation
@property (nonatomic, weak) YYAnimatedImageView *view;
@property (nonatomic, assign) NSUInteger nextIndex;
@property (nonatomic, strong) UIImage <YYAnimatedImage> *curImage;
@end

@implementation _YYAnimatedImageViewFetchOperation
- (void)main {
    __strong YYAnimatedImageView *view = _view;
    if (!view) return;
    if ([self isCancelled]) return;
    //_incrBufferCount加一
    //view->_incrBufferCount++;
    //进入该方法的时候 可能被调用reset animated方法 所以需要重新计算最大buffercount
    if (view->_incrBufferCount == 0) [view calcMaxBufferCount];
    //如果_incrBufferCount 超过 设备可接受的_maxBufferCount 则将_incrBufferCount 等于 _maxBufferCount
    if (view->_incrBufferCount > (NSInteger)view->_maxBufferCount) {
        view->_incrBufferCount = view->_maxBufferCount;
    }
    NSUInteger idx = _nextIndex;
    NSUInteger max = view->_incrBufferCount < 1 ? 1 : view->_incrBufferCount;
    NSUInteger total = view->_totalFrameCount;
    NSLog(@"operation _incrBufferCount - %ld",view->_incrBufferCount);
    NSLog(@"operation buffercount - %ld",view->_buffer.count);

    view = nil;

    for (int i = 0; i < max; i++,idx++) {
        @autoreleasepool {
            NSLog(@"operation - %ld",idx);
            //如果index 超过 总帧数 则将idx设置为0
            if (idx >= total) idx = 0;
            if ([self isCancelled]) break;
            __strong YYAnimatedImageView *view = _view;
            if (!view) break;
            LOCK_VIEW(BOOL miss = (view->_buffer[@(idx)] == nil));
            //如果miss 为 true 则表示缓存里没有这张图 则需要从头_curimage的decoder里获取
            if (miss) {
                //通过_curImage去获取在该idx帧下的图片
                UIImage *img = [_curImage animatedImageFrameAtIndex:idx];
                img = img.yy_imageByDecoded;
                if ([self isCancelled]) break;
//                LOCK_VIEW(view->_buffer[@(idx)] = img ? img : [NSNull null];
//                          if (img) view->_incrBufferCount++);
                LOCK_VIEW(view->_buffer[@(idx)] = img ? img : [NSNull null]);
                view = nil;
            }
        }
    }
}
@end

@implementation YYAnimatedImageView

- (instancetype)init {
    self = [super init];
    _runloopMode = NSRunLoopCommonModes;
    _autoPlayAnimatedImage = YES;
    return self;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    _runloopMode = NSRunLoopCommonModes;
    _autoPlayAnimatedImage = YES;
    return self;
}

- (instancetype)initWithImage:(UIImage *)image {
    self = [super init];
    //设置_runloopMode 和 _autoPlayAnimatedImage
    _runloopMode = NSRunLoopCommonModes;
    _autoPlayAnimatedImage = YES;
    self.frame = (CGRect) {CGPointZero, image.size };
    //下面会调用setimage方法
    self.image = image;
    return self;
}

- (instancetype)initWithImage:(UIImage *)image highlightedImage:(UIImage *)highlightedImage {
    self = [super init];
    //设置_runloopMode 和 _autoPlayAnimatedImage
    _runloopMode = NSRunLoopCommonModes;
    _autoPlayAnimatedImage = YES;
    CGSize size = image ? image.size : highlightedImage.size;
    self.frame = (CGRect) {CGPointZero, size };
    self.image = image;
    self.highlightedImage = highlightedImage;
    return self;
}

// init the animated params.
- (void)resetAnimated {
    //初始化动画的参数
    if (!_link) {
        _lock = dispatch_semaphore_create(1);
        _buffer = [NSMutableDictionary new];
        _requestQueue = [[NSOperationQueue alloc] init];
        //串行队列
        _requestQueue.maxConcurrentOperationCount = 1;
        
        //CADisplayLink 就是一个定时器 只不过它的调用时间是跟屏幕的刷新率有关
        _link = [CADisplayLink displayLinkWithTarget:[_YYImageWeakProxy proxyWithTarget:self] selector:@selector(step:)];
        if (_runloopMode) {
            [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:_runloopMode];
        }
        _link.paused = YES;
        
        //在进入后台 或者 发生内存警告时 都是将_buffer里的除了下一帧以外的全部清除
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReceiveMemoryWarning:) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    }
    
    [_requestQueue cancelAllOperations];
    LOCK(
         if (_buffer.count) {
             NSMutableDictionary *holder = _buffer;
             _buffer = [NSMutableDictionary new];
             //在新的线程下 清除原本在imageview的_buffer内容
             dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
                 // Capture the dictionary to global queue,
                 // release these images in background to avoid blocking UI thread.
                 [holder class];
             });
         }
    );
    _link.paused = YES;
    _time = 0;
    if (_curIndex != 0) {
        [self willChangeValueForKey:@"currentAnimatedImageIndex"];
        _curIndex = 0;
        [self didChangeValueForKey:@"currentAnimatedImageIndex"];
    }
    //设置参数
    _curAnimatedImage = nil;
    _curFrame = nil;
    _curLoop = 0;
    _totalLoop = 0;
    _totalFrameCount = 1;
    _loopEnd = NO;
    _bufferMiss = NO;
    _incrBufferCount = 0;
}

- (void)setImage:(UIImage *)image {
    if (self.image == image) return;
    [self setImage:image withType:YYAnimatedImageTypeImage];
}

- (void)setHighlightedImage:(UIImage *)highlightedImage {
    if (self.highlightedImage == highlightedImage) return;
    [self setImage:highlightedImage withType:YYAnimatedImageTypeHighlightedImage];
}

- (void)setAnimationImages:(NSArray *)animationImages {
    if (self.animationImages == animationImages) return;
    [self setImage:animationImages withType:YYAnimatedImageTypeImages];
}

- (void)setHighlightedAnimationImages:(NSArray *)highlightedAnimationImages {
    if (self.highlightedAnimationImages == highlightedAnimationImages) return;
    [self setImage:highlightedAnimationImages withType:YYAnimatedImageTypeHighlightedImages];
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    if (_link) [self resetAnimated];
    [self imageChanged];
}

- (id)imageForType:(YYAnimatedImageType)type {
    switch (type) {
        case YYAnimatedImageTypeNone: return nil;
        case YYAnimatedImageTypeImage: return self.image;
        case YYAnimatedImageTypeHighlightedImage: return self.highlightedImage;
        case YYAnimatedImageTypeImages: return self.animationImages;
        case YYAnimatedImageTypeHighlightedImages: return self.highlightedAnimationImages;
    }
    return nil;
}

- (YYAnimatedImageType)currentImageType {
    YYAnimatedImageType curType = YYAnimatedImageTypeNone;
    if (self.highlighted) {
        if (self.highlightedAnimationImages.count) curType = YYAnimatedImageTypeHighlightedImages;
        else if (self.highlightedImage) curType = YYAnimatedImageTypeHighlightedImage;
    }
    if (curType == YYAnimatedImageTypeNone) {
        if (self.animationImages.count) curType = YYAnimatedImageTypeImages;
        else if (self.image) curType = YYAnimatedImageTypeImage;
    }
    return curType;
}

- (void)setImage:(id)image withType:(YYAnimatedImageType)type {
    [self stopAnimating];
    //刚创建的时候_link为nil 所以没进入该方法
    if (_link) [self resetAnimated];
    _curFrame = nil;
    switch (type) {
        case YYAnimatedImageTypeNone: break;
        case YYAnimatedImageTypeImage: super.image = image; break;
        case YYAnimatedImageTypeHighlightedImage: super.highlightedImage = image; break;
        case YYAnimatedImageTypeImages: super.animationImages = image; break;
        case YYAnimatedImageTypeHighlightedImages: super.highlightedAnimationImages = image; break;
    }
    [self imageChanged];
}

- (void)imageChanged {
    //获取type
    YYAnimatedImageType newType = [self currentImageType];
    id newVisibleImage = [self imageForType:newType];
    NSUInteger newImageFrameCount = 0;
    BOOL hasContentsRect = NO;
    if ([newVisibleImage isKindOfClass:[UIImage class]] &&
        [newVisibleImage conformsToProtocol:@protocol(YYAnimatedImage)]) {
        //返回decoder的framecount
        newImageFrameCount = ((UIImage<YYAnimatedImage> *) newVisibleImage).animatedImageFrameCount;
        if (newImageFrameCount > 1) {
            hasContentsRect = [((UIImage<YYAnimatedImage> *) newVisibleImage) respondsToSelector:@selector(animatedImageContentsRectAtIndex:)];
        }
    }
    //如果hasContentsRect为false 而且 _curImageHasContentsRect 为true 则进入下面的判断
    if (!hasContentsRect && _curImageHasContentsRect) {
        //如果contentRect 不等于 （0，0，1，1）则进入下面的判断
        if (!CGRectEqualToRect(self.layer.contentsRect, CGRectMake(0, 0, 1, 1)) ) {
            [CATransaction begin];
            //设置由于此treasaction所做的属性更改而触发的操作
            [CATransaction setDisableActions:YES];
            //直接将contentRect设置成
            self.layer.contentsRect = CGRectMake(0, 0, 1, 1);
            [CATransaction commit];
        }
    }
    _curImageHasContentsRect = hasContentsRect;
    //如果声明animatedImageContentsRectAtIndex方法 则进入下面的判断
    
    if (hasContentsRect) {
        //获取第一帧的图片大小
        CGRect rect = [((UIImage<YYAnimatedImage> *) newVisibleImage) animatedImageContentsRectAtIndex:0];
        NSLog(@"rect - %@",NSStringFromCGRect(rect));
        NSLog(@"image - %@",NSStringFromCGSize(((UIImage *)newVisibleImage).size));
        [self setContentsRect:rect forImage:newVisibleImage];
    }
    
    if (newImageFrameCount > 1) {
        [self resetAnimated];
        _curAnimatedImage = newVisibleImage;
        _curFrame = newVisibleImage;
        _totalLoop = _curAnimatedImage.animatedImageLoopCount;
        _totalFrameCount = _curAnimatedImage.animatedImageFrameCount;
        [self calcMaxBufferCount];
    }
    [self setNeedsDisplay];
    [self didMoved];
}

// dynamically adjust buffer size for current memory.
- (void)calcMaxBufferCount {
    int64_t bytes = (int64_t)_curAnimatedImage.animatedImageBytesPerFrame;
    if (bytes == 0) bytes = 1024;
    
    int64_t total = _YYDeviceMemoryTotal();
    int64_t free = _YYDeviceMemoryFree();
    int64_t max = MIN(total * 0.2, free * 0.6);
    max = MAX(max, BUFFER_SIZE);
    //__maxBufferSize 外界设置的最大buffer体积
    if (_maxBufferSize) max = max > _maxBufferSize ? _maxBufferSize : max;
    double maxBufferCount = (double)max / (double)bytes;
    if (maxBufferCount < 1) maxBufferCount = 1;
    else if (maxBufferCount > 512) maxBufferCount = 512;
    //获取到最大buffer的帧个数
    _maxBufferCount = maxBufferCount;
}

- (void)dealloc {
    [_requestQueue cancelAllOperations];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidEnterBackgroundNotification object:nil];
    [_link invalidate];
}

- (BOOL)isAnimating {
    return self.currentIsPlayingAnimation;
}

- (void)stopAnimating {
    [super stopAnimating];
    //暂停_requestQueue里所有的operation 以及暂停CADisplayLink的实例
    [_requestQueue cancelAllOperations];
    _link.paused = YES;
    self.currentIsPlayingAnimation = NO;
}

- (void)startAnimating {
    //开启动画 假如是用Images的就用UIImageView的startAnimating方法
    //若不是 则使用CADisplayLink来开始动画
    YYAnimatedImageType type = [self currentImageType];
    if (type == YYAnimatedImageTypeImages || type == YYAnimatedImageTypeHighlightedImages) {
        NSArray *images = [self imageForType:type];
        if (images.count > 0) {
            [super startAnimating];
            self.currentIsPlayingAnimation = YES;
        }
    } else {
        if (_curAnimatedImage && _link.paused) {
            _curLoop = 0;
            _loopEnd = NO;
            _link.paused = NO;
            self.currentIsPlayingAnimation = YES;
        }
    }
}

- (void)didReceiveMemoryWarning:(NSNotification *)notification {
    [_requestQueue cancelAllOperations];
    [_requestQueue addOperationWithBlock: ^{
        //这个还不知道有什么用
        _incrBufferCount = -60 - (int)(arc4random() % 120); // about 1~3 seconds to grow back..
        //获取下一帧
        NSNumber *next = @((_curIndex + 1) % _totalFrameCount);
        LOCK(
             NSArray * keys = _buffer.allKeys;
             for (NSNumber * key in keys) {
                 //如果不是下一帧的 全部清除
                 if (![key isEqualToNumber:next]) { // keep the next frame for smoothly animation
                     [_buffer removeObjectForKey:key];
                 }
             }
        )//LOCK
    }];
}

- (void)didEnterBackground:(NSNotification *)notification {
    [_requestQueue cancelAllOperations];
    NSNumber *next = @((_curIndex + 1) % _totalFrameCount);
    LOCK(
         //除了下一帧以外的全部清除
         NSArray * keys = _buffer.allKeys;
         for (NSNumber * key in keys) {
             if (![key isEqualToNumber:next]) { // keep the next frame for smoothly animation
                 [_buffer removeObjectForKey:key];
             }
         }
     )//LOCK
}

- (void)step:(CADisplayLink *)link {
    UIImage <YYAnimatedImage> *image = _curAnimatedImage;
    NSMutableDictionary *buffer = _buffer;
    //bufferedImage 这里会有个问题 因为有可能绘制不出图片 所以在operation下传了NSNull进去
    //可是假如总帧数和buffer count 相等的话
    //就会导致不会再去绘制图片 所以感觉这里可能还是需要多个判断
    UIImage *bufferedImage = nil;
    //获取下一帧的索引
    NSUInteger nextIndex = (_curIndex + 1) % _totalFrameCount;
    BOOL bufferIsFull = NO;
    
    if (!image) return;
    //如果循环结束 就进入下面的判断
    if (_loopEnd) { // view will keep in last frame
        [self stopAnimating];
        return;
    }
    
    NSTimeInterval delay = 0;
    //_bufferMiss还不是很知道
    if (!_bufferMiss) {
        //_time 加上 上次屏幕刷新的时间
        _time += link.duration;
        
        delay = [image animatedImageDurationAtIndex:_curIndex];
        //这里的意思是 因为每一帧需要一定的delay时间去展示
        //所以虽然刷新的时间很快 可是要经过delay时间去展示后 才会进行去下一帧的跳转
        if (_time < delay) return;
        //当超过那个展示时间后 就将上一帧的展示时间减去 留下_time跟下一帧去对比 不影响下一帧
        _time -= delay;
        //当循环完第一轮后 进入下面的判断
        if (nextIndex == 0) {
            
            _curLoop++;
            //如果超过总循环次数 而且 总循环次数不为0 则进入下面的判断
            if (_curLoop >= _totalLoop && _totalLoop != 0) {
                //将_loopEnd 设置为0 停止动画
                _loopEnd = YES;
                [self stopAnimating];
                [self.layer setNeedsDisplay]; // let system call `displayLayer:` before runloop sleep
                return; // stop at last frame
            }
        }
        //获取下一帧的需要delay的展示时间
        //如果_time过大的时候 就将_time设置为下一帧需要的delay 这样会显得比较连贯？
        delay = [image animatedImageDurationAtIndex:nextIndex];
        if (_time > delay) _time = delay; // do not jump over frame
    }
    LOCK(
         bufferedImage = buffer[@(nextIndex)];
         //判断是否有下一帧的缓存图片 若有 则进入下面的判断
         if (bufferedImage) {
//             NSLog(@"_incrBufferCount - %ld",_incrBufferCount);
//             NSLog(@"buffercount - %ld",buffer.count);
             //如果没有这个判断 _incrBufferCount的值会算不准
             //因为operation的循环里是无脑idx++
             //所以会导致_incrBufferCount还没到_maxBufferCount前 就会将图片都缓存完了
             //可是加了这个判断会引发cpu暴涨的问题
             //因为会导致一直使buffer.count小于_totalFrameCount
             //operation一直都需要工作
             //所以我觉得最好的办法要不就不需要idx在循环里增加
             //要不就让图片先预加入buffer里 即让idx在循环里增加 可是_incrBufferCount++要在图片设置在buffer时设置
             if ((int)_incrBufferCount < _totalFrameCount) {
                 [buffer removeObjectForKey:@(nextIndex)];
             }
             [self willChangeValueForKey:@"currentAnimatedImageIndex"];
             _curIndex = nextIndex;
             [self didChangeValueForKey:@"currentAnimatedImageIndex"];
             _curFrame = bufferedImage == (id)[NSNull null] ? nil : bufferedImage;
             //如果_curImageHasContentsRect 有值 则代表image有声明animatedImageContentsRectAtIndex方法
             if (_curImageHasContentsRect) {
                 //设置layer.contentRect
                 _curContentsRect = [image animatedImageContentsRectAtIndex:_curIndex];
                 [self setContentsRect:_curContentsRect forImage:_curFrame];
             }
             //获取下一帧
             nextIndex = (_curIndex + 1) % _totalFrameCount;
             _bufferMiss = NO;
             //如果buffercount 等于总帧数 则代表已经全部缓存
             if (buffer.count == _totalFrameCount) {
                 NSLog(@"走了这里");
                 NSLog(@"走了这里 _incrBufferCount - %ld",_incrBufferCount);
                 NSLog(@"走了这里 buffercount - %ld",buffer.count);

                 bufferIsFull = YES;
             }
         } else {
             //当没获取到缓存图时 则下次再进入step方法时 会跳过上面对_time的计算 再判断是否已经获取到图
             _bufferMiss = YES;
         }
    )//LOCK
    
    //当成功获取到图片时 就去调用displayLayer显示图片
    if (!_bufferMiss) {
        [self.layer setNeedsDisplay]; // let system call `displayLayer:` before runloop sleep
    }
    
    //当缓存没满 而且 _requestQueue的operation个数为0 即没operation干活 则添加一个新的operation
    if (!bufferIsFull && _requestQueue.operationCount == 0) { // if some work not finished, wait for next opportunity
        _YYAnimatedImageViewFetchOperation *operation = [_YYAnimatedImageViewFetchOperation new];
        operation.view = self;
        operation.nextIndex = nextIndex;
        operation.curImage = image;
        [_requestQueue addOperation:operation];
    }
}

- (void)displayLayer:(CALayer *)layer {
    //当调用self.layer setNeedsDisplay时 系统就会调用这个方法
    //从而展示最后那帧
    if (_curFrame) {
        layer.contents = (__bridge id)_curFrame.CGImage;
    }
}

- (void)setContentsRect:(CGRect)rect forImage:(UIImage *)image{
    CGRect layerRect = CGRectMake(0, 0, 1, 1);
    if (image) {
        CGSize imageSize = image.size;
        if (imageSize.width > 0.01 && imageSize.height > 0.01) {
            layerRect.origin.x = rect.origin.x / imageSize.width;
            layerRect.origin.y = rect.origin.y / imageSize.height;
            layerRect.size.width = rect.size.width / imageSize.width;
            layerRect.size.height = rect.size.height / imageSize.height;
            //获取layerRect和CGRectMake(0, 0, 1, 1)的相交部分
            layerRect = CGRectIntersection(layerRect, CGRectMake(0, 0, 1, 1));
            //如果不相交 则进入下面的判断
            if (CGRectIsNull(layerRect) || CGRectIsEmpty(layerRect)) {
                layerRect = CGRectMake(0, 0, 1, 1);
            }
        }
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.layer.contentsRect = layerRect;
    [CATransaction commit];
}

- (void)didMoved {
    if (self.autoPlayAnimatedImage) {
        if(self.superview && self.window) {
            [self startAnimating];
        } else {
            [self stopAnimating];
        }
    }
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self didMoved];
}

- (void)didMoveToSuperview {
    [super didMoveToSuperview];
    [self didMoved];
}

- (void)setCurrentAnimatedImageIndex:(NSUInteger)currentAnimatedImageIndex {
    if (!_curAnimatedImage) return;
    if (currentAnimatedImageIndex >= _curAnimatedImage.animatedImageFrameCount) return;
    if (_curIndex == currentAnimatedImageIndex) return;
    
    void (^block)() = ^{
        LOCK(
             [_requestQueue cancelAllOperations];
             [_buffer removeAllObjects];
             [self willChangeValueForKey:@"currentAnimatedImageIndex"];
             _curIndex = currentAnimatedImageIndex;
             [self didChangeValueForKey:@"currentAnimatedImageIndex"];
             _curFrame = [_curAnimatedImage animatedImageFrameAtIndex:_curIndex];
             if (_curImageHasContentsRect) {
                 _curContentsRect = [_curAnimatedImage animatedImageContentsRectAtIndex:_curIndex];
             }
             _time = 0;
             _loopEnd = NO;
             _bufferMiss = NO;
             [self.layer setNeedsDisplay];
        )//LOCK
    };
    
    if (pthread_main_np()) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

- (NSUInteger)currentAnimatedImageIndex {
    return _curIndex;
}

- (void)setRunloopMode:(NSString *)runloopMode {
    if ([_runloopMode isEqual:runloopMode]) return;
    if (_link) {
        if (_runloopMode) {
            [_link removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:_runloopMode];
        }
        if (runloopMode.length) {
            [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:runloopMode];
        }
    }
    _runloopMode = runloopMode.copy;
}

#pragma mark - Override NSObject(NSKeyValueObservingCustomization)

+ (BOOL)automaticallyNotifiesObserversForKey:(NSString *)key {
    if ([key isEqualToString:@"currentAnimatedImageIndex"]) {
        return NO;
    }
    return [super automaticallyNotifiesObserversForKey:key];
}

#pragma mark - NSCoding

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
    self = [super initWithCoder:aDecoder];
    _runloopMode = [aDecoder decodeObjectForKey:@"runloopMode"];
    if (_runloopMode.length == 0) _runloopMode = NSRunLoopCommonModes;
    if ([aDecoder containsValueForKey:@"autoPlayAnimatedImage"]) {
        _autoPlayAnimatedImage = [aDecoder decodeBoolForKey:@"autoPlayAnimatedImage"];
    } else {
        _autoPlayAnimatedImage = YES;
    }
    
    UIImage *image = [aDecoder decodeObjectForKey:@"YYAnimatedImage"];
    UIImage *highlightedImage = [aDecoder decodeObjectForKey:@"YYHighlightedAnimatedImage"];
    if (image) {
        self.image = image;
        [self setImage:image withType:YYAnimatedImageTypeImage];
    }
    if (highlightedImage) {
        self.highlightedImage = highlightedImage;
        [self setImage:highlightedImage withType:YYAnimatedImageTypeHighlightedImage];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)aCoder {
    [super encodeWithCoder:aCoder];
    [aCoder encodeObject:_runloopMode forKey:@"runloopMode"];
    [aCoder encodeBool:_autoPlayAnimatedImage forKey:@"autoPlayAnimatedImage"];
    
    BOOL ani, multi;
    ani = [self.image conformsToProtocol:@protocol(YYAnimatedImage)];
    multi = (ani && ((UIImage <YYAnimatedImage> *)self.image).animatedImageFrameCount > 1);
    if (multi) [aCoder encodeObject:self.image forKey:@"YYAnimatedImage"];
    
    ani = [self.highlightedImage conformsToProtocol:@protocol(YYAnimatedImage)];
    multi = (ani && ((UIImage <YYAnimatedImage> *)self.highlightedImage).animatedImageFrameCount > 1);
    if (multi) [aCoder encodeObject:self.highlightedImage forKey:@"YYHighlightedAnimatedImage"];
}

@end
