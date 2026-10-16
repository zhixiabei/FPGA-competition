# 烧录文件

**只选择本目录的 `anlogic_edge_osd.bit`。**

首次使用时，将下载器的文件路径改到这里。每次构建成功后，文件会在原路径更新；
在下载器中重新加载后再烧录，板上的配置才会改变。

重新生成：双击项目根目录 `build_firmware.cmd`。
当前文件的 SHA256、构建时间和时序结果以
[build/release/release_manifest.json](../build/release/release_manifest.json) 为准。

本目录只保留一份对外烧录文件。报告放在 `build/release`，源码放在 `user_source`。

旧 `td_project/anlogic_edge_osd_Runs` 中的重复 bit 和缓存已清理。
直接使用 TD 图形界面编译会重新生成 `best_result` 等输出目录；
日常通过根目录构建脚本生成本目录的固定烧录文件。
