# YYMemoryCache

 队列数：3个

1. 用于释放_YYLinkedMapNode实例时使用的(优先度:low 并发队列)
2. 用于在间隔5秒的类似定时器的操作(优先度:low 并发队列)
3. 用于在age、count、cost三个维度下进行节点检查和清理的操作（优先度:默认,串行队列）

线程锁：1个

1. pthread_mutex_t 针对节点链表的增删改

先看下它所需要的类

## _YYLinkedMapNode

链表节点

```objective-c
@interface _YYLinkedMapNode : NSObject {
    //@package 无法让外部直接访问以下变量
    @package
    __unsafe_unretained _YYLinkedMapNode *_prev; // retained by dic
    __unsafe_unretained _YYLinkedMapNode *_next; // retained by dic
    id _key;
    id _value;
    NSUInteger _cost;
    NSTimeInterval _time;
}
```

注意点:

1. __unsafe_unretained 的作用跟weak一样 只不过它不能当对象销毁时自动置为nil
2. @package 的作用是 只保证该文件可以调用 对于别的文件来说是私有的
3. _time 是保存取节点的时间 时间越新 证明越常使用

## _YYLinkedMap

双向链表的实现

```objective-c
@interface _YYLinkedMap : NSObject {
    @package
    CFMutableDictionaryRef _dic; // do not set object directly
    NSUInteger _totalCost;
    NSUInteger _totalCount;
    _YYLinkedMapNode *_head; // MRU, do not change it directly
    _YYLinkedMapNode *_tail; // LRU, do not change it directly
    BOOL _releaseOnMainThread;
    BOOL _releaseAsynchronously;
}

- (instancetype)init;
- (void)insertNodeAtHead:(_YYLinkedMapNode *)node;
- (void)bringNodeToHead:(_YYLinkedMapNode *)node;
- (void)removeNode:(_YYLinkedMapNode *)node;
- (_YYLinkedMapNode *)removeTailNode;
- (void)removeAll;
```

注意点：

1. _dic的作用是 保存在链表上的每一个节点 查找可以更加快

2. _totalCost 的作用是保存所有节点的cost总和 那进行节点检查和删除可以更加方便 不需要每次都遍历所有节点

3. _totalCount 保存所有节点的个数总和 跟\_totalCost同一个作用

4. \_head和\_tail分别是整个双向链表的头尾部

5. 因为是根据LRU的缓存淘汰算法 这个算法的中心在于将经常使用的高频节点放在最前面 那么在尾部的就是相对不常用的低频节点 那么当进行缓存清理的时候 先从尾部的开始清除 所以对于获取新的节点后都是因为这个原因而

6. 用双向链表而不用的数组的原因 我在别的博客上看到

   > 数组中元素在内存的排列是连续的，对于寻址操作非常便利；但是对于插入，删除操作很不方便，需要整体移动，移动的元素个数越多，代价越大。而链表恰恰相反，因为其节点的关联仅仅是靠指针，所以对于插入和删除操作会很便利，而寻址操作缺比较费时。由于在LRU策略中会有非常多的移动，插入和删除节点的操作，所以使用双向链表是比较有优势的。

  该类方法实现的注释我都写完 放在SourceCode文件夹里

## YYMemoryCache

```objective-c
@implementation YYMemoryCache {
    pthread_mutex_t _lock;
    _YYLinkedMap *_lru;
    dispatch_queue_t _queue;
}
//私有方法
- (void)_trimRecursively;
- (void)_trimInBackground;
- (void)_trimToCost:(NSUInteger)costLimit;
- (void)_trimToCount:(NSUInteger)countLimit;
- (void)_trimToAge:(NSTimeInterval)ageLimit;
- (void)_appDidReceiveMemoryWarningNotification;
- (void)_appDidReceiveMemoryWarningNotification;
- (void)_appDidEnterBackgroundNotification;
//
- (instancetype)init;
- (void)dealloc;

- (NSUInteger)totalCount;
- (NSUInteger)totalCost;
- (BOOL)releaseOnMainThread;
- (void)setReleaseOnMainThread:(BOOL)releaseOnMainThread;
- (BOOL)releaseAsynchronously;
- (void)setReleaseAsynchronously:(BOOL)releaseAsynchronously;

- (BOOL)containsObjectForKey:(id)key;
- (id)objectForKey:(id)key;

- (void)setObject:(id)object forKey:(id)key;
- (void)setObject:(id)object forKey:(id)key withCost:(NSUInteger)cost;

- (void)removeObjectForKey:(id)key;
- (void)removeAllObjects;

- (void)trimToCount:(NSUInteger)count;
- (void)trimToCost:(NSUInteger)cost;
- (void)trimToAge:(NSTimeInterval)age;

- (NSString *)description;
```

注意点：

1. 每5秒钟会从串行队列名为com.ibireme.cache.memory上进行count age cost 三个维度下对链表上的节点进行检查
2. 当有节点需要释放时 会在一个专门用于的释放的优先度低队列释放这些节点 降低工作线程的操作
3. 跟SDWebImage对缓存的处理 当出现内存警告和app进入后台的时候 就会自动删除链表内的所有节点
4. 互斥锁需要作用于 链表对节点的增加 删除 查询 以及对_totalCost _totalCount等操作 而且这个互斥锁是使用pthread_mutex_t 既性能高也可以保证线程安全 

![lock_benchmark](../Pics/lock_benchmark.png)

该类的方法实现的代码注释我都写完 放在SourceCode文件夹里
