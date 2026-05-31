# windows-dev-bootstrap

Windows 开发环境一键初始化脚本，适合在新电脑或干净系统中快速配置常用开发工具。

脚本会通过交互提示完成开发根目录、Scoop 代理和开发工具套件选择，并尽量复用本机已经安装的组件。

## 快速开始

在普通用户权限的 PowerShell 中执行：

```powershell
irm https://raw.githubusercontent.com/YOUR_GITHUB_NAME/windows-dev-bootstrap/main/Initialize-WindowsDevEnv.ps1 | iex
```

执行后按提示选择开发根目录、代理和需要安装的开发工具套件。直接回车会使用默认值或安装全部套件。

## 先查看再执行

如果希望先查看脚本内容，再手动执行：

```powershell
irm https://raw.githubusercontent.com/YOUR_GITHUB_NAME/windows-dev-bootstrap/main/Initialize-WindowsDevEnv.ps1 -OutFile .\Initialize-WindowsDevEnv.ps1
notepad .\Initialize-WindowsDevEnv.ps1
.\Initialize-WindowsDevEnv.ps1
```

## 会安装什么

脚本支持以下开发工具套件：

- `git`：必选，包含 Git 安装和基础配置。
- `node开发套件`：包含 Volta、Node.js、npm、pnpm。
- `Java开发套件`：包含 JDK、Maven。
- `Python开发套件`：包含 Python、pip、uv。

选择开发工具时可以输入编号或名称，多个选项用英文逗号分隔。直接回车会安装全部套件。

示例：

```text
2,3
```

表示安装 node 开发套件和 Java 开发套件。Git 始终会安装或配置。

## 默认目录

默认开发根目录为：

```text
D:\Dev
```

脚本会在开发根目录下组织应用、缓存、配置和工作区：

- `D:\Dev\apps`
- `D:\Dev\caches`
- `D:\Dev\configs`
- `D:\Dev\workspace`

运行时可以根据提示输入其他开发根目录。

## 运行要求

- Windows 10 或 Windows 11。
- PowerShell 5.1 或更高版本。
- 普通用户权限即可，不需要管理员权限。
- 能访问 GitHub。
- 建议网络环境可以正常访问 Scoop、GitHub 和相关软件源。

## 安全提示

`irm ... | iex` 会下载远程脚本并立即执行。只从你信任的仓库运行这条命令。

如果不确定脚本内容，请使用“先查看再执行”的方式。

## 常见问题

### Scoop 已经安装了怎么办？

脚本会检测已有 Scoop，存在时会跳过安装。

### Scoop bucket 已经存在怎么办？

脚本会跳过已经存在的 bucket，不会把它当作失败。

### 需要管理员权限吗？

不需要。脚本按普通用户安装方式设计。

### 直接回车会发生什么？

在开发工具选择步骤直接回车，会安装或配置全部开发工具套件。

### 可以只安装部分套件吗？

可以。选择开发工具时输入编号或名称即可，例如：

```text
2,4
```

表示安装 node 开发套件和 Python 开发套件。
