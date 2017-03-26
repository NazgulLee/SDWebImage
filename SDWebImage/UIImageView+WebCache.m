/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "UIImageView+WebCache.h"

#if SD_UIKIT || SD_MAC

#import "objc/runtime.h"
#import "UIView+WebCacheOperation.h"
#import "UIView+WebCache.h"

@implementation UIImageView (WebCache)

- (void)sd_setImageWithURL:(nullable NSURL *)url {
    [self sd_setImageWithURL:url placeholderImage:nil options:0 progress:nil completed:nil];
}

- (void)sd_setImageWithURL:(nullable NSURL *)url placeholderImage:(nullable UIImage *)placeholder {
    [self sd_setImageWithURL:url placeholderImage:placeholder options:0 progress:nil completed:nil];
}

- (void)sd_setImageWithURL:(nullable NSURL *)url placeholderImage:(nullable UIImage *)placeholder options:(SDWebImageOptions)options {
    [self sd_setImageWithURL:url placeholderImage:placeholder options:options progress:nil completed:nil];
}

- (void)sd_setImageWithURL:(nullable NSURL *)url completed:(nullable SDExternalCompletionBlock)completedBlock {
    [self sd_setImageWithURL:url placeholderImage:nil options:0 progress:nil completed:completedBlock];
}

- (void)sd_setImageWithURL:(nullable NSURL *)url placeholderImage:(nullable UIImage *)placeholder completed:(nullable SDExternalCompletionBlock)completedBlock {
    [self sd_setImageWithURL:url placeholderImage:placeholder options:0 progress:nil completed:completedBlock];
}

- (void)sd_setImageWithURL:(nullable NSURL *)url placeholderImage:(nullable UIImage *)placeholder options:(SDWebImageOptions)options completed:(nullable SDExternalCompletionBlock)completedBlock {
    [self sd_setImageWithURL:url placeholderImage:placeholder options:options progress:nil completed:completedBlock];
}

- (void)sd_setImageWithURL:(nullable NSURL *)url
          placeholderImage:(nullable UIImage *)placeholder
                   options:(SDWebImageOptions)options
                  progress:(nullable SDWebImageDownloaderProgressBlock)progressBlock
                 completed:(nullable SDExternalCompletionBlock)completedBlock {
    [self sd_internalSetImageWithURL:url
                    placeholderImage:placeholder
                             options:options
                        operationKey:nil
                       setImageBlock:nil
                            progress:progressBlock
                           completed:completedBlock];
}
// 以先前缓存的图片作为placeholder去下载新的图片。以url生成key，到缓存（先内存再磁盘）中找缓存，若有，把它作为下载过程的placeholder，若无，以参数中的placeholder为placeholder。是的，还是要下载image
- (void)sd_setImageWithPreviousCachedImageWithURL:(nullable NSURL *)url
                                 placeholderImage:(nullable UIImage *)placeholder
                                          options:(SDWebImageOptions)options
                                         progress:(nullable SDWebImageDownloaderProgressBlock)progressBlock
                                        completed:(nullable SDExternalCompletionBlock)completedBlock {
    NSString *key = [[SDWebImageManager sharedManager] cacheKeyForURL:url];
    UIImage *lastPreviousCachedImage = [[SDImageCache sharedImageCache] imageFromCacheForKey:key];
    
    [self sd_setImageWithURL:url placeholderImage:lastPreviousCachedImage ?: placeholder options:options progress:progressBlock completed:completedBlock];    
}

#if SD_UIKIT

#pragma mark - Animation of multiple images

- (void)sd_setAnimationImagesWithURLs:(nonnull NSArray<NSURL *> *)arrayOfURLs {
    [self sd_cancelCurrentAnimationImagesLoad];
    __weak __typeof(self)wself = self;

    NSMutableArray<id<SDWebImageOperation>> *operationsArray = [[NSMutableArray alloc] init];

    for (NSURL *logoImageURL in arrayOfURLs) {
        id <SDWebImageOperation> operation = [SDWebImageManager.sharedManager loadImageWithURL:logoImageURL options:0 progress:nil completed:^(UIImage *image, NSData *data, NSError *error, SDImageCacheType cacheType, BOOL finished, NSURL *imageURL) {
            if (!wself) return;
            dispatch_main_async_safe(^{// 若已在main queue上，直接执行block；若不在main queue上，则分发到main queue上执行
                __strong UIImageView *sself = wself;
                [sself stopAnimating];
                if (sself && image) {
                    NSMutableArray<UIImage *> *currentImages = [[sself animationImages] mutableCopy];
                    if (!currentImages) {
                        currentImages = [[NSMutableArray alloc] init];
                    }
                    [currentImages addObject:image];

                    sself.animationImages = currentImages;
                    [sself setNeedsLayout];
                }
                [sself startAnimating];
            });
        }];
        [operationsArray addObject:operation];
    }

    [self sd_setImageLoadOperation:[operationsArray copy] forKey:@"UIImageViewAnimationImages"];
}

- (void)sd_cancelCurrentAnimationImagesLoad {
    [self sd_cancelImageLoadOperationWithKey:@"UIImageViewAnimationImages"];
}
#endif

@end

#endif
