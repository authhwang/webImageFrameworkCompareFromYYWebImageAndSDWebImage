# YYImageCoder

线程数：无

锁：2个

1. pthread_mutex_t 一个递归锁 虽然我检查过没有地方需要递归 可是这个递归锁当相同线程递归调用同一个函数时 不会因为递归而导致死锁 这个锁在这个类里作用于图片数据的获取或更新
2. dispatch_semaphore 信号量 用于frames数组的元素的添加和删除

注意点：

1. 在这个类里我不把方法和属性都写出来 而是因为我觉得这个类实在很屌😂 不能用只言片语就能概括 虽然我看的主要部分都是图片的解码部分 而且不是全部都能看懂 可是整个方法的调用顺序是 针对图片获取的获取 是调用updateData方法 针对图片的展示 是调用frameAtIndex:(NSUInteger)index decodeForDisplay:(BOOL)decodeForDisplay 虽然别看调用的方法少 里面的实现是不很不得了的 我都对这两个方法的实现进行注释 有兴趣的可以看看 不过最好还是先看 

   1. [iOS平台图片编解码入门教程](http://dreampiggy.com/2017/10/30/iOS平台图片编解码入门教程（Image:IO篇）/) 

   2. [iOS平台图片编解码入门教程(第三方编解码篇)](http://dreampiggy.com/2017/10/30/iOS平台图片编解码入门教程（第三方编解码篇）/) 

   3. [iOS平台图片编解码入门教程(vImage篇)](http://dreampiggy.com/2017/11/12/iOS平台图片编解码入门教程（vImage篇）/) 

      看完之后再来看这里的实现相对容易懂一些 解码的大致内容其实跟第二篇的相似 

      1.都是将数据转换成CGBitmapContext 

      2.然后获取得到的CGImageRef画到画布上 

      3.从而再生成UIImage

2. 对于动态图的解码 就会有些特别 要判断其Dispose Method 是将前一帧的内容全部清空 还是说改变某个部分的

3. 渐进式解码 对于普通图片类型(不是webp png) 是用CGImageSourceCreateIncremental 然后用CGImageSourceUpdateData更新数据 然后再对这个_source进行解码显示 就能做到渐进式显示啦～

4. 每一个YYImage实例里面都有一个YYImageDecoder实例 这个对于之后做动图的处理方面简化很多

