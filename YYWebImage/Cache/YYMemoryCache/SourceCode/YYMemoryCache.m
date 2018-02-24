//
//  YYMemoryCache.m
//  YYCache <https://github.com/ibireme/YYCache>
//
//  Created by ibireme on 15/2/7.
//  Copyright (c) 2015 ibireme.
//
//  This source code is licensed under the MIT-style license found in the
//  LICENSE file in the root directory of this source tree.
//

#import "YYMemoryCache.h"
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <pthread.h>


static inline dispatch_queue_t YYMemoryCacheGetReleaseQueue() {
    return dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0);
}

/**
 A node in linked map.
 Typically, you should not use this class directly.
 */
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
@end

@implementation _YYLinkedMapNode
@end


/**
 A linked map used by YYMemoryCache.
 It's not thread-safe and does not validate the parameters.
 
 Typically, you should not use this class directly.
 */
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

/// Insert a node at head and update the total cost.
/// Node and node.key should not be nil.
- (void)insertNodeAtHead:(_YYLinkedMapNode *)node;

/// Bring a inner node to header.
/// Node should already inside the dic.
- (void)bringNodeToHead:(_YYLinkedMapNode *)node;

/// Remove a inner node and update the total cost.
/// Node should already inside the dic.
- (void)removeNode:(_YYLinkedMapNode *)node;

/// Remove tail node if exist.
- (_YYLinkedMapNode *)removeTailNode;

/// Remove all node in background queue.
- (void)removeAll;

@end

@implementation _YYLinkedMap

- (instancetype)init {
    self = [super init];
    //创建以CFMutableDictionary
    //CFAllocatorGetDefault() 内存分配器 默认是null 现在用CFAllocatorGetDefault()也行
    //CFIndex 0 字典的初始大小，跟我们Foundation 字典的创建一样，并不限制最大容量 就是预先分配内存
    //CFDictionaryKeyCallBacks  里面是一个结构体 主要内容可以看effective object的49节 可以针对键和值的填写而做出跟NSMutableDictionary不一样的功能 现在只是用回默认的功能
    _dic = CFDictionaryCreateMutable(CFAllocatorGetDefault(), 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    //在主线程下释放的标志符
    _releaseOnMainThread = NO;
    //异步释放的标志符
    _releaseAsynchronously = YES;
    return self;
}

- (void)dealloc {
    CFRelease(_dic);
}

- (void)insertNodeAtHead:(_YYLinkedMapNode *)node {
    //在_dic通过key设置节点 强引用节点
    CFDictionarySetValue(_dic, (__bridge const void *)(node->_key), (__bridge const void *)(node));
    //增加总消耗
    _totalCost += node->_cost;
    //总个数加一
    _totalCount++;
    //如果如果有头部 则修改头部为最新的节点
    if (_head) {
        node->_next = _head;
        _head->_prev = node;
        _head = node;
    } else {
        //若没有 则代表是全新的链表 增加头部和尾部
        _head = _tail = node;
    }
}

- (void)bringNodeToHead:(_YYLinkedMapNode *)node {
    if (_head == node) return;
    
    //如果node是尾部
    if (_tail == node) {
        //node的前一个为尾部
        _tail = node->_prev;
        //把新尾部的后一个置为nil
        _tail->_next = nil;
    } else {
        //node的后一个点的前一个 等于 node的前一个点
        node->_next->_prev = node->_prev;
        //node的前一个点的后一个 等于 node的后一个点
        node->_prev->_next = node->_next;
    }
    //node后一个 等于 原来的_head
    node->_next = _head;
    //node的前一个 置为 nil
    node->_prev = nil;
    //_head的前一个 改为 node
    _head->_prev = node;
    //_head 等于 node
    _head = node;
}

- (void)removeNode:(_YYLinkedMapNode *)node {
    //删除_dic下该key所对应的值 去除引用
    CFDictionaryRemoveValue(_dic, (__bridge const void *)(node->_key));
    //总消耗值减去被删除节点的消耗
    _totalCost -= node->_cost;
    //个数减一
    _totalCount--;
    //如果有节点的下一个 则将下一个的上一个 连着 节点的上一个
    if (node->_next) node->_next->_prev = node->_prev;
    //如果有节点的上一个 则将上一个的下一个 连着 节点的下一个
    if (node->_prev) node->_prev->_next = node->_next;
    //如果该节点是链表的头部 则头部交给节点的下一个
    if (_head == node) _head = node->_next;
    //如果该节点是链表的尾部 则头部交给节点的上一个
    if (_tail == node) _tail = node->_prev;
}

- (_YYLinkedMapNode *)removeTailNode {
    //如果尾部为空 则返回nil
    if (!_tail) return nil;
    //创建一个局部变量tail强引用_tail
    _YYLinkedMapNode *tail = _tail;
    //remove在dic对_tail的引用
    CFDictionaryRemoveValue(_dic, (__bridge const void *)(_tail->_key));
    //总花费值减去_tail的cost
    _totalCost -= _tail->_cost;
    //个数减一
    _totalCount--;
    //如果头部等于为尾部
    if (_head == _tail) {
        //头尾都置为空 解除_head和_tail对其的强引用
        _head = _tail = nil;
    } else {
        //如果不等于 则将_tail的前一个赋值给_tail
        //当前_tail的下一个置为空
        _tail = _tail->_prev;
        _tail->_next = nil;
    }
    return tail;
}

- (void)removeAll {
    //把_totalCost 和 _totalCount都置0
    _totalCost = 0;
    _totalCount = 0;
    //把_head 和 _tail置为nil
    _head = nil;
    _tail = nil;
    if (CFDictionaryGetCount(_dic) > 0) {
        CFMutableDictionaryRef holder = _dic;
        _dic = CFDictionaryCreateMutable(CFAllocatorGetDefault(), 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        //如果是在需要异步释放 则会开用异步的方式释放
        if (_releaseAsynchronously) {
            //判断是否需要在主线程释放 若不是 则通过YYMemoryCacheGetReleaseQueue()函数 创建一条低优先度的线程
            dispatch_queue_t queue = _releaseOnMainThread ? dispatch_get_main_queue() : YYMemoryCacheGetReleaseQueue();
            dispatch_async(queue, ^{
                CFRelease(holder); // hold and release in specified queue
            });
            //如果不是需要异步释放 但需要在主线程释放 而且 当前线程不是主线程
        } else if (_releaseOnMainThread && !pthread_main_np()) {
            //那就在主线程释放 （这里有点啰嗦）
            dispatch_async(dispatch_get_main_queue(), ^{
                CFRelease(holder); // hold and release in specified queue
            });
            //都不是 则直接释放
        } else {
            CFRelease(holder);
        }
    }
}

@end



@implementation YYMemoryCache {
    pthread_mutex_t _lock;
    _YYLinkedMap *_lru;
    dispatch_queue_t _queue;
}

- (void)_trimRecursively {
    //递归式去检查缓存是否超过限制值 像一个nstimer 在一个低优先度的队列里执行
    __weak typeof(self) _self = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_autoTrimInterval * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        __strong typeof(_self) self = _self;
        if (!self) return;
        
        //在_queue下异步检查_lru链表的消耗值 个数值 节点时间值 若有超过限制值的 则进行从尾部开始删减的处理 直到符合限制值
        [self _trimInBackground];
        //递归调用_trimRecursively方法
        [self _trimRecursively];
    });
}

- (void)_trimInBackground {
    //在_queue下执行检查操作
    dispatch_async(_queue, ^{
        
        //整理消耗值 若超过限制值 则进行从尾部开始删减的处理 直到符合限制值
        [self _trimToCost:self->_costLimit];
        //整理个数值 若超过限制值 则进行从尾部开始删减的处理 直到符合限制值
        [self _trimToCount:self->_countLimit];
        //整理节点时间值 若过期 则进行从尾部开始删减的处理 直到符合限制值
        [self _trimToAge:self->_ageLimit];
    });
}

- (void)_trimToCost:(NSUInteger)costLimit {
    BOOL finish = NO;
    //因为要操作_lru 所以又在互斥锁里进行
    pthread_mutex_lock(&_lock);
    //如果限制值为0 则清除所有节点
    if (costLimit == 0) {
        [_lru removeAll];
        finish = YES;
    //如果_lru总消耗值还没超过限制值 进入下面的判断
    } else if (_lru->_totalCost <= costLimit) {
        finish = YES;
    }
    //解锁
    pthread_mutex_unlock(&_lock);
    //如果为yes 则return
    if (finish) return;
    //进入下面的情况： _lru总消耗值超过了限制值 但限制值不为0
    
    NSMutableArray *holder = [NSMutableArray new];
    while (!finish) {
        //尝试性上锁 如果能上锁 就返回0 因为要对_lru做处理 所以要加锁
        if (pthread_mutex_trylock(&_lock) == 0) {
            //如果_lru总消耗值大于限制值时
            if (_lru->_totalCost > costLimit) {
                //取出_lru的尾部 并remove_lru对其的引用
                _YYLinkedMapNode *node = [_lru removeTailNode];
                //如果有node 则添加到holder上
                if (node) [holder addObject:node];
            } else {
                //如果如果_lru总消耗值小于或等于限制值时
                finish = YES;
            }
            pthread_mutex_unlock(&_lock);
        } else {
            //已经被其他线程调用 所以上了锁 其他调用该函数的线程挂起 10ms后再检查是否解锁 以微妙为单位
            usleep(10 * 1000); //10 ms
        }
    }
    
    //假如holder里有元素
    if (holder.count) {
        //判断是否需要在主线程release
        dispatch_queue_t queue = _lru->_releaseOnMainThread ? dispatch_get_main_queue() : YYMemoryCacheGetReleaseQueue();
        //它这个做法 就是因为block会把holder这个对象强引用 当block的调用结束后 会将holder从该队列下销毁 里面的node也是如此
        dispatch_async(queue, ^{
            [holder count]; // release in queue
        });
    }
}

- (void)_trimToCount:(NSUInteger)countLimit {
    BOOL finish = NO;
    //因为要操作_lru 所以又在互斥锁里进行
    pthread_mutex_lock(&_lock);
    //假如个数限制值为0 则清除所有节点
    if (countLimit == 0) {
        [_lru removeAll];
        finish = YES;
        //假如_lur的总个数少于或等于个数限制值 进入下面的判断
    } else if (_lru->_totalCount <= countLimit) {
        finish = YES;
    }
    //解锁
    pthread_mutex_unlock(&_lock);
    if (finish) return;
    //进入下面的情况： _lru总个数值超过了限制值 但限制值不为0
    
    NSMutableArray *holder = [NSMutableArray new];
    while (!finish) {
        //尝试性上锁 如果能上锁 就返回0 因为要对_lru做处理 所以要加锁
        if (pthread_mutex_trylock(&_lock) == 0) {
            //如果_lru总个数值大于限制值时
            if (_lru->_totalCount > countLimit) {
                //取出_lru的尾部 并remove_lru对其的引用
                _YYLinkedMapNode *node = [_lru removeTailNode];
                //如果有node 则添加到holder上
                if (node) [holder addObject:node];
            } else {
                //如果如果_lru总个数值小于或等于限制值时
                finish = YES;
            }
            //解锁
            pthread_mutex_unlock(&_lock);
        } else {
            //已经被其他线程调用 所以上了锁 其他调用该函数的线程挂起 10ms后再检查是否解锁 以微妙为单位
            usleep(10 * 1000); //10 ms
        }
    }
    
    //假如holder里有元素
    if (holder.count) {
        //判断是否需要在主线程release
        dispatch_queue_t queue = _lru->_releaseOnMainThread ? dispatch_get_main_queue() : YYMemoryCacheGetReleaseQueue();
        //它这个做法 就是因为block会把holder这个对象强引用 当block的调用结束后 会将holder从该队列下销毁 里面的node也是如此
        dispatch_async(queue, ^{
            [holder count]; // release in queue
        });
    }
}

- (void)_trimToAge:(NSTimeInterval)ageLimit {
    BOOL finish = NO;
    //获取现在的时间 这个时间是根据网络时间获取的
    NSTimeInterval now = CACurrentMediaTime();
    //因为要操作_lru 所以又在互斥锁里进行
    pthread_mutex_lock(&_lock);
    //如果时间限制值少于或等于0 则清除所有节点
    if (ageLimit <= 0) {
        [_lru removeAll];
        finish = YES;
        //如果没有尾部（即_lur个数为0）或者 现在的时间减去_lru尾部的时间小于或等于时间限制值 进入下面的判断
    } else if (!_lru->_tail || (now - _lru->_tail->_time) <= ageLimit) {
        finish = YES;
    }
    //解锁
    pthread_mutex_unlock(&_lock);
    if (finish) return;
    //如果现在的时间减去_lru尾部的时间大于时间限制值 而且 时间限制值大于0 则进入下面的操作
    
    NSMutableArray *holder = [NSMutableArray new];
    while (!finish) {
        //尝试性上锁 如果能上锁 就返回0 因为要对_lru做处理 所以要加锁
        if (pthread_mutex_trylock(&_lock) == 0) {
            //如果_lru尾部有值 而且 现在的时间减去_lru尾部的时间大于时间限制值
            if (_lru->_tail && (now - _lru->_tail->_time) > ageLimit) {
                //取出_lru的尾部 并remove_lru对其的引用
                _YYLinkedMapNode *node = [_lru removeTailNode];
                //如果有node 则添加到holder上
                if (node) [holder addObject:node];
            } else {
                //如果现在的时间减去_lru尾部的时间小于或等于时间限制值 则进入下面的判断
                finish = YES;
            }
            //解锁
            pthread_mutex_unlock(&_lock);
        } else {
            //已经被其他线程调用 所以上了锁 其他调用该函数的线程挂起 10ms后再检查是否解锁 以微妙为单位
            usleep(10 * 1000); //10 ms
        }
    }
    
    //假如holder里有元素
    if (holder.count) {
        //判断是否需要在主线程release
        dispatch_queue_t queue = _lru->_releaseOnMainThread ? dispatch_get_main_queue() : YYMemoryCacheGetReleaseQueue();
        //它这个做法 就是因为block会把holder这个对象强引用 当block的调用结束后 会将holder从该队列下销毁 里面的node也是如此
        dispatch_async(queue, ^{
            [holder count]; // release in queue
        });
    }
}

- (void)_appDidReceiveMemoryWarningNotification {
    if (self.didReceiveMemoryWarningBlock) {
        self.didReceiveMemoryWarningBlock(self);
    }
    if (self.shouldRemoveAllObjectsOnMemoryWarning) {
        [self removeAllObjects];
    }
}

- (void)_appDidEnterBackgroundNotification {
    if (self.didEnterBackgroundBlock) {
        self.didEnterBackgroundBlock(self);
    }
    if (self.shouldRemoveAllObjectsWhenEnteringBackground) {
        [self removeAllObjects];
    }
}

#pragma mark - public

- (instancetype)init {
    self = super.init;
    //创建互斥锁_lock
    pthread_mutex_init(&_lock, NULL);
    //创建_YYLinkedMapl类的实例
    _lru = [_YYLinkedMap new];
    //创建一条串行队列
    _queue = dispatch_queue_create("com.ibireme.cache.memory", DISPATCH_QUEUE_SERIAL);
    
    //还不知道要干啥用的
    _countLimit = NSUIntegerMax;
    _costLimit = NSUIntegerMax;
    _ageLimit = DBL_MAX;
    //yymemorycache含有一个定时器 每隔_autoTrimInterval（秒）的时间 会自动检查内存是否到达了限定值 若是 则会驱逐对象
    _autoTrimInterval = 5.0;
    //应该在内存警告下删除所有对象
    _shouldRemoveAllObjectsOnMemoryWarning = YES;
    //应该在进入后台时删除所有对象
    _shouldRemoveAllObjectsWhenEnteringBackground = YES;
    
    //监听UIApplicationDidReceiveMemoryWarningNotification 和 UIApplicationDidEnterBackgroundNotification通知
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_appDidReceiveMemoryWarningNotification) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_appDidEnterBackgroundNotification) name:UIApplicationDidEnterBackgroundNotification object:nil];
    
    //创建一个定时器 每隔5秒 在_queue下异步检查_lru链表的消耗值 个数值 节点时间值
    [self _trimRecursively];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidEnterBackgroundNotification object:nil];
    [_lru removeAll];
    pthread_mutex_destroy(&_lock);
}

- (NSUInteger)totalCount {
    pthread_mutex_lock(&_lock);
    NSUInteger count = _lru->_totalCount;
    pthread_mutex_unlock(&_lock);
    return count;
}

- (NSUInteger)totalCost {
    pthread_mutex_lock(&_lock);
    NSUInteger totalCost = _lru->_totalCost;
    pthread_mutex_unlock(&_lock);
    return totalCost;
}

- (BOOL)releaseOnMainThread {
    pthread_mutex_lock(&_lock);
    BOOL releaseOnMainThread = _lru->_releaseOnMainThread;
    pthread_mutex_unlock(&_lock);
    return releaseOnMainThread;
}

- (void)setReleaseOnMainThread:(BOOL)releaseOnMainThread {
    pthread_mutex_lock(&_lock);
    _lru->_releaseOnMainThread = releaseOnMainThread;
    pthread_mutex_unlock(&_lock);
}

- (BOOL)releaseAsynchronously {
    pthread_mutex_lock(&_lock);
    BOOL releaseAsynchronously = _lru->_releaseAsynchronously;
    pthread_mutex_unlock(&_lock);
    return releaseAsynchronously;
}

- (void)setReleaseAsynchronously:(BOOL)releaseAsynchronously {
    pthread_mutex_lock(&_lock);
    _lru->_releaseAsynchronously = releaseAsynchronously;
    pthread_mutex_unlock(&_lock);
}

- (BOOL)containsObjectForKey:(id)key {
    if (!key) return NO;
    pthread_mutex_lock(&_lock);
    BOOL contains = CFDictionaryContainsKey(_lru->_dic, (__bridge const void *)(key));
    pthread_mutex_unlock(&_lock);
    return contains;
}

- (id)objectForKey:(id)key {
    if (!key) return nil;
    //使用互斥锁 只给一个线程去寻找图片 其他调用都要阻塞
    pthread_mutex_lock(&_lock);
    _YYLinkedMapNode *node = CFDictionaryGetValue(_lru->_dic, (__bridge const void *)(key));
    //若通过这个键 能找到node 则进入下面的判断
    if (node) {
        node->_time = CACurrentMediaTime();
        //将node置为_lru最前
        [_lru bringNodeToHead:node];
    }
    //解锁
    pthread_mutex_unlock(&_lock);
    return node ? node->_value : nil;
}

- (void)setObject:(id)object forKey:(id)key {
    [self setObject:object forKey:key withCost:0];
}

- (void)setObject:(id)object forKey:(id)key withCost:(NSUInteger)cost {
    //如果key是非法 直接返回
    if (!key) return;
    //如果object是非法 则将该key上所对应的值删除
    if (!object) {
        [self removeObjectForKey:key];
        return;
    }
    //当key 和 value都正确的时候 走下面的逻辑
    
    pthread_mutex_lock(&_lock);
    //获取该节点
    _YYLinkedMapNode *node = CFDictionaryGetValue(_lru->_dic, (__bridge const void *)(key));
    NSTimeInterval now = CACurrentMediaTime();
    //若该节点存在
    if (node) {
        //先减去该节点消耗
        _lru->_totalCost -= node->_cost;
        //加新的图片消耗
        _lru->_totalCost += cost;
        //对该节点的cost重新赋值
        node->_cost = cost;
        //节点的修改时间改为现在
        node->_time = now;
        //对该节点的value重新赋值
        node->_value = object;
        //因为修改过 就把它拉到最前面来
        [_lru bringNodeToHead:node];
    } else {
        //重新创建一个_YYLinkedMapNode类的实例
        node = [_YYLinkedMapNode new];
        node->_cost = cost;
        node->_time = now;
        node->_key = key;
        node->_value = object;
        //向链表插入节点在头部
        [_lru insertNodeAtHead:node];
    }
    //如果总消耗大于限制的消耗量 则 在队列里异步进行整理
    if (_lru->_totalCost > _costLimit) {
        dispatch_async(_queue, ^{
            [self trimToCost:_costLimit];
        });
    }
    //如果总个数大于限制个数时 则在指定的队列下异步进行销毁一个尾部节点
    if (_lru->_totalCount > _countLimit) {
        _YYLinkedMapNode *node = [_lru removeTailNode];
        if (_lru->_releaseAsynchronously) {
            dispatch_queue_t queue = _lru->_releaseOnMainThread ? dispatch_get_main_queue() : YYMemoryCacheGetReleaseQueue();
            dispatch_async(queue, ^{
                [node class]; //hold and release in queue
            });
        } else if (_lru->_releaseOnMainThread && !pthread_main_np()) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [node class]; //hold and release in queue
            });
        }
    }
    pthread_mutex_unlock(&_lock);
}

- (void)removeObjectForKey:(id)key {
    if (!key) return;
    pthread_mutex_lock(&_lock);
    
    _YYLinkedMapNode *node = CFDictionaryGetValue(_lru->_dic, (__bridge const void *)(key));
    if (node) {
        //从链表删除该节点
        [_lru removeNode:node];
        if (_lru->_releaseAsynchronously) {
            dispatch_queue_t queue = _lru->_releaseOnMainThread ? dispatch_get_main_queue() : YYMemoryCacheGetReleaseQueue();
            //在主线程或者子线程下异步销毁
            dispatch_async(queue, ^{
                [node class]; //hold and release in queue
            });
        } else if (_lru->_releaseOnMainThread && !pthread_main_np()) {
            //如果当前不在主线程 而且需要在主线程释放
            //则在主线程异步销毁
            dispatch_async(dispatch_get_main_queue(), ^{
                [node class]; //hold and release in queue
            });
        }
    }
    pthread_mutex_unlock(&_lock);
}

- (void)removeAllObjects {
    pthread_mutex_lock(&_lock);
    [_lru removeAll];
    pthread_mutex_unlock(&_lock);
}

- (void)trimToCount:(NSUInteger)count {
    if (count == 0) {
        [self removeAllObjects];
        return;
    }
    [self _trimToCount:count];
}

- (void)trimToCost:(NSUInteger)cost {
    [self _trimToCost:cost];
}

- (void)trimToAge:(NSTimeInterval)age {
    [self _trimToAge:age];
}

- (NSString *)description {
    if (_name) return [NSString stringWithFormat:@"<%@: %p> (%@)", self.class, self, _name];
    else return [NSString stringWithFormat:@"<%@: %p>", self.class, self];
}

@end
