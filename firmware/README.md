# 烧录文件

**本目录保存脚本编译出的 `anlogic_edge_osd.bit`，可直接烧录。**

双击根目录 `build_firmware.cmd`，成功后会在原路径更新本文件；
下载器重新加载后再烧录。
如果使用 TD 界面编译，继续选择
`td_project/anlogic_edge_osd_Runs/best_result/anlogic_edge_osd.bit`。
TD 界面编译不会更新本目录，两个目录不会自动同步。

当前文件的 SHA256、构建时间和时序结果以
[build/release/release_manifest.json](../build/release/release_manifest.json) 为准。

本目录只保留一份脚本发布的烧录文件。
脚本报告放在 `build/release`，源码放在 `user_source`。
