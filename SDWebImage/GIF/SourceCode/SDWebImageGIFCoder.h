/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import <Foundation/Foundation.h>
#import "SDWebImageCoder.h"

/**
 Built in coder using ImageIO that supports GIF encoding/decoding
 @note `SDWebImageIOCoder` supports GIF but only as static (will use the 1st frame).
 @note Use `SDWebImageGIFCoder` for fully animated GIFs - less performant than `FLAnimatedImage`
 @note If you decide to make all `UIImageView`(including `FLAnimatedImageView`) instance support GIF. You should add this coder to `SDWebImageCodersManager` and make sure that it has a higher priority than `SDWebImageIOCoder`
 @note The recommended approach for animated GIFs is using `FLAnimatedImage`. It's more performant than `UIImageView` for GIF displaying
 */
//如果想用gif 假如通过SDWebImageIOCoder来解码 会有个问题 就是它会返回静态的图片
//假如通过SDWebImageGIFCoder来解码 作者觉得会性能上没FLAnimatedImage好
//所以在4.0里是支持FLAnimatedImageView
@interface SDWebImageGIFCoder : NSObject <SDWebImageCoder>

+ (nonnull instancetype)sharedCoder;

@end
