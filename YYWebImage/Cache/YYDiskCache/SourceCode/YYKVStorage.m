//
//  YYKVStorage.m
//  YYCache <https://github.com/ibireme/YYCache>
//
//  Created by ibireme on 15/4/22.
//  Copyright (c) 2015 ibireme.
//
//  This source code is licensed under the MIT-style license found in the
//  LICENSE file in the root directory of this source tree.
//

#import "YYKVStorage.h"
#import <UIKit/UIKit.h>
#import <time.h>

#if __has_include(<sqlite3.h>)
#import <sqlite3.h>
#else
#import "sqlite3.h"
#endif


static const NSUInteger kMaxErrorRetryCount = 8;
static const NSTimeInterval kMinRetryTimeInterval = 2.0;
static const int kPathLengthMax = PATH_MAX - 64;
static NSString *const kDBFileName = @"manifest.sqlite";
static NSString *const kDBShmFileName = @"manifest.sqlite-shm";
static NSString *const kDBWalFileName = @"manifest.sqlite-wal";
static NSString *const kDataDirectoryName = @"data";
static NSString *const kTrashDirectoryName = @"trash";


/*
 File:
 /path/
      /manifest.sqlite
      /manifest.sqlite-shm
      /manifest.sqlite-wal
      /data/
           /e10adc3949ba59abbe56e057f20f883e
           /e10adc3949ba59abbe56e057f20f883e
      /trash/
            /unused_file_or_folder
 
 SQL:
 create table if not exists manifest (
    key                 text,
    filename            text,
    size                integer,
    inline_data         blob,
    modification_time   integer,
    last_access_time    integer,
    extended_data       blob,
    primary key(key)
 ); 
 create index if not exists last_access_time_idx on manifest(last_access_time);
 */

/// Returns nil in App Extension.
static UIApplication *_YYSharedApplication() {
    static BOOL isAppExtension = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = NSClassFromString(@"UIApplication");
        if(!cls || ![cls respondsToSelector:@selector(sharedApplication)]) isAppExtension = YES;
        if ([[[NSBundle mainBundle] bundlePath] hasSuffix:@".appex"]) isAppExtension = YES;
    });
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
    return isAppExtension ? nil : [UIApplication performSelector:@selector(sharedApplication)];
#pragma clang diagnostic pop
}


@implementation YYKVStorageItem
@end

@implementation YYKVStorage {
    dispatch_queue_t _trashQueue;
    
    NSString *_path;
    NSString *_dbPath;
    NSString *_dataPath;
    NSString *_trashPath;
    
    sqlite3 *_db;
    CFMutableDictionaryRef _dbStmtCache;
    NSTimeInterval _dbLastOpenErrorTime;
    NSUInteger _dbOpenErrorCount;
}


#pragma mark - db

- (BOOL)_dbOpen {
    //若存在_db句柄 则返回YES
    if (_db) return YES;
    
    //打开数据库
    int result = sqlite3_open(_dbPath.UTF8String, &_db);
    //如果初始化成功 则进入下面的判断
    if (result == SQLITE_OK) {
        //创建一个类型为CFDictionary的可变字典
        //key是需要调用copy持有
        CFDictionaryKeyCallBacks keyCallbacks = kCFCopyStringDictionaryKeyCallBacks;
        //value这个不是很懂 有两种说法 一种是啥都不做（可能性较低） 一种是作为默认的功能 即retain
        CFDictionaryValueCallBacks valueCallbacks = {0};
        _dbStmtCache = CFDictionaryCreateMutable(CFAllocatorGetDefault(), 0, &keyCallbacks, &valueCallbacks);
        //数据库上一次打开失败的错误时间 清零
        _dbLastOpenErrorTime = 0;
        //数据库打开失败的次数 清零
        _dbOpenErrorCount = 0;
        return YES;
    } else {
        //若初始化失败 则进入下面的判断
        //_db置为null
        _db = NULL;
        //如果有_dbStmtCache 则释放_dbStmtCache
        if (_dbStmtCache) CFRelease(_dbStmtCache);
        //_dbStmtCache置为null
        _dbStmtCache = NULL;
        //记录当前时间为数据库打开失败的时间
        _dbLastOpenErrorTime = CACurrentMediaTime();
        //数据库打开失败的次数加一
        _dbOpenErrorCount++;
        
        //如果允许打印错误日志
        if (_errorLogsEnabled) {
            //__LINE__ 返回当前行数
            //result 返回数据库打开失败的原因
            NSLog(@"%s line:%d sqlite open failed (%d).", __FUNCTION__, __LINE__, result);
        }
        return NO;
    }
}

- (BOOL)_dbClose {
    if (!_db) return YES;
    
    int  result = 0;
    BOOL retry = NO;
    BOOL stmtFinalized = NO;
    //释放_dbStmtCache
    if (_dbStmtCache) CFRelease(_dbStmtCache);
    _dbStmtCache = NULL;
    
    do {
        retry = NO;
        result = sqlite3_close(_db);
        //关闭数据库 若返回结果是SQLITE_BUSY 或者 SQLITE_LOCKED 则代表有语句正在执行或准备执行 进入下面的判断
        if (result == SQLITE_BUSY || result == SQLITE_LOCKED) {
            //sql语句被编译成二进制格式的数据 并准备evaluated的 这种叫 Prepared Statement Object
            //sqlite3_next_stmt 做的就是将数据库里找出下一个Prepared Statement Object
            //sqlite3_finalize 做的就是将Prepared Statement Object删除
            if (!stmtFinalized) {
                stmtFinalized = YES;
                sqlite3_stmt *stmt;
                //循环寻找 直到没有Prepared Statement Object
                while ((stmt = sqlite3_next_stmt(_db, nil)) != 0) {
                    sqlite3_finalize(stmt);
                    retry = YES;
                }
            }
            //若返回结果不是SQLITE_OK 则打印错误 并退出循环
        } else if (result != SQLITE_OK) {
            if (_errorLogsEnabled) {
                NSLog(@"%s line:%d sqlite close failed (%d).", __FUNCTION__, __LINE__, result);
            }
        }
    } while (retry);
    //_db置为NULL
    _db = NULL;
    return YES;
}

- (BOOL)_dbCheck {
    //如果不存在_db句柄
    if (!_db) {
        //如果数据库打开失败的次数 少于 重试次数（8）而且 现在的时间减去数据库上次打开失败的时间 大于 重试时间（2秒） 则进入下面的判断
        if (_dbOpenErrorCount < kMaxErrorRetryCount &&
            CACurrentMediaTime() - _dbLastOpenErrorTime > kMinRetryTimeInterval) {
            //初始化数据库和创建manifest表
            return [self _dbOpen] && [self _dbInitialize];
        } else {
            //否则返回no
            return NO;
        }
    }
    return YES;
}

- (BOOL)_dbInitialize {
    NSString *sql = @"pragma journal_mode = wal; pragma synchronous = normal; create table if not exists manifest (key text, filename text, size integer, inline_data blob, modification_time integer, last_access_time integer, extended_data blob, primary key(key)); create index if not exists last_access_time_idx on manifest(last_access_time);";
    //pragma journal_mode = wal 启动wal模式
    //当事务对数据库进行修改时，将修改后的页面存入WAL文件中，而不写回原数据库。
    //WAL文件从数据库的第一个连接建立时创建，在最后一个连接释放时删除。
    //当事务要读取数据库内容时，先在WAL文件中找找有没有要读的那一页的最新版本，有的话就从WAL中读取。
    //没有的话，就从数据库中读取。
    //由于写事务只是在WAL文件之后追加一些内容，而读事务只是在WAL文件中查找一些内容。
    //所以，读事务在开始的时候，记录WAL文件的最后一个有效帧（read mark），并在整个事务中忽略之后添加的新内容。
    //这样可以做到读事务和写事务同时进行，提高了速度。
    
    //pragma synchronous = normal
    //指的是 wal文件写入磁盘的频率
    //假如用了full 则表示每次tranction写入wal文件时都调用一次fsync 即将wal文件保存在磁盘中 不会发生数据库损坏的情况
    //假如用了normal 则表示可能随机经过多次tranction写入后 才调用一次fsync 有一定机率会在发生电源故障导致数据库损坏的情况
    
    //create table if not exists manifest (key text, filename text, size integer, inline_data blob, modification_time integer, last_access_time integer, extended_data blob, primary key(key));
    //创建manifest表 主键为key
    
    //create index if not exists last_access_time_idx on manifest(last_access_time);
    //以manifest的last_access_time字段 增加last_access_time_idx索引 方便搜索
    return [self _dbExecute:sql];
}

- (void)_dbCheckpoint {
    if (![self _dbCheck]) return;
    // Cause a checkpoint to occur, merge `sqlite-wal` file to `sqlite` file.
    //将wal文件的内容写入数据库中 并清空wal文件
    sqlite3_wal_checkpoint(_db, NULL);
}

- (BOOL)_dbExecute:(NSString *)sql {
    //判断sql语句的正确性
    if (sql.length == 0) return NO;
    //判断数据库是否成功打开
    if (![self _dbCheck]) return NO;
    
    char *error = NULL;
    //第一个null 是sql调用后的回调 callback function
    //第二个null 是传入回调的第一个参数
    int result = sqlite3_exec(_db, sql.UTF8String, NULL, NULL, &error);
    if (error) {
        if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite exec error (%d): %s", __FUNCTION__, __LINE__, result, error);
        sqlite3_free(error);
    }
    
    return result == SQLITE_OK;
}

- (sqlite3_stmt *)_dbPrepareStmt:(NSString *)sql {
    if (![self _dbCheck] || sql.length == 0 || !_dbStmtCache) return NULL;
    //根据该sql 获取其Prepared Statement Object
    sqlite3_stmt *stmt = (sqlite3_stmt *)CFDictionaryGetValue(_dbStmtCache, (__bridge const void *)(sql));
    //Prepared Statement Object 若无 则进入下面的判断
    if (!stmt) {
        //sqlite3_prepare 是将这句sql 转转换成Prepared Statement Object 同时返回该对象的指针 但并没有执行该sql
        //sqlite3_prepare_v2 是新版 sqlite3_prepare是为了前向兼容
        int result = sqlite3_prepare_v2(_db, sql.UTF8String, -1, &stmt, NULL);
        if (result != SQLITE_OK) {
            if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite stmt prepare error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
            return NULL;
        }
        //将stmt以值的key为sql存入_dbStmtCache中
        CFDictionarySetValue(_dbStmtCache, (__bridge const void *)(sql), stmt);
    } else {
        //如果从_dbStmtCache 通过sql找到Prepared Statement Object 则执行下面的函数
        //reset该Prepared Statement Object 恢复成起始状态 预备重执行状态
        sqlite3_reset(stmt);
    }
    return stmt;
}

- (NSString *)_dbJoinedKeys:(NSArray *)keys {
    NSMutableString *string = [NSMutableString new];
    for (NSUInteger i = 0,max = keys.count; i < max; i++) {
        [string appendString:@"?"];
        if (i + 1 != max) {
            [string appendString:@","];
        }
    }
    return string;
}

- (void)_dbBindJoinedKeys:(NSArray *)keys stmt:(sqlite3_stmt *)stmt fromIndex:(int)index{
    for (int i = 0, max = (int)keys.count; i < max; i++) {
        NSString *key = keys[i];
        sqlite3_bind_text(stmt, index + i, key.UTF8String, -1, NULL);
    }
}

- (BOOL)_dbSaveWithKey:(NSString *)key value:(NSData *)value fileName:(NSString *)fileName extendedData:(NSData *)extendedData {
    //保存图片的信息 以key, filename, size, inline_data, modification_time, last_access_time, extended_data为字段
    NSString *sql = @"insert or replace into manifest (key, filename, size, inline_data, modification_time, last_access_time, extended_data) values (?1, ?2, ?3, ?4, ?5, ?6, ?7);";
    sqlite3_stmt *stmt = [self _dbPrepareStmt:sql];
    if (!stmt) return NO;
    
    int timestamp = (int)time(NULL);
    sqlite3_bind_text(stmt, 1, key.UTF8String, -1, NULL);
    sqlite3_bind_text(stmt, 2, fileName.UTF8String, -1, NULL);
    sqlite3_bind_int(stmt, 3, (int)value.length);
    //若fileName为空 则代表需要将图片的内容都存在数据库里
    if (fileName.length == 0) {
        sqlite3_bind_blob(stmt, 4, value.bytes, (int)value.length, 0);
    } else {
        sqlite3_bind_blob(stmt, 4, NULL, 0, 0);
    }
    sqlite3_bind_int(stmt, 5, timestamp);
    sqlite3_bind_int(stmt, 6, timestamp);
    sqlite3_bind_blob(stmt, 7, extendedData.bytes, (int)extendedData.length, 0);
    
    int result = sqlite3_step(stmt);
    if (result != SQLITE_DONE) {
        if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite insert error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
        return NO;
    }
    return YES;
}

- (BOOL)_dbUpdateAccessTimeWithKey:(NSString *)key {
    //通过key搜找该记录 并更新其last_access_time字段 值为现在的时间（单位秒数）
    NSString *sql = @"update manifest set last_access_time = ?1 where key = ?2;";
    sqlite3_stmt *stmt = [self _dbPrepareStmt:sql];
    if (!stmt) return NO;
    sqlite3_bind_int(stmt, 1, (int)time(NULL));
    sqlite3_bind_text(stmt, 2, key.UTF8String, -1, NULL);
    int result = sqlite3_step(stmt);
    if (result != SQLITE_DONE) {
        if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite update error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
        return NO;
    }
    return YES;
}

- (BOOL)_dbUpdateAccessTimeWithKeys:(NSArray *)keys {
    if (![self _dbCheck]) return NO;
    int t = (int)time(NULL);
     NSString *sql = [NSString stringWithFormat:@"update manifest set last_access_time = %d where key in (%@);", t, [self _dbJoinedKeys:keys]];
    
    sqlite3_stmt *stmt = NULL;
    int result = sqlite3_prepare_v2(_db, sql.UTF8String, -1, &stmt, NULL);
    if (result != SQLITE_OK) {
        if (_errorLogsEnabled)  NSLog(@"%s line:%d sqlite stmt prepare error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
        return NO;
    }
    
    [self _dbBindJoinedKeys:keys stmt:stmt fromIndex:1];
    result = sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    if (result != SQLITE_DONE) {
        if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite update error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
        return NO;
    }
    return YES;
}

- (BOOL)_dbDeleteItemWithKey:(NSString *)key {
    //根据key删除其在数据库的记录
    NSString *sql = @"delete from manifest where key = ?1;";
    sqlite3_stmt *stmt = [self _dbPrepareStmt:sql];
    if (!stmt) return NO;
    //sqlite3_bind_text的第四个参数是指字符串的长度
    //sqlite3_bind_text的第五个参数 是该字符串的析构函数 用于处理该字符串 即使api调用失败
    sqlite3_bind_text(stmt, 1, key.UTF8String, -1, NULL);
    
    //执行该sql 因为没有数据返回 执行正确时是SQLITE_DONE
    int result = sqlite3_step(stmt);
    if (result != SQLITE_DONE) {
        if (_errorLogsEnabled) NSLog(@"%s line:%d db delete error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
        return NO;
    }
    return YES;}

- (BOOL)_dbDeleteItemWithKeys:(NSArray *)keys {
    if (![self _dbCheck]) return NO;
    NSString *sql =  [NSString stringWithFormat:@"delete from manifest where key in (%@);", [self _dbJoinedKeys:keys]];
    sqlite3_stmt *stmt = NULL;
    int result = sqlite3_prepare_v2(_db, sql.UTF8String, -1, &stmt, NULL);
    if (result != SQLITE_OK) {
        if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite stmt prepare error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
        return NO;
    }
    
    [self _dbBindJoinedKeys:keys stmt:stmt fromIndex:1];
    result = sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    if (result == SQLITE_ERROR) {
        if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite delete error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
        return NO;
    }
    return YES;
}

- (BOOL)_dbDeleteItemsWithSizeLargerThan:(int)size {
    NSString *sql = @"delete from manifest where size > ?1;";
    sqlite3_stmt *stmt = [self _dbPrepareStmt:sql];
    if (!stmt) return NO;
    sqlite3_bind_int(stmt, 1, size);
    int result = sqlite3_step(stmt);
    if (result != SQLITE_DONE) {
        if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite delete error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
        return NO;
    }
    return YES;
}

- (BOOL)_dbDeleteItemsWithTimeEarlierThan:(int)time {
    //last_access_time 小于 限制的时间 即代表比它旧
    NSString *sql = @"delete from manifest where last_access_time < ?1;";
    sqlite3_stmt *stmt = [self _dbPrepareStmt:sql];
    if (!stmt) return NO;
    sqlite3_bind_int(stmt, 1, time);
    int result = sqlite3_step(stmt);
    if (result != SQLITE_DONE) {
        if (_errorLogsEnabled)  NSLog(@"%s line:%d sqlite delete error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
        return NO;
    }
    return YES;
}

- (YYKVStorageItem *)_dbGetItemFromStmt:(sqlite3_stmt *)stmt excludeInlineData:(BOOL)excludeInlineData {
    //获取该记录下的指定字段值
    int i = 0;
    char *key = (char *)sqlite3_column_text(stmt, i++);
    char *filename = (char *)sqlite3_column_text(stmt, i++);
    int size = sqlite3_column_int(stmt, i++);
    const void *inline_data = excludeInlineData ? NULL : sqlite3_column_blob(stmt, i);
    int inline_data_bytes = excludeInlineData ? 0 : sqlite3_column_bytes(stmt, i++);
    int modification_time = sqlite3_column_int(stmt, i++);
    int last_access_time = sqlite3_column_int(stmt, i++);
    const void *extended_data = sqlite3_column_blob(stmt, i);
    int extended_data_bytes = sqlite3_column_bytes(stmt, i++);
    
    //并通过YYKVStorageItem类实例封装获取到的数据 并返回item
    YYKVStorageItem *item = [YYKVStorageItem new];
    if (key) item.key = [NSString stringWithUTF8String:key];
    if (filename && *filename != 0) item.filename = [NSString stringWithUTF8String:filename];
    item.size = size;
    if (inline_data_bytes > 0 && inline_data) item.value = [NSData dataWithBytes:inline_data length:inline_data_bytes];
    item.modTime = modification_time;
    item.accessTime = last_access_time;
    if (extended_data_bytes > 0 && extended_data) item.extendedData = [NSData dataWithBytes:extended_data length:extended_data_bytes];
    return item;
}

- (YYKVStorageItem *)_dbGetItemWithKey:(NSString *)key excludeInlineData:(BOOL)excludeInlineData {
    //判断是否需要excludeInlineData字段而判断
    NSString *sql = excludeInlineData ? @"select key, filename, size, modification_time, last_access_time, extended_data from manifest where key = ?1;" : @"select key, filename, size, inline_data, modification_time, last_access_time, extended_data from manifest where key = ?1;";
    //执行该sql 获取其Prepared Statement Object
    sqlite3_stmt *stmt = [self _dbPrepareStmt:sql];
    if (!stmt) return nil;
    //绑定该参数?1 换成key
    sqlite3_bind_text(stmt, 1, key.UTF8String, -1, NULL);
    
    YYKVStorageItem *item = nil;
    
    int result = sqlite3_step(stmt);
    if (result == SQLITE_ROW) {
        //通过获取到的记录 获取其字段下的值 并用YYKVStorageItem类实例封装获取到的数据 返回item
        item = [self _dbGetItemFromStmt:stmt excludeInlineData:excludeInlineData];
    } else {
        if (result != SQLITE_DONE) {
            if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite query error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
        }
    }
    return item;
}

- (NSMutableArray *)_dbGetItemWithKeys:(NSArray *)keys excludeInlineData:(BOOL)excludeInlineData {
    if (![self _dbCheck]) return nil;
    NSString *sql;
    if (excludeInlineData) {
        sql = [NSString stringWithFormat:@"select key, filename, size, modification_time, last_access_time, extended_data from manifest where key in (%@);", [self _dbJoinedKeys:keys]];
    } else {
        sql = [NSString stringWithFormat:@"select key, filename, size, inline_data, modification_time, last_access_time, extended_data from manifest where key in (%@)", [self _dbJoinedKeys:keys]];
    }
    
    sqlite3_stmt *stmt = NULL;
    int result = sqlite3_prepare_v2(_db, sql.UTF8String, -1, &stmt, NULL);
    if (result != SQLITE_OK) {
        if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite stmt prepare error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
        return nil;
    }
    
    [self _dbBindJoinedKeys:keys stmt:stmt fromIndex:1];
    NSMutableArray *items = [NSMutableArray new];
    do {
        result = sqlite3_step(stmt);
        if (result == SQLITE_ROW) {
            YYKVStorageItem *item = [self _dbGetItemFromStmt:stmt excludeInlineData:excludeInlineData];
            if (item) [items addObject:item];
        } else if (result == SQLITE_DONE) {
            break;
        } else {
            if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite query error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
            items = nil;
            break;
        }
    } while (1);
    sqlite3_finalize(stmt);
    return items;
}

- (NSData *)_dbGetValueWithKey:(NSString *)key {
    NSString *sql = @"select inline_data from manifest where key = ?1;";
    sqlite3_stmt *stmt = [self _dbPrepareStmt:sql];
    if (!stmt) return nil;
    sqlite3_bind_text(stmt, 1, key.UTF8String, -1, NULL);
    
    int result = sqlite3_step(stmt);
    if (result == SQLITE_ROW) {
        const void *inline_data = sqlite3_column_blob(stmt, 0);
        int inline_data_bytes = sqlite3_column_bytes(stmt, 0);
        if (!inline_data || inline_data_bytes <= 0) return nil;
        return [NSData dataWithBytes:inline_data length:inline_data_bytes];
    } else {
        if (result != SQLITE_DONE) {
            if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite query error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
        }
        return nil;
    }
}

- (NSString *)_dbGetFilenameWithKey:(NSString *)key {
    NSString *sql = @"select filename from manifest where key = ?1;";
    sqlite3_stmt *stmt = [self _dbPrepareStmt:sql];
    if (!stmt) return nil;
    sqlite3_bind_text(stmt, 1, key.UTF8String, -1, NULL);
    int result = sqlite3_step(stmt);
    if (result == SQLITE_ROW) {
        char *filename = (char *)sqlite3_column_text(stmt, 0);
        if (filename && *filename != 0) {
            return [NSString stringWithUTF8String:filename];
        }
    } else {
        if (result != SQLITE_DONE) {
            if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite query error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
        }
    }
    return nil;
}

- (NSMutableArray *)_dbGetFilenameWithKeys:(NSArray *)keys {
    if (![self _dbCheck]) return nil;
    NSString *sql = [NSString stringWithFormat:@"select filename from manifest where key in (%@);", [self _dbJoinedKeys:keys]];
    sqlite3_stmt *stmt = NULL;
    int result = sqlite3_prepare_v2(_db, sql.UTF8String, -1, &stmt, NULL);
    if (result != SQLITE_OK) {
        if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite stmt prepare error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
        return nil;
    }
    
    [self _dbBindJoinedKeys:keys stmt:stmt fromIndex:1];
    NSMutableArray *filenames = [NSMutableArray new];
    do {
        result = sqlite3_step(stmt);
        if (result == SQLITE_ROW) {
            char *filename = (char *)sqlite3_column_text(stmt, 0);
            if (filename && *filename != 0) {
                NSString *name = [NSString stringWithUTF8String:filename];
                if (name) [filenames addObject:name];
            }
        } else if (result == SQLITE_DONE) {
            break;
        } else {
            if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite query error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
            filenames = nil;
            break;
        }
    } while (1);
    sqlite3_finalize(stmt);
    return filenames;
}

- (NSMutableArray *)_dbGetFilenamesWithSizeLargerThan:(int)size {
    NSString *sql = @"select filename from manifest where size > ?1 and filename is not null;";
    sqlite3_stmt *stmt = [self _dbPrepareStmt:sql];
    if (!stmt) return nil;
    sqlite3_bind_int(stmt, 1, size);
    
    NSMutableArray *filenames = [NSMutableArray new];
    do {
        int result = sqlite3_step(stmt);
        if (result == SQLITE_ROW) {
            char *filename = (char *)sqlite3_column_text(stmt, 0);
            if (filename && *filename != 0) {
                NSString *name = [NSString stringWithUTF8String:filename];
                if (name) [filenames addObject:name];
            }
        } else if (result == SQLITE_DONE) {
            break;
        } else {
            if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite query error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
            filenames = nil;
            break;
        }
    } while (1);
    return filenames;
}

- (NSMutableArray *)_dbGetFilenamesWithTimeEarlierThan:(int)time {
    //获取last_access_time比time旧的 而且 filename不为空的记录
    NSString *sql = @"select filename from manifest where last_access_time < ?1 and filename is not null;";
    sqlite3_stmt *stmt = [self _dbPrepareStmt:sql];
    if (!stmt) return nil;
    sqlite3_bind_int(stmt, 1, time);
    
    NSMutableArray *filenames = [NSMutableArray new];
    do {
        int result = sqlite3_step(stmt);
        if (result == SQLITE_ROW) {
            //将filename转换为NSString 并加到filenames数组中
            char *filename = (char *)sqlite3_column_text(stmt, 0);
            if (filename && *filename != 0) {
                NSString *name = [NSString stringWithUTF8String:filename];
                if (name) [filenames addObject:name];
            }
        } else if (result == SQLITE_DONE) {
            break;
        } else {
            if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite query error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
            filenames = nil;
            break;
        }
    } while (1);
    return filenames;
    
}

- (NSMutableArray *)_dbGetItemSizeInfoOrderByTimeAscWithLimit:(int)count {
    NSString *sql = @"select key, filename, size from manifest order by last_access_time asc limit ?1;";
    sqlite3_stmt *stmt = [self _dbPrepareStmt:sql];
    if (!stmt) return nil;
    //将?1绑定count上
    sqlite3_bind_int(stmt, 1, count);
    
    NSMutableArray *items = [NSMutableArray new];
    do {
        //执行sql 获取到一条记录 再调用后就会往下一条 last_access_time越小 证明上次接触的时间离现在越远
        int result = sqlite3_step(stmt);
        //result等于SQLITE_ROW 证明获取到数据
        if (result == SQLITE_ROW) {
            char *key = (char *)sqlite3_column_text(stmt, 0);
            char *filename = (char *)sqlite3_column_text(stmt, 1);
            int size = sqlite3_column_int(stmt, 2);
            NSString *keyStr = key ? [NSString stringWithUTF8String:key] : nil;
            if (keyStr) {
                //将获取到的记录 转换成 YYKVStorageItem类的实例
                YYKVStorageItem *item = [YYKVStorageItem new];
                item.key = key ? [NSString stringWithUTF8String:key] : nil;
                item.filename = filename ? [NSString stringWithUTF8String:filename] : nil;
                item.size = size;
                [items addObject:item];
            }
        } else if (result == SQLITE_DONE) {
            //result等于SQLITE_DONE 证明已经完成
            break;
        } else {
            if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite query error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
            items = nil;
            break;
        }
    } while (1);
    return items;
}

- (int)_dbGetItemCountWithKey:(NSString *)key {
    NSString *sql = @"select count(key) from manifest where key = ?1;";
    sqlite3_stmt *stmt = [self _dbPrepareStmt:sql];
    if (!stmt) return -1;
    sqlite3_bind_text(stmt, 1, key.UTF8String, -1, NULL);
    int result = sqlite3_step(stmt);
    if (result != SQLITE_ROW) {
        if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite query error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
        return -1;
    }
    return sqlite3_column_int(stmt, 0);
}

- (int)_dbGetTotalItemSize {
    //通过size字段获取size的总和
    //获取数据库所有图片的size
    NSString *sql = @"select sum(size) from manifest;";
    //通过sql 创建Prepared Statement Object 并保存在_dbStmtCache中
    sqlite3_stmt *stmt = [self _dbPrepareStmt:sql];
    if (!stmt) return -1;
    //执行该Prepared Statement Object
    int result = sqlite3_step(stmt);
    //SQLITE_ROW 代表有值输出
    if (result != SQLITE_ROW) {
        if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite query error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
        return -1;
    }
    //sqlite3_column_int 就是将result 返回成int类型
    return sqlite3_column_int(stmt, 0);
    
}

- (int)_dbGetTotalItemCount {
    //获取整个数据库的所有图片个数
    NSString *sql = @"select count(*) from manifest;";
    sqlite3_stmt *stmt = [self _dbPrepareStmt:sql];
    if (!stmt) return -1;
    int result = sqlite3_step(stmt);
    if (result != SQLITE_ROW) {
        if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite query error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
        return -1;
    }
    return sqlite3_column_int(stmt, 0);
}


#pragma mark - file

- (BOOL)_fileWriteWithName:(NSString *)filename data:(NSData *)data {
    NSString *path = [_dataPath stringByAppendingPathComponent:filename];
    return [data writeToFile:path atomically:NO];
}

- (NSData *)_fileReadWithName:(NSString *)filename {
    //通过文件名 获取文件的路径 并返回其二进制数据
    NSString *path = [_dataPath stringByAppendingPathComponent:filename];
    NSData *data = [NSData dataWithContentsOfFile:path];
    return data;
}

- (BOOL)_fileDeleteWithName:(NSString *)filename {
    //从_dataPath文件夹中删除该文件
    NSString *path = [_dataPath stringByAppendingPathComponent:filename];
    return [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

- (BOOL)_fileMoveAllToTrash {
    //获取默认的uuid
    CFUUIDRef uuidRef = CFUUIDCreate(NULL);
    //获取默认的uuid的字符串格式
    CFStringRef uuid = CFUUIDCreateString(NULL, uuidRef);
    //释放uuidRef
    CFRelease(uuidRef);
    //在_trashPath路径的文件夹下创建以uuid为文件名的临时文件夹
    NSString *tmpPath = [_trashPath stringByAppendingPathComponent:(__bridge NSString *)(uuid)];
    //将在_dataPath路径的文件夹移动在tmpPath内
    BOOL suc = [[NSFileManager defaultManager] moveItemAtPath:_dataPath toPath:tmpPath error:nil];
    //如果成功 则创建新的_dataPath为路径的文件夹
    if (suc) {
        suc = [[NSFileManager defaultManager] createDirectoryAtPath:_dataPath withIntermediateDirectories:YES attributes:nil error:NULL];
    }
    //释放uuid
    CFRelease(uuid);
    return suc;
}

- (void)_fileEmptyTrashInBackground {
    NSString *trashPath = _trashPath;
    dispatch_queue_t queue = _trashQueue;
    //在串行队列下异步处理 清空trashPath文件夹下的所有文件
    dispatch_async(queue, ^{
        NSFileManager *manager = [NSFileManager new];
        NSArray *directoryContents = [manager contentsOfDirectoryAtPath:trashPath error:NULL];
        for (NSString *path in directoryContents) {
            NSString *fullPath = [trashPath stringByAppendingPathComponent:path];
            [manager removeItemAtPath:fullPath error:NULL];
        }
    });
}


#pragma mark - private

/**
 Delete all files and empty in background.
 Make sure the db is closed.
 */
- (void)_reset {
    //删除manifest.sqlite文件
    [[NSFileManager defaultManager] removeItemAtPath:[_path stringByAppendingPathComponent:kDBFileName] error:nil];
    //删除manifest.sqlite-shm文件 //wal的索引文件 可以通过该文件快速寻找 不能遍历整个wal文件
    [[NSFileManager defaultManager] removeItemAtPath:[_path stringByAppendingPathComponent:kDBShmFileName] error:nil];
    //删除manifest.sqlite-wal文件
    [[NSFileManager defaultManager] removeItemAtPath:[_path stringByAppendingPathComponent:kDBWalFileName] error:nil];
    //将_dataPath路径的文件夹转移到_trash文件夹下 并创建新的_dataPath路径的文件夹
    [self _fileMoveAllToTrash];
    //在串行队列下异步处理 清空trashPath文件夹下的所有文件
    [self _fileEmptyTrashInBackground];
}

#pragma mark - public

- (instancetype)init {
    @throw [NSException exceptionWithName:@"YYKVStorage init error" reason:@"Please use the designated initializer and pass the 'path' and 'type'." userInfo:nil];
    return [self initWithPath:@"" type:YYKVStorageTypeFile];
}

- (instancetype)initWithPath:(NSString *)path type:(YYKVStorageType)type {
    //判断path路径的正确性
    if (path.length == 0 || path.length > kPathLengthMax) {
        NSLog(@"YYKVStorage init error: invalid path: [%@].", path);
        return nil;
    }
    //判断type的正确性
    if (type > YYKVStorageTypeMixed) {
        NSLog(@"YYKVStorage init error: invalid type: %lu.", (unsigned long)type);
        return nil;
    }
    
    self = [super init];
    //_path 引用path
    _path = path.copy;
    //_type 以type赋值
    _type = type;
    //_dataPath 指的是在NSCachesDirectory文件夹里com.ibireme.yykit/image/data文件夹的路径
    _dataPath = [path stringByAppendingPathComponent:kDataDirectoryName];
    //_trashPath 指的是在NSCachesDirectory文件夹里com.ibireme.yykit/image/trash文件夹的路径
    _trashPath = [path stringByAppendingPathComponent:kTrashDirectoryName];
    //创建串行队列 用于异步清理trash文件夹下的文件
    _trashQueue = dispatch_queue_create("com.ibireme.cache.disk.trash", DISPATCH_QUEUE_SERIAL);
    //_dbPath 指的是在NSCachesDirectory文件夹里com.ibireme.yykit/image/manifest.sqlite数据库的路径 
    _dbPath = [path stringByAppendingPathComponent:kDBFileName];
    //是否打印错误信息 默认为YE
    _errorLogsEnabled = YES;
    NSError *error = nil;
    //创建三个文件夹image image/data image/trash
    if (![[NSFileManager defaultManager] createDirectoryAtPath:path
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:&error] ||
        ![[NSFileManager defaultManager] createDirectoryAtPath:[path stringByAppendingPathComponent:kDataDirectoryName]
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:&error] ||
        ![[NSFileManager defaultManager] createDirectoryAtPath:[path stringByAppendingPathComponent:kTrashDirectoryName]
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:&error]) {
        NSLog(@"YYKVStorage init error:%@", error);
        return nil;
    }
    //_dbOpen方法 判断sqlite是否被成功初始化 或者 是否能成功创建表manifest 若都不能 则进入下面的判断
    if (![self _dbOpen] || ![self _dbInitialize]) {
        // db file may broken...
        //数据库文件可能损坏
        //关闭数据库
        [self _dbClose];
        [self _reset]; // rebuild
        if (![self _dbOpen] || ![self _dbInitialize]) {
            [self _dbClose];
            NSLog(@"YYKVStorage init error: fail to open sqlite db.");
            return nil;
        }
    }
    [self _fileEmptyTrashInBackground]; // empty the trash if failed at last time
    return self;
}

- (void)dealloc {
    UIBackgroundTaskIdentifier taskID = [_YYSharedApplication() beginBackgroundTaskWithExpirationHandler:^{}];
    [self _dbClose];
    if (taskID != UIBackgroundTaskInvalid) {
        [_YYSharedApplication() endBackgroundTask:taskID];
    }
}

- (BOOL)saveItem:(YYKVStorageItem *)item {
    return [self saveItemWithKey:item.key value:item.value filename:item.filename extendedData:item.extendedData];
}

- (BOOL)saveItemWithKey:(NSString *)key value:(NSData *)value {
    return [self saveItemWithKey:key value:value filename:nil extendedData:nil];
}

- (BOOL) saveItemWithKey:(NSString *)key value:(NSData *)value filename:(NSString *)filename extendedData:(NSData *)extendedData {
    if (key.length == 0 || value.length == 0) return NO;
    if (_type == YYKVStorageTypeFile && filename.length == 0) {
        return NO;
    }
    
    if (filename.length) {
        //以文件的方式写入
        if (![self _fileWriteWithName:filename data:value]) {
            return NO;
        }
        //以数据库的方式保存图片的信息
        if (![self _dbSaveWithKey:key value:value fileName:filename extendedData:extendedData]) {
            //若保存失败 则删除该图片在硬盘上的文件
            [self _fileDeleteWithName:filename];
            return NO;
        }
        return YES;
    } else {
        //若_type 不等于 YYKVStorageTypeSQLite 则表示不允许用sqilit保存文件的信息
        //那就是应该是用文件路径去保存
        //然而由于它filename为空 则代表它小于20kb 所以还是用回数据库去保存
        if (_type != YYKVStorageTypeSQLite) {
            //则会从数据库获取文件路径
            NSString *filename = [self _dbGetFilenameWithKey:key];
            //若存在 则去删除该文件
            if (filename) {
                [self _fileDeleteWithName:filename];
            }
        }
        return [self _dbSaveWithKey:key value:value fileName:nil extendedData:extendedData];
    }
}

- (BOOL)removeItemForKey:(NSString *)key {
    //根据_type的不同 会有不同的处理
    if (key.length == 0) return NO;
    switch (_type) {
        case YYKVStorageTypeSQLite: {
            //删除数据库保存的信息
            return [self _dbDeleteItemWithKey:key];
        } break;
        case YYKVStorageTypeFile:
        case YYKVStorageTypeMixed: {
            //获取文件路径
            NSString *filename = [self _dbGetFilenameWithKey:key];
            //若存在 则删除本地的文件
            if (filename) {
                [self _fileDeleteWithName:filename];
            }
            //删除数据库保存的信息
            return [self _dbDeleteItemWithKey:key];
        } break;
        default: return NO;
    }
}

- (BOOL)removeItemForKeys:(NSArray *)keys {
    if (keys.count == 0) return NO;
    switch (_type) {
        case YYKVStorageTypeSQLite: {
            return [self _dbDeleteItemWithKeys:keys];
        } break;
        case YYKVStorageTypeFile:
        case YYKVStorageTypeMixed: {
            NSArray *filenames = [self _dbGetFilenameWithKeys:keys];
            for (NSString *filename in filenames) {
                [self _fileDeleteWithName:filename];
            }
            return [self _dbDeleteItemWithKeys:keys];
        } break;
        default: return NO;
    }
}

- (BOOL)removeItemsLargerThanSize:(int)size {
    if (size == INT_MAX) return YES;
    if (size <= 0) return [self removeAllItems];
    
    switch (_type) {
        case YYKVStorageTypeSQLite: {
            if ([self _dbDeleteItemsWithSizeLargerThan:size]) {
                [self _dbCheckpoint];
                return YES;
            }
        } break;
        case YYKVStorageTypeFile:
        case YYKVStorageTypeMixed: {
            NSArray *filenames = [self _dbGetFilenamesWithSizeLargerThan:size];
            for (NSString *name in filenames) {
                [self _fileDeleteWithName:name];
            }
            if ([self _dbDeleteItemsWithSizeLargerThan:size]) {
                [self _dbCheckpoint];
                return YES;
            }
        } break;
    }
    return NO;
}

- (BOOL)removeItemsEarlierThanTime:(int)time {
    if (time <= 0) return YES;
    if (time == INT_MAX) return [self removeAllItems];
    
    //根据类型判断
    switch (_type) {
            //YYKVStorageTypeSQLite类型的
        case YYKVStorageTypeSQLite: {
            //删除所有last_access_time比time旧的记录
            if ([self _dbDeleteItemsWithTimeEarlierThan:time]) {
                //写入数据库
                [self _dbCheckpoint];
                return YES;
            }
        } break;
        case YYKVStorageTypeFile:
        case YYKVStorageTypeMixed: {
            //获取所有last_access_time比time旧的文件名
            NSArray *filenames = [self _dbGetFilenamesWithTimeEarlierThan:time];
            //遍历文件名 通过文件名删除_dataPath文件夹的图片
            for (NSString *name in filenames) {
                [self _fileDeleteWithName:name];
            }
            //再删除所有last_access_time比time旧的记录
            if ([self _dbDeleteItemsWithTimeEarlierThan:time]) {
                //写入数据库
                [self _dbCheckpoint];
                return YES;
            }
        } break;
    }
    return NO;
}

- (BOOL)removeItemsToFitSize:(int)maxSize {
    if (maxSize == INT_MAX) return YES;
    //里面调用[self reset]
    if (maxSize <= 0) return [self removeAllItems];
    //获取整个数据库的所有图片size
    int total = [self _dbGetTotalItemSize];
    if (total < 0) return NO;
    //如果所有图片size少于maxSize就直接返回
    if (total <= maxSize) return YES;
    
    NSArray *items = nil;
    BOOL suc = NO;
    do {
        int perCount = 16;
        //返回一个数组 是包含离上次接触的时间离最远的perCount条记录 并转换成 YYKVStorageItem类的实例
        items = [self _dbGetItemSizeInfoOrderByTimeAscWithLimit:perCount];
        
        for (YYKVStorageItem *item in items) {
            if (total > maxSize) {
                //从_dataPath文件夹中删除该文件
                if (item.filename) {
                    [self _fileDeleteWithName:item.filename];
                }
                //根据key删除数据库的记录
                suc = [self _dbDeleteItemWithKey:item.key];
                //总大小 减去该文件的大小
                total -= item.size;
            } else {
                break;
            }
            //根据删除数据库记录的成功 判断是否需要break 若发生什么错误即suc为no时 则证明数据有问题 需要break循环
            if (!suc) break;
        }
    } while (total > maxSize && items.count > 0 && suc);
    //suc为true时 则需要将wal文件的删除事务写入数据库中
    if (suc) [self _dbCheckpoint];
    return suc;
}

- (BOOL)removeItemsToFitCount:(int)maxCount {
    if (maxCount == INT_MAX) return YES;
    //里面调用[self reset]
    if (maxCount <= 0) return [self removeAllItems];
    
    //获取整个数据库的所有图片个数
    int total = [self _dbGetTotalItemCount];
    if (total < 0) return NO;
    if (total <= maxCount) return YES;
    
    NSArray *items = nil;
    BOOL suc = NO;
    do {
        int perCount = 16;
        //返回一个数组 是包含离上次接触的时间离最远的perCount条记录 并转换成 YYKVStorageItem类的实例
        items = [self _dbGetItemSizeInfoOrderByTimeAscWithLimit:perCount];
        for (YYKVStorageItem *item in items) {
            if (total > maxCount) {
                //从_dataPath文件夹中删除该文件
                if (item.filename) {
                    [self _fileDeleteWithName:item.filename];
                }
                //根据key删除数据库的记录
                suc = [self _dbDeleteItemWithKey:item.key];
                //总个数减一
                total--;
            } else {
                break;
            }
            //根据删除数据库记录的成功 判断是否需要break 若发生什么错误即suc为no时 则证明数据有问题 需要break循环
            if (!suc) break;
        }
    } while (total > maxCount && items.count > 0 && suc);
    //suc为true时 则需要将wal文件的删除事务写入数据库中
    if (suc) [self _dbCheckpoint];
    return suc;
}

- (BOOL)removeAllItems {
    if (![self _dbClose]) return NO;
    [self _reset];
    if (![self _dbOpen]) return NO;
    if (![self _dbInitialize]) return NO;
    return YES;
}

- (void)removeAllItemsWithProgressBlock:(void(^)(int removedCount, int totalCount))progress
                               endBlock:(void(^)(BOOL error))end {
    
    int total = [self _dbGetTotalItemCount];
    if (total <= 0) {
        if (end) end(total < 0);
    } else {
        int left = total;
        int perCount = 32;
        NSArray *items = nil;
        BOOL suc = NO;
        do {
            items = [self _dbGetItemSizeInfoOrderByTimeAscWithLimit:perCount];
            for (YYKVStorageItem *item in items) {
                if (left > 0) {
                    if (item.filename) {
                        [self _fileDeleteWithName:item.filename];
                    }
                    suc = [self _dbDeleteItemWithKey:item.key];
                    left--;
                } else {
                    break;
                }
                if (!suc) break;
            }
            if (progress) progress(total - left, total);
        } while (left > 0 && items.count > 0 && suc);
        if (suc) [self _dbCheckpoint];
        if (end) end(!suc);
    }
}

- (YYKVStorageItem *)getItemForKey:(NSString *)key {
    //根据key 先去数据库找到该记录 假如没记录则证明没有该文件 返回nil
    //假如在数据库上找到记录 封装成YYKVStorageItem类的实例 根据filename获取在其文件的磁盘路径 若找到 则赋值在item的value属性上 若没有 则返回nil
    if (key.length == 0) return nil;
    //通过key 查询数据库 并该记录封装成YYKVStorageItem类的实例 并返回item
    YYKVStorageItem *item = [self _dbGetItemWithKey:key excludeInlineData:NO];
    if (item) {
        //假如有该item 则更新其last_access_time字段
        [self _dbUpdateAccessTimeWithKey:key];
        
        if (item.filename) {
            //通过文件名 获取文件的路径 并返回其二进制数据 赋值在item的value属性上
            item.value = [self _fileReadWithName:item.filename];
            //如果发现在磁盘中没找到该文件 则需要在数据库上删除该记录
            if (!item.value) {
                //根据key 删除其在数据库的记录
                [self _dbDeleteItemWithKey:key];
                //将item置为nil
                item = nil;
            }
        }
    }
    return item;
}

- (YYKVStorageItem *)getItemInfoForKey:(NSString *)key {
    if (key.length == 0) return nil;
    YYKVStorageItem *item = [self _dbGetItemWithKey:key excludeInlineData:YES];
    return item;
}

- (NSData *)getItemValueForKey:(NSString *)key {
    if (key.length == 0) return nil;
    NSData *value = nil;
    switch (_type) {
        case YYKVStorageTypeFile: {
            NSString *filename = [self _dbGetFilenameWithKey:key];
            if (filename) {
                value = [self _fileReadWithName:filename];
                if (!value) {
                    [self _dbDeleteItemWithKey:key];
                    value = nil;
                }
            }
        } break;
        case YYKVStorageTypeSQLite: {
            value = [self _dbGetValueWithKey:key];
        } break;
        case YYKVStorageTypeMixed: {
            NSString *filename = [self _dbGetFilenameWithKey:key];
            if (filename) {
                value = [self _fileReadWithName:filename];
                if (!value) {
                    [self _dbDeleteItemWithKey:key];
                    value = nil;
                }
            } else {
                value = [self _dbGetValueWithKey:key];
            }
        } break;
    }
    if (value) {
        [self _dbUpdateAccessTimeWithKey:key];
    }
    return value;
}

- (NSArray *)getItemForKeys:(NSArray *)keys {
    if (keys.count == 0) return nil;
    NSMutableArray *items = [self _dbGetItemWithKeys:keys excludeInlineData:NO];
    if (_type != YYKVStorageTypeSQLite) {
        for (NSInteger i = 0, max = items.count; i < max; i++) {
            YYKVStorageItem *item = items[i];
            if (item.filename) {
                item.value = [self _fileReadWithName:item.filename];
                if (!item.value) {
                    if (item.key) [self _dbDeleteItemWithKey:item.key];
                    [items removeObjectAtIndex:i];
                    i--;
                    max--;
                }
            }
        }
    }
    if (items.count > 0) {
        [self _dbUpdateAccessTimeWithKeys:keys];
    }
    return items.count ? items : nil;
}

- (NSArray *)getItemInfoForKeys:(NSArray *)keys {
    if (keys.count == 0) return nil;
    return [self _dbGetItemWithKeys:keys excludeInlineData:YES];
}

- (NSDictionary *)getItemValueForKeys:(NSArray *)keys {
    NSMutableArray *items = (NSMutableArray *)[self getItemForKeys:keys];
    NSMutableDictionary *kv = [NSMutableDictionary new];
    for (YYKVStorageItem *item in items) {
        if (item.key && item.value) {
            [kv setObject:item.value forKey:item.key];
        }
    }
    return kv.count ? kv : nil;
}

- (BOOL)itemExistsForKey:(NSString *)key {
    if (key.length == 0) return NO;
    return [self _dbGetItemCountWithKey:key] > 0;
}

- (int)getItemsCount {
    return [self _dbGetTotalItemCount];
}

- (int)getItemsSize {
    return [self _dbGetTotalItemSize];
}

@end
