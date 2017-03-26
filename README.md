## 概览
`SDWebImage`通过`SDWebImageManager`类管理图片的下载与缓存。`SDWebImageManager`主要通过三个实例变量来管理图片：一个`imageDownloader`（`SDWebImageDownloader`类），一个`imageCache`（`SDWebImageCache`类）和一个`delegate`（`SDWebImageManagerDelegate`类）。`imageDownloader`负责下载图片，`imageCache`负责缓存图片，`delegate`负责协调两者，比如在`imageCache`中没找到对应的缓存图片时是否要从网络上下载，从网络上下载好了图片，在存入缓存之前是否要先做一些处理如边框之类。

## SDWebImageDownloader
一个imageDownloader维护一个downloadQueue（`NSOperationQueue`类）属性。imageDownloader会为每个图片url对应的下载操作创建一个downloadOperation（`SDWebImageDownloaderOperation`类，继承自`NSOperation`类)，并添加到downloadQueue中，并且添加依赖使得前一个被添加的downloadOperation依赖于后一个添加的downloadOperation，这样使得后加入的downloadOperation能先执行。imageDownloader还有一个`maxConcurrentOperationCount`属性，用来设置同时进行的最大下载数量，默认为6。这个数字越小，后加入的operation就能越快得到执行。这也是为什么快速滑动tableView时，SDWebImage能先下载滑动停下时被用户可见的部分tableView需要的图片的原因。针对同一url可能会有多个下载请求，这些下载请求可能具有不同progressBlock和completionBlock的情况，imageDownloader维护了一个以url为键，downloadOperation为值的字典用来存储已经接受但还没有完成的下载请求。每次要下载某一url的图片时，先到这里寻找是否存在该url对应的downloadOperation，若不存在则新建一个downloadOperation，若存在，则将progressBlock和completionBlock添加到downloadOperation的callbackBlocks字典中，downloadOperation下载进行时会执行callbackBlocks中的所有progressBlock，下载完成时会执行callbackBlocks中的所有completionBlock。取消某一下载请求时，只会将它的progressBlock和completionBlock从callbackBlocks中移除，callbackBlocks为空时，才取消对这个url的下载。默认下载完图片后会将图片解压缩，但可以自定义。

## SDWebImageCache
imageCache维护双级缓存：内存缓存和磁盘缓存。内存缓存用NSCache实现，磁盘缓存存放在NSCachesDirectory文件夹下，默认存储的是解压缩的图片。存储缓存图片时先存储在内存缓存中，若内存缓存超过了指定限制，则根据NSCache的移除规则移除某些缓存。根据设置还可能存储在磁盘缓存中，若磁盘缓存超过制定限制，仍继续存储操作，且暂时不做移除操作，但是在在进入后台后或者用户强制关闭应用时会清理磁盘缓存中的过期图片，若剩下的图片占的空间超过指定的限制，则按文件修改日期，从远到近删除，直到占的空间小于限制的一半。查找缓存时，先到内存缓存中查找，没找到再到磁盘缓存中查找。imageCache也可以设置是否在从缓存中提取图片时解压缩。在收到`UIApplicationDidReceiveMemoryWarningNotification`时清理内存缓存。

## 例子
向UIImageView发送`- (void)sd_setImageWithURL:(nullable NSURL *)url;`消息时，最终会转化为对`UIView+WebCache`的`- (void)sd_internalSetImageWithURL:(nullable NSURL *)url`方法的调用，这个方法又会调用`SDWebImageManager`的`- loadImageWithURL:(nullable NSURL *)url
         options:(SDWebImageOptions)options
        progress:(nullable SDWebImageDownloaderProgressBlock)progressBlock
       completed:(nullable SDInternalCompletionBlock)completedBlock;`方法，`loadImageWithURL`先到双级缓存中找，没找到再调用imageDownloader的`- downloadImageWithURL:(nullable NSURL *)url
             options:(SDWebImageDownloaderOptions)options
            progress:(nullable SDWebImageDownloaderProgressBlock)progressBlock
           completed:
               (nullable SDWebImageDownloaderCompletedBlock)completedBlock;`方法去网上下载，下载完成后将图片解压缩存入缓存并显示到UIImageView中。
               
## SDWebImage与FastImageCache的图片缓存政策的对比

### SDWebImageCache

* 缓存位置：内存缓存（NSCache）和磁盘缓存（NSCachesDirectory下）。
* 缓存内容：imageDownloader默认下载图片后解压缩，所以缓存的是解压缩的数据。也可以设置imageDownloader默认下载图片不解压缩，这样缓存的是没有解压缩的图片。磁盘缓存中一张图片是一个文件。
* 如何限制缓存大小：可以指定磁盘最多缓存的字节数量和图片有效期。
* 移除策略：在收到`UIApplicationDidReceiveMemoryWarningNotification`时清理内存缓存。在进入后台后或者用户强制关闭应用时清理磁盘缓存中的过期图片，若剩下的图片占的空间超过指定的maxCacheSize，则按文件修改日期，从远到近删除，直到占的空间小于maxCacheSize的一半。在添加新缓存时不会移除其他缓存，即使占用的空间超出了上限。

### FastImageCache

* 缓存位置：貌似只有磁盘缓存（NSCachesDirectory下）。内存缓存用户可以自己配置。
* 缓存内容：缓存的是图片解压缩后的数据。磁盘缓存中一张表是一个文件。
* 如何限制缓存大小：为每张表指定imageSize和maximumCount从而限制每张表的大小。初始化imageCache时指定创建哪几张表。从而限制整个imageCache的大小。
* 移除策略：在往某张表中加入新缓存时，若表已满，则移除一张最久没更新的图片缓存。更新包括存和取。

## Tips
`SDWebImageDownloader`类的实现涉及到自定义NSOperation子类和如何使用NSOperationQueue。在阅读源码之前建议先阅读苹果的官方文档[Concurrency Programming Guide](https://developer.apple.com/library/content/documentation/General/Conceptual/ConcurrencyProgrammingGuide/Introduction/Introduction.html)。
