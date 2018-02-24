# YYWebImageOperation

线程数：最多17个

1. NSThread 专门用于\_startOperation、\_startRequest、\_cancelOperation、\_didReceiveImageFromDiskCache、\_didReceiveImageFromWeb这几个方法里（优先度：后台）
2. 最多16个的队列数组 专门用于图片的读取和解码 将图片保存缓存或者本地磁盘中（优先度：QOS_CLASS_UTILITY 串行队列 ）

锁：2个

1. NSRecursiveLock 递归锁 用于调用completionBlock 或者ProgressBlock 或者一些标职位设置 或者 将图片设置到缓存里
2. dispatch_semaphore 信号量 用于黑名单URL的查找或者添加

注意点：

1. 跟SDWebImage一样对无法获取的URL会添加到黑名单上
2. 针对NSURLConnection对target 会有循环引用的问题 框架作者使用了NSProxy的子类去处理 并且针对可能随时target会销毁的问题 假如动态方法的解析上target销毁 那么借助runtime的消息转发而吞掉异常
3. 在每调用一个方法 都要先去判断是否被canceled 保证不会因为nsoperation被取消而没有及时的停止
4. 因为重写了start方法 所以需要设置好isfinish和isexcuting等属性 而且针对需要kvo的三个属性 都用[self willChangeValueForKey:@"\*\*\*"];   [self didChangeValueForKey:@"\*\*\*"];去处理
5. YYWebImage可能因为还没更新所以还是用旧的NSURLConnection去调用请求 NSURLConnection是针对一个请求一个实例 而新的NSURLSession更像一个管家 可以针对一个url生成一个NSURLSessionTask实例 不过关于凭证方面的信息和cookies信息就由NSURLSession实例统一处理

其他方法的调用基本上跟SDWebImage有些相似 或者可以直接看方法实现的注释也可以大概明白