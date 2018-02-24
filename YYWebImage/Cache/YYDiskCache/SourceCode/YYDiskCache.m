//
//  YYDiskCache.m
//  YYCache <https://github.com/ibireme/YYCache>
//
//  Created by ibireme on 15/2/11.
//  Copyright (c) 2015 ibireme.
//
//  This source code is licensed under the MIT-style license found in the
//  LICENSE file in the root directory of this source tree.
//

#import "YYDiskCache.h"
#import "YYKVStorage.h"
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonCrypto.h>
#import <objc/runtime.h>
#import <time.h>

#define Lock() dispatch_semaphore_wait(self->_lock, DISPATCH_TIME_FOREVER)
#define Unlock() dispatch_semaphore_signal(self->_lock)

static const int extended_data_key;

/// Free disk space in bytes.
static int64_t _YYDiskSpaceFree() {
    //获取NSHomeDirectory文件夹下的NSFileSystemFreeSize属性 获取剩余空间
    NSError *error = nil;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfFileSystemForPath:NSHomeDirectory() error:&error];
    if (error) return -1;
    int64_t space =  [[attrs objectForKey:NSFileSystemFreeSize] longLongValue];
    if (space < 0) space = -1;
    return space;
}

/// String's md5 hash.
static NSString *_YYNSStringMD5(NSString *string) {
    if (!string) return nil;
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char result[CC_MD5_DIGEST_LENGTH];
    CC_MD5(data.bytes, (CC_LONG)data.length, result);
    return [NSString stringWithFormat:
                @"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
                result[0],  result[1],  result[2],  result[3],
                result[4],  result[5],  result[6],  result[7],
                result[8],  result[9],  result[10], result[11],
                result[12], result[13], result[14], result[15]
            ];
}

/// weak reference for all instances
//作为静态区的对象 NSMapTable类的实例 和 由dispatch_semaphore_t创建的信号锁
static NSMapTable *_globalInstances;
static dispatch_semaphore_t _globalInstancesLock;

static void _YYDiskCacheInitGlobal() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        //由dispatch_semaphore创建的信号锁 只给一个线程进去处理
        _globalInstancesLock = dispatch_semaphore_create(1);
        //创建了一个动态字典 key是强引用 值是弱引用
        _globalInstances = [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsStrongMemory valueOptions:NSPointerFunctionsWeakMemory capacity:0];
    });
}

static YYDiskCache *_YYDiskCacheGetGlobal(NSString *path) {
    if (path.length == 0) return nil;
    _YYDiskCacheInitGlobal();
    //等待之前的线程完成 直到获取到信号
    dispatch_semaphore_wait(_globalInstancesLock, DISPATCH_TIME_FOREVER);
    //从字典通过key为path去获取值
    id cache = [_globalInstances objectForKey:path];
    //发送回信号给_globalInstancesLock 解锁
    dispatch_semaphore_signal(_globalInstancesLock);
    return cache;
}

static void _YYDiskCacheSetGlobal(YYDiskCache *cache) {
    if (cache.path.length == 0) return;
    _YYDiskCacheInitGlobal();
    dispatch_semaphore_wait(_globalInstancesLock, DISPATCH_TIME_FOREVER);
    //弱引用的形式通过_globalInstances保存YYDiskCache类的实例
    [_globalInstances setObject:cache forKey:cache.path];
    dispatch_semaphore_signal(_globalInstancesLock);
}



@implementation YYDiskCache {
    YYKVStorage *_kv;
    dispatch_semaphore_t _lock;
    dispatch_queue_t _queue;
}

- (void)_trimRecursively {
    __weak typeof(self) _self = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_autoTrimInterval * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        __strong typeof(_self) self = _self;
        if (!self) return;
        [self _trimInBackground];
        [self _trimRecursively];
    });
}

- (void)_trimInBackground {
    __weak typeof(self) _self = self;
    dispatch_async(_queue, ^{
        __strong typeof(_self) self = _self;
        if (!self) return;
        Lock();
        [self _trimToCost:self.costLimit];
        [self _trimToCount:self.countLimit];
        [self _trimToAge:self.ageLimit];
        [self _trimToFreeDiskSpace:self.freeDiskSpaceLimit];
        //解锁
        Unlock();
    });
}

- (void)_trimToCost:(NSUInteger)costLimit {
    if (costLimit >= INT_MAX) return;
    [_kv removeItemsToFitSize:(int)costLimit];
    
}

- (void)_trimToCount:(NSUInteger)countLimit {
    if (countLimit >= INT_MAX) return;
    [_kv removeItemsToFitCount:(int)countLimit];
}

- (void)_trimToAge:(NSTimeInterval)ageLimit {
    if (ageLimit <= 0) {
        [_kv removeAllItems];
        return;
    }
    //该时间差是timestamp - ageLimit 获得一个新的日期 比timestamp旧的
    //time(NULL) 返回的是系统的现在时间 为秒
    long timestamp = time(NULL);
    if (timestamp <= ageLimit) return;
    long age = timestamp - ageLimit;
    if (age >= INT_MAX) return;
    [_kv removeItemsEarlierThanTime:(int)age];
}

- (void)_trimToFreeDiskSpace:(NSUInteger)targetFreeDiskSpace {
    if (targetFreeDiskSpace == 0) return;
    //获取size字段获取所有图片size的总和
    int64_t totalBytes = [_kv getItemsSize];
    if (totalBytes <= 0) return;
    //获取NSHomeDirectory文件夹下的NSFileSystemFreeSize属性 获取剩余空间
    int64_t diskFreeBytes = _YYDiskSpaceFree();
    if (diskFreeBytes < 0) return;
    //用指定的剩余磁盘空间 减去 实际磁盘剩余空间
    int64_t needTrimBytes = targetFreeDiskSpace - diskFreeBytes;
    if (needTrimBytes <= 0) return;
    int64_t costLimit = totalBytes - needTrimBytes;
    if (costLimit < 0) costLimit = 0;
    //删除文件
    [self _trimToCost:(int)costLimit];
}

- (NSString *)_filenameForKey:(NSString *)key {
    NSString *filename = nil;
    if (_customFileNameBlock) filename = _customFileNameBlock(key);
    if (!filename) filename = _YYNSStringMD5(key);
    return filename;
}

- (void)_appWillBeTerminated {
    Lock();
    _kv = nil;
    Unlock();
}

#pragma mark - public

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationWillTerminateNotification object:nil];
}

- (instancetype)init {
    @throw [NSException exceptionWithName:@"YYDiskCache init error" reason:@"YYDiskCache must be initialized with a path. Use 'initWithPath:' or 'initWithPath:inlineThreshold:' instead." userInfo:nil];
    return [self initWithPath:@"" inlineThreshold:0];
}

- (instancetype)initWithPath:(NSString *)path {
    return [self initWithPath:path inlineThreshold:1024 * 20]; // 20KB
}

- (instancetype)initWithPath:(NSString *)path
             inlineThreshold:(NSUInteger)threshold {
    //threshold 指的是阈值 临界值
    //path 指的是在NSCachesDirectory文件夹里com.ibireme.yykit/image文件夹的路径
    self = [super init];
    if (!self) return nil;
    
    YYDiskCache *globalCache = _YYDiskCacheGetGlobal(path);
    //如果有值 则直接返回
    if (globalCache) return globalCache;
    
    //如果临界值为0 代表只需要用文件保存
    YYKVStorageType type;
    if (threshold == 0) {
        type = YYKVStorageTypeFile;
        //如果临界值为NSUIntegerMax 代表要用数据库保存
    } else if (threshold == NSUIntegerMax) {
        type = YYKVStorageTypeSQLite;
    } else {
        //否则 则采用混合型处理
        type = YYKVStorageTypeMixed;
    }
    
    YYKVStorage *kv = [[YYKVStorage alloc] initWithPath:path type:type];
    if (!kv) return nil;
    
    _kv = kv;
    _path = path;
    _lock = dispatch_semaphore_create(1);
    //并行队列
    _queue = dispatch_queue_create("com.ibireme.cache.disk", DISPATCH_QUEUE_CONCURRENT);
    //临界值
    _inlineThreshold = threshold;
    //限制个数
    _countLimit = NSUIntegerMax;
    //限制cost
    _costLimit = NSUIntegerMax;
    //过期时间
    _ageLimit = DBL_MAX;
    //限制空余磁盘空间
    _freeDiskSpaceLimit = 0;
    //自动检测时间60秒
    _autoTrimInterval = 60;
    
    [self _trimRecursively];
    //弱引用的形式通过_globalInstances保存YYDiskCache类的实例
    _YYDiskCacheSetGlobal(self);
    
    //若收到app销毁时 直接将_kv置为nil 就会调用YYKVStorage的dealloc方法 若其的数据库自行关闭
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_appWillBeTerminated) name:UIApplicationWillTerminateNotification object:nil];
    return self;
}

- (BOOL)containsObjectForKey:(NSString *)key {
    if (!key) return NO;
    Lock();
    BOOL contains = [_kv itemExistsForKey:key];
    Unlock();
    return contains;
}

- (void)containsObjectForKey:(NSString *)key withBlock:(void(^)(NSString *key, BOOL contains))block {
    if (!block) return;
    __weak typeof(self) _self = self;
    dispatch_async(_queue, ^{
        __strong typeof(_self) self = _self;
        BOOL contains = [self containsObjectForKey:key];
        block(key, contains);
    });
}

- (id<NSCoding>)objectForKey:(NSString *)key {
    if (!key) return nil;
    //这里lock 可是有可能会被主线程调用的喔 用dispatch_semaphore_wait来锁的
    Lock();
    //根据key 先去数据库找到该记录 假如没记录则证明没有该文件 返回nil
    //假如在数据库上找到记录 封装成YYKVStorageItem类的实例 根据filename获取在其文件的磁盘路径 若找到 则赋值在item的value属性上 若没有 则返回nil
    YYKVStorageItem *item = [_kv getItemForKey:key];
    //解锁
    Unlock();
    //若没有获取到图片数据 则返回nil
    if (!item.value) return nil;
    
    id object = nil;
    //若实现_customUnarchiveBlock 则通过_customUnarchiveBlock将图片数据Unarchive 里面的实现是直接返回data 啥都没搞
    if (_customUnarchiveBlock) {
        object = _customUnarchiveBlock(item.value);
    } else {
        //否则 则使用NSKeyedUnarchiver对图片数据进行Unarchive
        @try {
            object = [NSKeyedUnarchiver unarchiveObjectWithData:item.value];
        }
        @catch (NSException *exception) {
            // nothing to do...
        }
    }
    //若存在object && item.extendedData 则将item.extendedData 以AssociatedObject的方式强引用在object的extended_data_key为key上
    //该值通常是一些图片相关的信息值
    if (object && item.extendedData) {
        [YYDiskCache setExtendedData:item.extendedData toObject:object];
    }
    return object;
}

- (void)objectForKey:(NSString *)key withBlock:(void(^)(NSString *key, id<NSCoding> object))block {
    if (!block) return;
    __weak typeof(self) _self = self;
    dispatch_async(_queue, ^{
        __strong typeof(_self) self = _self;
        id<NSCoding> object = [self objectForKey:key];
        block(key, object);
    });
}

- (void)setObject:(id<NSCoding>)object forKey:(NSString *)key {
    if (!key) return;
    if (!object) {
        [self removeObjectForKey:key];
        return;
    }
    
    NSData *extendedData = [YYDiskCache getExtendedDataFromObject:object];
    NSData *value = nil;
    if (_customArchiveBlock) {
        value = _customArchiveBlock(object);
    } else {
        @try {
            value = [NSKeyedArchiver archivedDataWithRootObject:object];
        }
        @catch (NSException *exception) {
            // nothing to do...
        }
    }
    if (!value) return;
    NSString *filename = nil;
    if (_kv.type != YYKVStorageTypeSQLite) {
        //如果图片的内容 大于 20kb 则将其以文件的方式保存
        if (value.length > _inlineThreshold) {
            filename = [self _filenameForKey:key];
        }
    }
    
    Lock();
    [_kv saveItemWithKey:key value:value filename:filename extendedData:extendedData];
    Unlock();
}

- (void)setObject:(id<NSCoding>)object forKey:(NSString *)key withBlock:(void(^)(void))block {
    __weak typeof(self) _self = self;
    dispatch_async(_queue, ^{
        __strong typeof(_self) self = _self;
        [self setObject:object forKey:key];
        if (block) block();
    });
}

- (void)removeObjectForKey:(NSString *)key {
    //根据_type判断进行何种删除的操作
    if (!key) return;
    Lock();
    [_kv removeItemForKey:key];
    Unlock();
}

- (void)removeObjectForKey:(NSString *)key withBlock:(void(^)(NSString *key))block {
    __weak typeof(self) _self = self;
    dispatch_async(_queue, ^{
        __strong typeof(_self) self = _self;
        [self removeObjectForKey:key];
        if (block) block(key);
    });
}

- (void)removeAllObjects {
    Lock();
    [_kv removeAllItems];
    Unlock();
}

- (void)removeAllObjectsWithBlock:(void(^)(void))block {
    __weak typeof(self) _self = self;
    dispatch_async(_queue, ^{
        __strong typeof(_self) self = _self;
        [self removeAllObjects];
        if (block) block();
    });
}

- (void)removeAllObjectsWithProgressBlock:(void(^)(int removedCount, int totalCount))progress
                                 endBlock:(void(^)(BOOL error))end {
    __weak typeof(self) _self = self;
    dispatch_async(_queue, ^{
        __strong typeof(_self) self = _self;
        if (!self) {
            if (end) end(YES);
            return;
        }
        Lock();
        [_kv removeAllItemsWithProgressBlock:progress endBlock:end];
        Unlock();
    });
}

- (NSInteger)totalCount {
    Lock();
    int count = [_kv getItemsCount];
    Unlock();
    return count;
}

- (void)totalCountWithBlock:(void(^)(NSInteger totalCount))block {
    if (!block) return;
    __weak typeof(self) _self = self;
    dispatch_async(_queue, ^{
        __strong typeof(_self) self = _self;
        NSInteger totalCount = [self totalCount];
        block(totalCount);
    });
}

- (NSInteger)totalCost {
    Lock();
    int count = [_kv getItemsSize];
    Unlock();
    return count;
}

- (void)totalCostWithBlock:(void(^)(NSInteger totalCost))block {
    if (!block) return;
    __weak typeof(self) _self = self;
    dispatch_async(_queue, ^{
        __strong typeof(_self) self = _self;
        NSInteger totalCost = [self totalCost];
        block(totalCost);
    });
}

- (void)trimToCount:(NSUInteger)count {
    Lock();
    [self _trimToCount:count];
    Unlock();
}

- (void)trimToCount:(NSUInteger)count withBlock:(void(^)(void))block {
    __weak typeof(self) _self = self;
    dispatch_async(_queue, ^{
        __strong typeof(_self) self = _self;
        [self trimToCount:count];
        if (block) block();
    });
}

- (void)trimToCost:(NSUInteger)cost {
    Lock();
    [self _trimToCost:cost];
    Unlock();
}

- (void)trimToCost:(NSUInteger)cost withBlock:(void(^)(void))block {
    __weak typeof(self) _self = self;
    dispatch_async(_queue, ^{
        __strong typeof(_self) self = _self;
        [self trimToCost:cost];
        if (block) block();
    });
}

- (void)trimToAge:(NSTimeInterval)age {
    Lock();
    [self _trimToAge:age];
    Unlock();
}

- (void)trimToAge:(NSTimeInterval)age withBlock:(void(^)(void))block {
    __weak typeof(self) _self = self;
    dispatch_async(_queue, ^{
        __strong typeof(_self) self = _self;
        [self trimToAge:age];
        if (block) block();
    });
}

+ (NSData *)getExtendedDataFromObject:(id)object {
    if (!object) return nil;
    return (NSData *)objc_getAssociatedObject(object, &extended_data_key);
}

+ (void)setExtendedData:(NSData *)extendedData toObject:(id)object {
    if (!object) return;
    objc_setAssociatedObject(object, &extended_data_key, extendedData, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSString *)description {
    if (_name) return [NSString stringWithFormat:@"<%@: %p> (%@:%@)", self.class, self, _name, _path];
    else return [NSString stringWithFormat:@"<%@: %p> (%@)", self.class, self, _path];
}

- (BOOL)errorLogsEnabled {
    Lock();
    BOOL enabled = _kv.errorLogsEnabled;
    Unlock();
    return enabled;
}

- (void)setErrorLogsEnabled:(BOOL)errorLogsEnabled {
    Lock();
    _kv.errorLogsEnabled = errorLogsEnabled;
    Unlock();
}

@end
