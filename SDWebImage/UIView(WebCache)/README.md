# UIView + WebCache

这个分类基本上服务于UIImage UIButton 不过它也是整个流程的入口 如下面的例子：

```objective-c
[imageView sd_setImageWithURL: ****];
```

 它的最终还是要调用这个方法: 

```objective-c
- (void)sd_internalSetImageWithURL:(nullable NSURL *)url
                  placeholderImage:(nullable UIImage *)placeholder
                  options:(SDWebImageOptions)options
                  operationKey:(nullable NSString *)operationKey
                  setImageBlock:(nullable SDSetImageBlock)setImageBlock
                  progress:(nullable SDWebImageDownloaderProgressBlock)progressBlock
                  completed:(nullable SDExternalCompletionBlock)completedBlock
                  context:(nullable NSDictionary *)context;

```

所以我们从这个方法开始看起

我把这个方法内部分成两个部分 一个部分是**获得图片前** 另一部分是**获得图片后**

第一部分

```objective-c
NSString *validOperationKey = operationKey ?: NSStringFromClass([self class]);
    [self sd_cancelImageLoadOperationWithKey:validOperationKey];//cancel晒所有该实例的SDWebImageCombinedOperation实例operation

	//对其url通过associatedObject以key为imageURLKey进行绑定
    objc_setAssociatedObject(self, &imageURLKey, url, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    //options没含有SDWebImageDelayPlaceholder 即表明先设置placeholder图片 就会进入下面的判断
    if (!(options & SDWebImageDelayPlaceholder)) {
        //如果有设置group下载的话 就会在context的键为SDWebImageInternalSetImageGroupKey下设置
        if ([context valueForKey:SDWebImageInternalSetImageGroupKey]) {
            dispatch_group_t group = [context valueForKey:SDWebImageInternalSetImageGroupKey];
            dispatch_group_enter(group);
        }
        //判断当前队列是否主线程 如果是 则直接调用block 否则 则在主线程下调用
        //这里是在主线程下 给该view设置placeholder图片 假如有设置setimageblock 则会直接调用 如果不是 会判断是uibutton还是uiimageview
        dispatch_main_async_safe(^{
            [self sd_setImage:placeholder imageData:nil basedOnClassOrViaCustomSetImageBlock:setImageBlock];
        });
    }
    
    //判断是否有url 如果无则会将转菊花清除 然后如果有competedblock 则会调用该block 并传一个error给它 说明是一个空url
    //如果有url 则走下面的流程
    
    if (url) {
        // check if activityView is enabled or not
        //检查是否在用菊花转转转 如果无 则会添加一个菊花
        if ([self sd_showActivityIndicatorView]) {
            [self sd_addActivityIndicator];
        }
        
        //创建一个类为SDWebImageManager 的实例 功能迟候分析
        SDWebImageManager *manager;
        //支持自定义manager
        if ([context valueForKey:SDWebImageExternalCustomManagerKey]) {
            manager = (SDWebImageManager *)[context valueForKey:SDWebImageExternalCustomManagerKey];
        } else {
            manager = [SDWebImageManager sharedManager];
        }
      	
      	//通过manager将url options progressBlock 等传进去 并在里面通过缓存查找 硬盘查找 url请求有先后顺序的去获取图片
     	id <SDWebImageOperation> operation = [manager loadImageWithURL:url options:options progress:progressBlock completed:^(UIImage *image, NSData *data, NSError *error, SDImageCacheType cacheType, BOOL finished, NSURL *imageURL) {
		//这里迟些分析 属于第二部分
        }];
      	
        //这里对SDWebImageCombinedOperation(源于SDWebImageManager)弱引用 该数组在UIView(WebCacheOperation)中创建并用assoicatedObject与其绑定 可以查看该分类的源码
        [self sd_setImageLoadOperation:operation forKey:validOperationKey];
    } else {
        //当不存在url的时候 则通过主线程调用completedBlock 返回一个error回去
        dispatch_main_async_safe(^{
            [self sd_removeActivityIndicator];
            if (completedBlock) {
                NSError *error = [NSError errorWithDomain:SDWebImageErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey : @"Trying to load a nil url"}];
                completedBlock(nil, error, SDImageCacheTypeNone, url);
            }
        });
    }
```

注意点:

1. dispatch_main_async_safe 是通过宏定义 它里面会判断当前队列是否在主线程中 若是 则直接调用block 若不是 则通过gcd在主线程下调用该block


2.  针对SDWebImageInternalSetImageGroupKey的实现操作我还没研究 有研究就会补上了
3.  UIView + WebCacheOperation 这个分类的方法是用于帮助控件图片加载的取消 该分类里的储存的operation都是弱引用 所以它会自动销毁当图片加载完后 如果你需要强引用这些operation 用自定义一个类去强引用他们

第二部分：

```objective-c
completed:^(UIImage *image, NSData *data, NSError *error, SDImageCacheType cacheType, BOOL finished, NSURL *imageURL) {
            //回到这里基本上从三个途径之一找到了图片 或者 没有任何图片
            __strong __typeof (wself) sself = wself;
            [sself sd_removeActivityIndicator];
            //假如该控件已经被销毁 则直接ruturn
            if (!sself) { return; }
            //是否自动调用completeBlock
            BOOL shouldCallCompletedBlock = finished || (options & SDWebImageAvoidAutoSetImage);
            //是否有图片而且options含有SDWebImageAvoidAutoSetImage 或者 是否没有图片而且option里不含有SDWebImageDelayPlaceholder的时候
            //含有SDWebImageAvoidAutoSetImage 代表避免自动调用completeBlock
            //含有SDWebImageDelayPlaceholder 代表等待寻找到图片后再进行加载placeHolder图像 默认是在寻找图片前已经加载了placeHolder
            BOOL shouldNotSetImage = ((image && (options & SDWebImageAvoidAutoSetImage)) ||
                                      (!image && !(options & SDWebImageDelayPlaceholder)));
  			//这个block做的是 若需要给控件加载图片 则先调用setNeedlayout会讲view当前的layout设置为无效 并在下一个update cycle里去触发layout更新 
            SDWebImageNoParamsBlock callCompletedBlockClojure = ^{
                if (!sself) { return; }
                if (!shouldNotSetImage) {
                    [sself sd_setNeedsLayout];
                }
                if (completedBlock && shouldCallCompletedBlock) {
                    completedBlock(image, error, cacheType, url);
                }
            };
            
            // case 1a: we got an image, but the SDWebImageAvoidAutoSetImage flag is set
            // OR
            // case 1b: we got no image and the SDWebImageDelayPlaceholder is not set
            if (shouldNotSetImage) {
                dispatch_main_async_safe(callCompletedBlockClojure);
                return;
            }
            
            //往下就是自动将图片加载
            
            UIImage *targetImage = nil;
            NSData *targetData = nil;
            if (image) {
                // case 2a: we got an image and the SDWebImageAvoidAutoSetImage is not set
                targetImage = image;
                targetData = data;
            } else if (options & SDWebImageDelayPlaceholder) {
                // case 2b: we got no image and the SDWebImageDelayPlaceholder flag is set
                targetImage = placeholder;
                targetData = nil;
            }
            
            
            //context若有设置图片组SDWebImageInternalSetImageGroupKey
            //我感觉这个group好像是在主线程调用
            //是针对FLAnimatedImageView所使用
            if ([context valueForKey:SDWebImageInternalSetImageGroupKey]) {
                dispatch_group_t group = [context valueForKey:SDWebImageInternalSetImageGroupKey];
                dispatch_group_enter(group);
                dispatch_main_async_safe(^{
                    [sself sd_setImage:targetImage imageData:targetData basedOnClassOrViaCustomSetImageBlock:setImageBlock];
                });
                // ensure completion block is called after custom setImage process finish
                dispatch_group_notify(group, dispatch_get_main_queue(), ^{
                    callCompletedBlockClojure();
                });
            } else {
                dispatch_main_async_safe(^{
                    [sself sd_setImage:targetImage imageData:targetData basedOnClassOrViaCustomSetImageBlock:setImageBlock];
                    callCompletedBlockClojure();
                });
            }
        }];
```

这两个部分相当于整个流程的开头和结尾 我们接下来去看SDWebImageManager
