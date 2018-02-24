# YYWebImage

在看YYWebImage之前 我想run了下它提供的demo 发现在有大量动图的时候 会使cpu暴涨到200% ~ 300% 因此我带着这个问题的心情去看整个框架 但看着看着发现不得了 跟SDWebImage 这里的内容实在大得多 不过最后还是坚持慢慢看完它 并后来也找到出现那个bug的原因 十分舒畅呀～

整个YYWebImage不能像SDWebImage那样根据方法的调用去分析 所以我想分成两个部分去分析

* [cache](./Cache)
* [image](./Image)

