# SDImageCache

这个类整个就是负责缓存寻找和硬盘寻找的工作啦～ 先看它的init方法吧

```objective-c
- (instancetype)init {
    return [self initWithNamespace:@"default"];
}

- (nonnull instancetype)initWithNamespace:(nonnull NSString *)ns {
    //在NSCachesDirectory下创建一个default文件夹
    NSString *path = [self makeDiskCachePath:ns];
    return [self initWithNamespace:ns diskCacheDirectory:path];
}

- (nonnull instancetype)initWithNamespace:(nonnull NSString *)ns
                       diskCacheDirectory:(nonnull NSString *)directory {
    if ((self = [super init])) {
        NSString *fullNamespace = [@"com.hackemist.SDWebImageCache." stringByAppendingString:ns];
        
        //在这里开始创建一个io串行队列
        // Create IO serial queue
        _ioQueue = dispatch_queue_create("com.hackemist.SDWebImageCache", DISPATCH_QUEUE_SERIAL);
        
        //缓存设置类实例
        _config = [[SDImageCacheConfig alloc] init];
        
        // Init the memory cache
        //nscache为其父类
        _memCache = [[AutoPurgeCache alloc] init];
        _memCache.name = fullNamespace;

        // Init the disk cache
        //硬盘缓存
        if (directory != nil) {
            _diskCachePath = [directory stringByAppendingPathComponent:fullNamespace];
        } else {
            NSString *path = [self makeDiskCachePath:ns];
            _diskCachePath = path;
        }
        
        //_filemanager要在该_ioQueue队列用 
        dispatch_sync(_ioQueue, ^{
            _fileManager = [NSFileManager new];
        });

#if SD_UIKIT
        //三个通知
        // Subscribe to app events
        //出现内存警告时 清除缓存
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(clearMemory)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];
        //当应用将要销毁时 检查是否有过期文件 有则删除
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(deleteOldFiles)
                                                     name:UIApplicationWillTerminateNotification
                                                   object:nil];
        
        //当应用进入后台时 会在后台检查是否有过期文件 有则删除
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(backgroundDeleteOldFiles)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
#endif
    }

    return self;
}
```

注意点：

1. init方法调用时 创建了五个**成员变量**
   * _memCache 是AutoPurgeCache类创建的实例 该父类是NSCache AutoPurgeCache做的是增加了一个通知 当收到UIApplicationDidReceiveMemoryWarningNotification通知时要清空内存
   * _diskCachePath 是指存在硬盘的文件夹路径 是在NSCachesDirectory下创建的 假如要手机要清理硬盘容量时 会首先清除NSCachesDirectory下的
   * _ioQueue 是专门为SDImageCache实例服务的串行队列 用于创建文件的创建或者删除 图片的解压缩等工作 可以防止阻塞主线程
   * _customsPath是一个含有只读文件路径的数组 该路径可能是有一些已经预加载过缓存的图片
   * _fileManager NSFileManger类的实例

下面的这个方法是根据 SDWebImageManager的逻辑调用的方法 我们先从这个方法看起

```objective-c
- (nullable NSOperation *)queryCacheOperationForKey:(nullable NSString *)key done:(nullable SDCacheQueryCompletedBlock)doneBlock;
```

这个方法分为两个部分 一部分是**从缓存寻找** 另一部分是**从硬盘寻找**

第一部分：

```objective-c
    //如果key即url为空时 即SDWebImageManager的第二部分
    if (!key) {
        if (doneBlock) {
            doneBlock(nil, nil, SDImageCacheTypeNone);
        }
        return nil;
    }

    // First check the in-memory cache...
    //首先检查缓存是否含有该url的图片 如果有 则走下面的判断
    //假如在缓存里找到image 则diskData就有可能为nil
    UIImage *image = [self imageFromMemoryCacheForKey:key];
    if (image) {
        NSData *diskData = nil;
        //判断该图片是否为一个含有多张图片的动态图
        if (image.images) {
            //会通过是否有后缀名的方式在各个硬盘路径下寻找文件
            diskData = [self diskImageDataBySearchingAllPathsForKey:key];
        }
        //如果有设置doneBlock 即SDWebImageManager的第二部分 则调用
        if (doneBlock) {
            doneBlock(image, diskData, SDImageCacheTypeMemory);
        }
        return nil;
    }
```

第二部分：

```objective-c
 //这个operation的意义在于 因为是在别的队列下async处理获取工作 所以 有可能会在主线程调用栈结束前 该uiview实例又需要对别的url获取 所以就会需要把这个的operation先给取消掉
    //那么在该operation被取消后 回到这个ioQueue时 由于operation已被取消了 所以就不需要再去硬盘里获取图片 防止出现旧的图片
    NSOperation *operation = [NSOperation new];
    dispatch_async(self.ioQueue, ^{
        if (operation.isCancelled) {
            // do not call the completion if cancelled
            return;
        }

        @autoreleasepool {
            //从各个路径下寻找是否有同名文件 有则返回其数据
            NSData *diskData = [self diskImageDataBySearchingAllPathsForKey:key];
            //通过找到的图片数据进行解压缩和缩小的处理 然后返回新的图片
            UIImage *diskImage = [self diskImageForKey:key];
            //假如能在硬盘里找到该文件 在sdwebimage上的默认设置是将图片存在缓存里 所以shouldCacheImagesInMemory为true 所以找到文件就会进入下面的判断
            if (diskImage && self.config.shouldCacheImagesInMemory) {
                //获取图片的大小 并存在内存里
                NSUInteger cost = SDCacheCostForImage(diskImage);
                [self.memCache setObject:diskImage forKey:key cost:cost];
            }

            if (doneBlock) {
                //然后在主线程调用doneBlock 即SDWebImageManager的第二部分
                dispatch_async(dispatch_get_main_queue(), ^{
                    doneBlock(diskImage, diskData, SDImageCacheTypeDisk);
                });
            }
        }
    });

    return operation;
```

注意点：

1. diskImageDataBySearchingAllPathsForKey的内部实现

```objective-c
//通过获取key 将其转换为md5形式并换成以_diskCachePath为的文件路径
NSString *defaultPath = [self defaultCachePathForKey:key];
    //如果有该文件 则返回其数据
    NSData *data = [NSData dataWithContentsOfFile:defaultPath options:self.config.diskCacheReadingOptions error:nil];
    if (data) {
        return data;
    }

    // fallback because of https://github.com/rs/SDWebImage/pull/976 that added the extension to the disk file name
    // checking the key with and without the extension
    //检查有可能是没有后缀名的文件
    data = [NSData dataWithContentsOfFile:defaultPath.stringByDeletingPathExtension options:self.config.diskCacheReadingOptions error:nil];
    if (data) {
        return data;
    }
    
    //self.customPaths是一个含有只读文件路径的数组 该路径可能是有一些已经预加载缓存的图片
    NSArray<NSString *> *customPaths = [self.customPaths copy];
    for (NSString *path in customPaths) {
        //按上面的逻辑继续遍历去找
        NSString *filePath = [self cachePathForKey:key inPath:path];
        NSData *imageData = [NSData dataWithContentsOfFile:filePath options:self.config.diskCacheReadingOptions error:nil];
        if (imageData) {
            return imageData;
        }

        // fallback because of https://github.com/rs/SDWebImage/pull/976 that added the extension to the disk file name
        // checking the key with and without the extension
        imageData = [NSData dataWithContentsOfFile:filePath.stringByDeletingPathExtension options:self.config.diskCacheReadingOptions error:nil];
        if (imageData) {
            return imageData;
        }
    }

    return nil;
```

2. diskImageForKey的内部实现

```objective-c
NSData *data = [self diskImageDataBySearchingAllPathsForKey:key];
	//若在硬盘找到了数据 下面做的就是将图片进行缩小和解压缩
    if (data) {
      	//获取SDWebImageCodersManager单例子 并对获取到的数据进行解码转换成UIImage
        UIImage *image = [[SDWebImageCodersManager sharedInstance] decodedImageWithData:data];
        image = [self scaledImageForKey:key image:image];
        if (self.config.shouldDecompressImages) {
            //进行复杂的图像解压缩处理
            image = [[SDWebImageCodersManager sharedInstance] decompressedImageWithImage:image data:&data options:@{SDWebImageCoderScaleDownLargeImagesKey: @(NO)}];
        }
        return image;
    } else {
        return nil;
    }
```

##### SDWebImageCodersManager 所调用过的方法

```objective-c
- (instancetype)init {
    //SDWebImageCodersManager 是一个通过对图片数据编码和解码的工具 它的mutableCoders是可以针对不同的图片类型进行不同的解码和编码 外部获取coders时 越往后的优先度越高
    if (self = [super init]) {
        // initialize with default coders
        //默认是使用SDWebImageImageIOCoder
        _mutableCoders = [@[[SDWebImageImageIOCoder sharedCoder]] mutableCopy];
#ifdef SD_WEBP
        [_mutableCoders addObject:[SDWebImageWebPCoder sharedCoder]];
#endif
      	//该队列用于在并行队列下添加或删除解码器
        _mutableCodersAccessQueue = dispatch_queue_create("com.hackemist.SDWebImageCodersManager", DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}
```

 ```objective-c
- (UIImage *)decodedImageWithData:(NSData *)data {
    if (!data) {
        return nil;
    }
  	//通过循环每个coder 由coder来判断自身是否能进行解码 若能则进行解码
    for (id<SDWebImageCoder> coder in self.coders) {
        if ([coder canDecodeFromData:data]) {
            return [coder decodedImageWithData:data];
        }
    }
    return nil;
}
 ```

##### SDWebImageImageIOCoder 所调用过的方法

```objective-c
- (UIImage *)decodedImageWithData:(NSData *)data {
    if (!data) {
        return nil;
    }
    
    UIImage *image = [[UIImage alloc] initWithData:data];
    
#if SD_MAC
    return image;
#else
    if (!image) {
        return nil;
    }
    
  	//获取图片的数据类型
    SDImageFormat format = [NSData sd_imageFormatForImageData:data];
    //如果是gif只能返回静态的gif
    if (format == SDImageFormatGIF) {
        // static single GIF need to be created animated for `FLAnimatedImage` logic
        // GIF does not support EXIF image orientation
        image = [UIImage animatedImageWithImages:@[image] duration:image.duration];
        return image;
    }
    //通过data获取图片的旋转角度
    UIImageOrientation orientation = [[self class] sd_imageOrientationFromImageData:data];
    if (orientation != UIImageOrientationUp) {
        image = [UIImage imageWithCGImage:image.CGImage
                                    scale:image.scale
                              orientation:orientation];
    }
    
    return image;
```

普通图片解压缩时都是用这个类的下面的方法

```objective-c
- (UIImage *)decompressedImageWithImage:(UIImage *)image
                                   data:(NSData *__autoreleasing  _Nullable *)data
                                options:(nullable NSDictionary<NSString*, NSObject*>*)optionsDict {
#if SD_MAC
    return image;
#endif
#if SD_UIKIT || SD_WATCH
    BOOL shouldScaleDown = NO;
    if (optionsDict != nil) {
        NSNumber *scaleDownLargeImagesOption = nil;
        if ([optionsDict[SDWebImageCoderScaleDownLargeImagesKey] isKindOfClass:[NSNumber class]]) {
            scaleDownLargeImagesOption = (NSNumber *)optionsDict[SDWebImageCoderScaleDownLargeImagesKey];
        }
        if (scaleDownLargeImagesOption != nil) {
            shouldScaleDown = [scaleDownLargeImagesOption boolValue];
        }
    }
    //是否需要缩小图片
    if (!shouldScaleDown) {
        return [self sd_decompressedImageWithImage:image];
    } else {
        UIImage *scaledDownImage = [self sd_decompressedAndScaledDownImageWithImage:image];
        if (scaledDownImage && !CGSizeEqualToSize(scaledDownImage.size, image.size)) {
            // if the image is scaled down, need to modify the data pointer as well
            SDImageFormat format = [NSData sd_imageFormatForImageData:*data];
          	//对缩小的图片编码 将其转换成二进制
            NSData *imageData = [self encodedDataWithImage:scaledDownImage format:format];
            if (imageData) {
                *data = imageData;
            }
        }
        return scaledDownImage;
    }
#endif
}
```

若不需要缩小图片 则调用下面的方法将矢量图换成位图并解压缩

```objective-c
- (nullable UIImage *)sd_decompressedImageWithImage:(nullable UIImage *)image {
    
  	//假如是有alpha通道的图像则不给decode
  	if (![[self class] shouldDecodeImage:image]) {
        return image;
    }
    
    // autorelease the bitmap context and all vars to help system to free memory when there are memory warning.
    // on iOS7, do not forget to call [[SDImageCache sharedImageCache] clearMemory];
    @autoreleasepool{
        
        CGImageRef imageRef = image.CGImage;
        //获取图像的颜色空间
        CGColorSpaceRef colorspaceRef = [[self class] colorSpaceForImageRef:imageRef];
        //获取图像的宽高
        size_t width = CGImageGetWidth(imageRef);
        size_t height = CGImageGetHeight(imageRef);
        
        // kCGImageAlphaNone is not supported in CGBitmapContextCreate.
        // Since the original image here has no alpha info, use kCGImageAlphaNoneSkipLast
        // to create bitmap graphics contexts without alpha info.
        //这个重新解压缩的图片 是一个没有alpha通道的图 只有rgb颜色通道的
        //data 是指让系统去分配和释放内存空间，避免内存泄漏问题
        //kBitsPerComponent 是指位图像素中每个组件的位数 对于32位像素格式和RGB 颜色空间，这个值是8
        //bitmapInfo 指出该位图是否包含 alpha 通道和它是如何产生的(RGB/RGBA/RGBX…)，还有每个通道应该用整数标识还是浮点数。值为kCGBitmapByteOrderDefault | kCGImageAlphaNoneSkipLast，表示着新的位图图像不使用后面8位的 alpha 通道的。
        CGContextRef context = CGBitmapContextCreate(NULL,
                                                     width,
                                                     height,
                                                     kBitsPerComponent,
                                                     0,
                                                     colorspaceRef,
                                                     kCGBitmapByteOrderDefault|kCGImageAlphaNoneSkipLast);
        if (context == NULL) {
            return image;
        }
        
        // Draw the image into the context and retrieve the new bitmap image without alpha
        //创建新的位图 并且不使用alpha通道
        CGContextDrawImage(context, CGRectMake(0, 0, width, height), imageRef);
        CGImageRef imageRefWithoutAlpha = CGBitmapContextCreateImage(context);
        UIImage *imageWithoutAlpha = [UIImage imageWithCGImage:imageRefWithoutAlpha
                                                         scale:image.scale
                                                   orientation:image.imageOrientation];
        
        CGContextRelease(context);
        CGImageRelease(imageRefWithoutAlpha);
        
        return imageWithoutAlpha;
    }
}
```

注意点：

1. iphone只能显示颜色为最高为8通道 所以kBitsPerComponent固定为8 详细的可以研究这片[文章](http://honglu.me/2016/09/02/一张图片引发的深思/?utm_source=tuicool)

若需要缩小图片 则调用下面的方法

```objective-c
- (nullable UIImage *)sd_decompressedAndScaledDownImageWithImage:(nullable UIImage *)image {

	//假如是有alpha通道的图像则不给decode
    if (![[self class] shouldDecodeImage:image]) {
        return image;
    }
    
    if (![[self class] shouldScaleDownImage:image]) {
        return [self sd_decompressedImageWithImage:image];
    }
    
    CGContextRef destContext;
    
    // autorelease the bitmap context and all vars to help system to free memory when there are memory warning.
    // on iOS7, do not forget to call [[SDImageCache sharedImageCache] clearMemory];
    @autoreleasepool {
        CGImageRef sourceImageRef = image.CGImage;
        
        CGSize sourceResolution = CGSizeZero;
        sourceResolution.width = CGImageGetWidth(sourceImageRef);
        sourceResolution.height = CGImageGetHeight(sourceImageRef);
        float sourceTotalPixels = sourceResolution.width * sourceResolution.height;
        // Determine the scale ratio to apply to the input image
        // that results in an output image of the defined size.
        // see kDestImageSizeMB, and how it relates to destTotalPixels.
        float imageScale = kDestTotalPixels / sourceTotalPixels;
        CGSize destResolution = CGSizeZero;
        destResolution.width = (int)(sourceResolution.width*imageScale);
        destResolution.height = (int)(sourceResolution.height*imageScale);
        
        // current color space
        CGColorSpaceRef colorspaceRef = [[self class] colorSpaceForImageRef:sourceImageRef];
        
        // kCGImageAlphaNone is not supported in CGBitmapContextCreate.
        // Since the original image here has no alpha info, use kCGImageAlphaNoneSkipLast
        // to create bitmap graphics contexts without alpha info.
        destContext = CGBitmapContextCreate(NULL,
                                            destResolution.width,
                                            destResolution.height,
                                            kBitsPerComponent,
                                            0,
                                            colorspaceRef,
                                            kCGBitmapByteOrderDefault|kCGImageAlphaNoneSkipLast);
        
        if (destContext == NULL) {
            return image;
        }
        //设置图像插值的质量为高
        CGContextSetInterpolationQuality(destContext, kCGInterpolationHigh);
        
        // Now define the size of the rectangle to be used for the
        // incremental blits from the input image to the output image.
        // we use a source tile width equal to the width of the source
        // image due to the way that iOS retrieves image data from disk.
        // iOS must decode an image from disk in full width 'bands', even
        // if current graphics context is clipped to a subrect within that
        // band. Therefore we fully utilize all of the pixel data that results
        // from a decoding opertion by achnoring our tile size to the full
        // width of the input image.
        //这里整段话的意思我估计是 由于ios从硬盘取回图像数据时 它必须以全宽度下解码图片 即使现在图像上下文被裁了部分
        CGRect sourceTile = CGRectZero;
        sourceTile.size.width = sourceResolution.width;
        // The source tile height is dynamic. Since we specified the size
        // of the source tile in MB, see how many rows of pixels high it
        // can be given the input image width.
        //通过指定了固定size 在基于已有的width下就能获取到相应的高度了
        sourceTile.size.height = (int)(kTileTotalPixels / sourceTile.size.width );
        sourceTile.origin.x = 0.0f;
        // The output tile is the same proportions as the input tile, but
        // scaled to image scale.
        CGRect destTile;
        destTile.size.width = destResolution.width;
        destTile.size.height = sourceTile.size.height * imageScale;
        destTile.origin.x = 0.0f;
        // The source seem overlap is proportionate to the destination seem overlap.
        // this is the amount of pixels to overlap each tile as we assemble the ouput image.
        // 计算公式： sourceSeemOverlap = (int)kDestSeemOverlap / imageScale
        float sourceSeemOverlap = (int)((kDestSeemOverlap/destResolution.height)*sourceResolution.height);
        CGImageRef sourceTileImageRef;
        // calculate the number of read/write operations required to assemble the
        // output image.
        //计算读／写操作来收集输出图像时所需要的操作数
        int iterations = (int)( sourceResolution.height / sourceTile.size.height );
        // If tile height doesn't divide the image height evenly, add another iteration
        // to account for the remaining pixels.
        int remainder = (int)sourceResolution.height % (int)sourceTile.size.height;
        if(remainder) {
            iterations++;
        }
        // Add seem overlaps to the tiles, but save the original tile height for y coordinate calculations.
        float sourceTileHeightMinusOverlap = sourceTile.size.height;
        sourceTile.size.height += sourceSeemOverlap;
        destTile.size.height += kDestSeemOverlap;
        //应该说 从这里开始 就是不断的调整destContext 让它一直进行插值处理 不断的调整 根据上面获得的循环次数
        for( int y = 0; y < iterations; ++y ) {
            @autoreleasepool {
                sourceTile.origin.y = y * sourceTileHeightMinusOverlap + sourceSeemOverlap;
                destTile.origin.y = destResolution.height - (( y + 1 ) * sourceTileHeightMinusOverlap * imageScale + kDestSeemOverlap);
                sourceTileImageRef = CGImageCreateWithImageInRect( sourceImageRef, sourceTile );
                if( y == iterations - 1 && remainder ) {
                    float dify = destTile.size.height;
                    destTile.size.height = CGImageGetHeight( sourceTileImageRef ) * imageScale;
                    dify -= destTile.size.height;
                    destTile.origin.y += dify;
                }
                CGContextDrawImage( destContext, destTile, sourceTileImageRef );
                CGImageRelease( sourceTileImageRef );
            }
        }
        
        CGImageRef destImageRef = CGBitmapContextCreateImage(destContext);
        CGContextRelease(destContext);
        if (destImageRef == NULL) {
            return image;
        }
        UIImage *destImage = [UIImage imageWithCGImage:destImageRef scale:image.scale orientation:image.imageOrientation];
        CGImageRelease(destImageRef);
        if (destImage == nil) {
            return image;
        }
        return destImage;
    }
```

注意点：

1.这个方法用了比较叼的图片缩小算法 详细的研究可以看这篇[文章](https://www.jianshu.com/p/dfa47380fc05)

对已经进行解压缩并缩小的图片获取其二进制数据

```objective-c
- (NSData *)encodedDataWithImage:(UIImage *)image format:(SDImageFormat)format {
    if (!image) {
        return nil;
    }
    
    if (format == SDImageFormatUndefined) {
        BOOL hasAlpha = SDCGImageRefContainsAlpha(image.CGImage);
        if (hasAlpha) {
            format = SDImageFormatPNG;
        } else {
            format = SDImageFormatJPEG;
        }
    }
    
    NSMutableData *imageData = [NSMutableData data];
    CFStringRef imageUTType = [NSData sd_UTTypeFromSDImageFormat:format];
    
    // Create an image destination.
  	//这里相当于先获取整个数据的容量
    CGImageDestinationRef imageDestination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)imageData, imageUTType, 1, NULL);
    if (!imageDestination) {
        // Handle failure.
        return nil;
    }
    
    NSMutableDictionary *properties = [NSMutableDictionary dictionary];
#if SD_UIKIT || SD_WATCH
    NSInteger exifOrientation = [SDWebImageCoderHelper exifOrientationFromImageOrientation:image.imageOrientation];
    [properties setValue:@(exifOrientation) forKey:(__bridge_transfer NSString *)kCGImagePropertyOrientation];
#endif
    
    // Add your image to the destination.
    //这里相当于再往已定容量的imageData添加数据
    CGImageDestinationAddImage(imageDestination, image.CGImage, (__bridge CFDictionaryRef)properties);
    
  	//判断是否完成
    // Finalize the destination.
    if (CGImageDestinationFinalize(imageDestination) == NO) {
        // Handle failure.
        imageData = nil;
    }
    
    CFRelease(imageDestination);
    
    return [imageData copy];
}
```

##### scaledImageForKey的内部实现

```objective-c
//通过判断key中是否含有@2x. 或者@3x. 若有就放大到2倍 或者 3倍 否则则用原本的scale
return SDScaledImageForKey(key, image);
```

整个第二部分就讲完啦 篇幅很长 但主要就是讲从硬盘获取到的图片 需要先解其压缩 若需要缩小则进行缩小和解压缩的操作 矢量图解压成位图 主要一点就是可以帮助UIImageView更快的去渲染图片 系统默认是等到图片快要展示的时候才去解压缩图片然后去渲染 所以有时候在显示到屏幕时 会看到有一段时间的延迟问题

> Imagine you have a UIScrollView that displays UIImageViews for the individual pages of a catalog or magazine style app. As soon as even one pixel of the following page comes on screen you instantiate (or reuse) a UIImageView and pop it into the scroll view’s content area. That works quite well in Simulator, but when you test this on the device you find that every time you try to page to the next page, there is a noticeable delay. This delay results from the fact that images need to be decompressed from their file incarnation to be rendered on screen. Unfortunately UIImage does this decompression at the very latest possible moment, i.e. when it is to be displayed.
>
> 源自[Avoiding Image Decompression Sickness](https://www.cocoanetics.com/2011/10/avoiding-image-decompression-sickness/)

