# github-migrate-tool

用于将 GitHub Repo 及其 submodules 整体迁移到 GitLab Project 的工具  

## Requirement

1. 安装 curl 和 jq

    ```bash
    sudo apt-get install curl jq -y
    ```

2. 安装 git-lfs，参考：[[installing-git-large-file-storage]](https://docs.github.com/en/repositories/working-with-files/managing-large-files/installing-git-large-file-storage)

    ```bash
    # 配置lfs.locksverify
    git config --global lfs.locksverify true
    ```

## Running

### Static

静态脚本会将主仓库及子模块的所有分支迁移到目标群组中，会在中转机上下载大量空仓库

1. 创建 GitHub Token 及 GitLab Token 用于访问服务，参考:
    [[GitHub-repo权限]](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens#creating-a-personal-access-token-classic)
    [[GitLab-api权限]](https://docs.gitlab.com/ee/user/profile/personal_access_tokens.html#create-a-personal-access-token)

    ```bash
    export GITHUB_TOKEN="<GITHUB_TOKEN>"
    export GITLAB_TOKEN="<GITLAB_TOKEN>"
    ```

2. 创建 GitLab Group 作为目标迁移路径，参考: [[create-a-group]](https://docs.gitlab.com/ee/user/group/#create-a-group)

3. 迁移 GitHub Repo -> GitLab Project

    ```bash
    # 参数 [-s:待迁移仓库] [-t:目标Group] [-b:指定分支(可选，无指定则迁移所有分支)]
    ./migrate-static.sh -s <src_repo> -t <tar_group> -b <branch>
    ```

4. 从 GitLab 克隆项目

    ```bash
    git clone --recursive -b <branch> <proj_url>
    ```

脚本执行结果如下:
1. 本地保存源仓库的镜像仓库，路径如：`./user/repo`
2. 在目标 Group 中创建 subgroup，命名为：`user`
3. 在 subgroup 中创建 proj，命名为：`repo`

此外，还在本地 `./.migrate_log` 目录下存储执行必要的跟踪文件

### Dynamic

动态脚本会根据当前本地仓库的状态，动态替换已迁移依赖的url以及更新新依赖到GitLab依赖群组中

1. 创建 GitLab Token 和依赖群组( GitLab Group，命名为 `<deps_group_name>` )，操作同上

2. 克隆 GitHub 项目到本地

    ```bash
    git clone https://github.com/xxx/xxx -b master <local_path>
    ```

3. 执行迁移脚本

    ```bash
    export GITLAB_TOKEN=<gitlab_token>
    export GITLAB_HOST=http://oauth2:<gitlab_token>@<gitlab_host>
    export DEPS_GROUP=<deps_group_name>
    ./migrate-dynamic.sh <local_path>
    ```

脚本会检测本地仓库的每个子模块，
1. 若存在于依赖组则替换 url 直接 clone
2. 若不存在于依赖组则从 GitHub 下载并 push 到依赖组中
3. 执行完脚本，本地仓库直接可用，相当于执行 `git submoudle update --init --recursive`

## Description

### Static

<p align="center">
    <img src="migrate.png">
</p>
