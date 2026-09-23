# GitHub 上传与后续更新

本工程的 .gitignore 已配置好。默认保留文件，只排除已知生成物；以后新增 HDL、约束、IP 配置、初始化数据、脚本和文档，通常不需要修改规则。

普通压缩软件和 GitHub 网页拖拽上传不会执行 .gitignore。使用 Git / GitHub Desktop 提交，或者按下文从 Git 导出干净 ZIP。

## 首次上传（只做一次）

在 GitHub 新建一个空仓库，不勾选自动添加 README、.gitignore 或 License。随后在 PowerShell 中执行：

```powershell
cd D:\vivado_work\anlogic_edge_osd
git init
git add -A
git status --short
```

检查将要提交的文件：应包含 .gitignore、TD 的 .al/.sdc、user_source 下的源码和 IP、sim 下的测试代码和脚本，不应出现 *_Runs、sim/out、sim/out_720p 里的文件。

确认列表后执行：

```powershell
git commit -m "首次提交安路TD合并工程"
git branch -M main
git remote add origin https://github.com/你的用户名/你的仓库名.git
git push -u origin main
```

将地址替换为自己空仓库的实际地址；首次推送按 Git 的提示完成 GitHub 登录。这里只配置本地过滤规则，尚未创建远程仓库或上传。

## 以后每次新增、修改、删除代码

1. 将新源码保存在本工程中，例如 user_source/hdl_source；新测试代码放在 sim。不要把源码放到 *_Runs、sim/out 或 sim/out_* 输出目录。
2. 若新模块需要参与 TD 编译，在 TD 中加入相应源码，并保存 .al 工程。Git 会发现文件，但不会替你更新 TD 工程里的源文件清单。
3. 在工程根目录执行：

```powershell
cd D:\vivado_work\anlogic_edge_osd
git add -A
git status --short
git diff --cached --stat
git commit -m "新增滤波模块并更新TD工程"
git push
```

提交说明改成此次实际修改内容。git add -A 会收集新增、修改和删除；命中 .gitignore 的未跟踪文件自动跳过。git commit 保存本地版本，git push 才上传到已关联的 GitHub 仓库。没有改动时无需提交；无须再次 git init 或 git remote add。

如果使用 GitHub Desktop：首次将本地仓库添加到 Desktop 并 Publish repository；后续保存代码后，在 Changes 中检查变更、填写说明、Commit to main、Push origin。过滤规则同样生效。

.gitignore 不是自动识别垃圾文件的工具。如果以后新工具输出到另一个目录，需要为那个输出目录新增规则。

## 需要干净压缩包时

先完成 git add -A 和 git commit，再执行：

```powershell
New-Item -ItemType Directory -Force .\exports | Out-Null
git archive --format=zip --output=exports/anlogic_edge_osd-source.zip --prefix=anlogic_edge_osd/ HEAD
```

ZIP 位于 exports/anlogic_edge_osd-source.zip，仅包含最后一次提交的文件。未提交的新代码或修改不会进入 ZIP；每次更新后重新提交、重新导出即可。exports 已被忽略，不会把导出的包再次提交。

## 查看某个文件为什么没被提交

```powershell
git check-ignore -v -- sim/out/edge.wdb
git status --short
```

check-ignore 会显示命中的规则；未跟踪文件没有命中时不会输出。先检查路径或调整 .gitignore，不要直接强制加入整个输出目录。

## 如果以前已经提交过生成物

.gitignore 不会自动取消对已有文件的跟踪。确认没有需要保留的暂存区安排后，可在工程根目录执行一次：

```powershell
git rm -r --cached .
git add -A
git status --short
git commit -m "清理版本跟踪，排除生成物"
git push
```

这里 --cached 只调整 Git 索引，不删除电脑里的文件；检查清单后再提交。这不会清除旧提交中已经保存的生成物，也不会立即缩小历史仓库体积。
