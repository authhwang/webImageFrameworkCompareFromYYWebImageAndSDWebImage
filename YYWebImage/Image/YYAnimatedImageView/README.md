# YYAnimatedImageView

线程数：1个

1. NSOperationQueue 用于图片解码处理（优先度：默认 串行队列）

锁：1个

1. dispatch_semaphore 针对_buffer数组的元素增加或删除

注意点：

1. imageChange方法实现

```objective-c
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
```

修改原本layer的contentRect 获取当前image 获取frame 总共循环次数 总共帧数 还有计算最大的buffer个数 这个buffer个数是会将已进行解码的图片保存在imageview里 不过会根据当前设备的内存而做相应的限制

2. step方法的实现

```objective-c
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

```

这个方法就是CADisplayLink所调用的方法 

上半部分是要判断每一帧所需要的展示时间 若再下次调用的间隔没超过该帧的展示时间 则直接return 若超过 则开始下一帧的处理

下半部分是要判断是否有下一帧的缓存图片 可是之前cpu暴涨的问题就是出现之后的条件判断 由于增加的buffer个数肯定永远都比总帧数少 导致会一直将在缓存数组里下一帧的图片删除 从而导致缓存个数永远都不能等于总帧数 因而使cpu都要去重新绘制下一帧的图片 

接下来就是通过当前帧的contentrect修改layer的contentract 以及进行判断是否需要创建operation去解码下一帧图片

3. main方法的实现

```objective-c
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
```

这里就的循环就是去做图片的解码处理 不过这里是有个细节 就是由于每次的nextindex不同 其实在每次重新进入这个循环时 等于给未来的帧都给做好解码 就不用执行太多次的循环 我想这个应该是框架作者的小心思吧