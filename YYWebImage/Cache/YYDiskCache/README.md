# YYDiskCache

队列数：2个

1. 用于通过cost、count、age、磁盘空间4个维度下进行数据库记录的检查和文件和记录的清理(优先度:默认 并发队列)
2. 用于在间隔5秒的类似定时器的操作(优先度:low 并发队列)

线程锁：2个

1. dispatch_semaphore信号量 作用于数据库的操作 而且semaphore信号量对于等待的线程具有顺序性
2. pthread_mutex互斥锁 作用于全局存储YYDiskCache实例的字典的存取方法里

 ## YYKVStorageItem

```objective-c
@interface YYKVStorageItem : NSObject
@property (nonatomic, strong) NSString *key;                ///< key
@property (nonatomic, strong) NSData *value;                ///< value
@property (nullable, nonatomic, strong) NSString *filename; ///< filename (nil if inline)
@property (nonatomic) int size;                             ///< value's size in bytes
@property (nonatomic) int modTime;                          ///< modification unix timestamp
@property (nonatomic) int accessTime;                       ///< last access unix timestamp
@property (nullable, nonatomic, strong) NSData *extendedData; ///< extended data (nil if no extended data)
@end
```

## YYKVStorage

```objective-c
@interface YYKVStorage : NSObject

#pragma mark - Attribute
@property (nonatomic, readonly) NSString *path;        ///< The path of this storage.
@property (nonatomic, readonly) YYKVStorageType type;  ///< The type of this storage.
@property (nonatomic) BOOL errorLogsEnabled;           ///< Set `YES` to enable error logs for debug.

#pragma mark - Initializer
- (instancetype)init UNAVAILABLE_ATTRIBUTE;
+ (instancetype)new UNAVAILABLE_ATTRIBUTE;

- (nullable instancetype)initWithPath:(NSString *)path type:(YYKVStorageType)type NS_DESIGNATED_INITIALIZER;


#pragma mark - Save Items
- (BOOL)saveItem:(YYKVStorageItem *)item;
- (BOOL)saveItemWithKey:(NSString *)key value:(NSData *)value;
- (BOOL)saveItemWithKey:(NSString *)key
                  value:(NSData *)value
               filename:(nullable NSString *)filename
           extendedData:(nullable NSData *)extendedData;

#pragma mark - Remove Items
- (BOOL)removeItemForKey:(NSString *)key;
- (BOOL)removeItemForKeys:(NSArray<NSString *> *)keys;
- (BOOL)removeItemsLargerThanSize:(int)size;
- (BOOL)removeItemsEarlierThanTime:(int)time;
- (BOOL)removeItemsToFitSize:(int)maxSize;
- (BOOL)removeItemsToFitCount:(int)maxCount;
- (BOOL)removeAllItems;
- (void)removeAllItemsWithProgressBlock:(nullable void(^)(int removedCount, int totalCount))progress
                               endBlock:(nullable void(^)(BOOL error))end;

#pragma mark - Get Items
- (nullable YYKVStorageItem *)getItemForKey:(NSString *)key;
- (nullable YYKVStorageItem *)getItemInfoForKey:(NSString *)key;
- (nullable NSData *)getItemValueForKey:(NSString *)key;
- (nullable NSArray<YYKVStorageItem *> *)getItemForKeys:(NSArray<NSString *> *)keys;
- (nullable NSArray<YYKVStorageItem *> *)getItemInfoForKeys:(NSArray<NSString *> *)keys;
- (nullable NSDictionary<NSString *, NSData *> *)getItemValueForKeys:(NSArray<NSString *> *)keys;

#pragma mark - Get Storage Status
- (BOOL)itemExistsForKey:(NSString *)key;
- (int)getItemsCount;
- (int)getItemsSize;

@end

```

注意点：

1. YYKVStorage实例不是线程安全的 所以需要保证在同一时间只有一个线程在处理 如果你想使用多线程去处理大量数据 那你应该将数据分开并使用多个YYKVStorage实例（分片处理）
2. 使用了wal模式 提高数据库的读取速度
3. 当每次进行删除记录操作时 都需要将wal文件的内容写入数据库中 并清空wal文件

## YYDiskCache

```objective-c
static int64_t _YYDiskSpaceFree();
static NSString *_YYNSStringMD5(NSString *string);

static NSMapTable *_globalInstances;
static dispatch_semaphore_t _globalInstancesLock;
static void _YYDiskCacheInitGlobal();
static YYDiskCache *_YYDiskCacheGetGlobal(NSString *path);
static void _YYDiskCacheSetGlobal(YYDiskCache *cache);

@interface YYDiskCache : NSObject

#pragma mark - Attribute
@property (nullable, copy) NSString *name;
@property (readonly) NSString *path;
@property (readonly) NSUInteger inlineThreshold;
@property (nullable, copy) NSData *(^customArchiveBlock)(id object);
@property (nullable, copy) id (^customUnarchiveBlock)(NSData *data);
@property (nullable, copy) NSString *(^customFileNameBlock)(NSString *key);

#pragma mark - Limit
@property NSUInteger countLimit;
@property NSUInteger costLimit;
@property NSTimeInterval ageLimit;
@property NSUInteger freeDiskSpaceLimit;
@property NSTimeInterval autoTrimInterval;
@property BOOL errorLogsEnabled;

@implementation YYDiskCache {
    YYKVStorage *_kv;
    dispatch_semaphore_t _lock;
    dispatch_queue_t _queue;
}

//私有方法
- (void)_trimRecursively;
- (void)_trimInBackground;
- (void)_trimToCost:(NSUInteger)costLimit;
- (void)_trimToCount:(NSUInteger)countLimit;
- (void)_trimToAge:(NSTimeInterval)ageLimit;
- (void)_trimToFreeDiskSpace:(NSUInteger)targetFreeDiskSpace;
- (NSString *)_filenameForKey:(NSString *)key;
- (void)_appWillBeTerminated;
//public方法
- (void)dealloc;
#pragma mark - Initializer
- (instancetype)init;
- (instancetype)initWithPath:(NSString *)path;
- (instancetype)initWithPath:(NSString *)path
             inlineThreshold:(NSUInteger)threshold;

#pragma mark - Access Methods
- (BOOL)containsObjectForKey:(NSString *)key;
- (id<NSCoding>)objectForKey:(NSString *)key;
- (void)objectForKey:(NSString *)key withBlock:(void(^)(NSString *key, id<NSCoding> object))block;
- (void)setObject:(id<NSCoding>)object forKey:(NSString *)key;
- (void)setObject:(id<NSCoding>)object forKey:(NSString *)key withBlock:(void(^)(void))block;
- (void)removeObjectForKey:(NSString *)key;
- (void)removeObjectForKey:(NSString *)key withBlock:(void(^)(NSString *key))block;
- (void)removeAllObjects;
- (void)removeAllObjectsWithBlock:(void(^)(void))block;
- (void)removeAllObjectsWithProgressBlock:(void(^)(int removedCount, int totalCount))progress
                                 endBlock:(void(^)(BOOL error))end;
- (NSInteger)totalCount;
- (void)totalCountWithBlock:(void(^)(NSInteger totalCount))block;
- (NSInteger)totalCost;
- (void)totalCostWithBlock:(void(^)(NSInteger totalCost))block;

#pragma mark - Trim
- (void)trimToCount:(NSUInteger)count;
- (void)trimToCount:(NSUInteger)count withBlock:(void(^)(void))block;
- (void)trimToCost:(NSUInteger)cost;
- (void)trimToCost:(NSUInteger)cost withBlock:(void(^)(void))block;
- (void)trimToAge:(NSTimeInterval)age;
- (void)trimToAge:(NSTimeInterval)age withBlock:(void(^)(void))block;

#pragma mark - Extended Data
+ (NSData *)getExtendedDataFromObject:(id)object;
+ (void)setExtendedData:(NSData *)extendedData toObject:(id)object;

- (NSString *)description;
- (BOOL)errorLogsEnabled;
- (void)setErrorLogsEnabled:(BOOL)errorLogsEnabled;
```

注意点：

1. 是用了根据阙值20kb判断文件数据是否保存在sqlite3里 或者保存图片的元信息 然后通过数据库获取到的md5文件名再去文件路径里寻找图片
2. 根据路径对YYDiskCache实例进行全局的保存 减少过多的实例创建对资源的浪费 并且是用NSMapTable来处理 跟字典类似 但可以接受不是对象的value
3. 用了并发队列处理数据库的增删改查处理 减少主线程的处理
4. 跟YYMemoryCache一样 针对每个文件（记录）的清除都是以lru的缓存淘汰算法为中心去处理
5. 用了一个CFMutableDictionaryRef 对象去保存sql所对应的sqlite3_stmt 可以减少重复生成sqlite3\_stmt的开销
6. 使用dispatch_semaphore信号量的原因

> dispatch_semaphore 是信号量，但当信号总量设为 1 时也可以当作锁来。在没有等待情况出现时，它的性能比 pthread_mutex 还要高，但一旦有等待情况出现时，性能就会下降许多。相对于 OSSpinLock 来说，它的优势在于等待时不会消耗 CPU 资源。对磁盘缓存来说，它比较合适。

所有类的实现注释都写在SourceCode文件夹里
