# SDWebImage

先看下面这两张图 （源于SDWebImage库里的）:

![SDWebImageClassDiagram](/Users/guomanli/Downloads/SDWebImageClassDiagram.png)

![SDWebImageSequenceDiagram](/Users/guomanli/Downloads/SDWebImageSequenceDiagram.png)

从这两张图中可以看出 整个流程最重要的几个类是UIView(WebCache)、SDWebImageManager、SDWebImageCache、SDWebImageDownloader 

所以我会从这几个类为分类来充当流程的步骤 来分析整个SDWebImage的工作原理

* [UIView(WebCache)]()
* [SDWebImageManager]()
* [SDWebImageCache]()
* [SDWebImageDownloader]()