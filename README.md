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
    ./migrate-local.sh -s ${src_repo} -t ${tar_group} -b ${branch}
    ```

4. 从 GitLab 克隆项目

    ```bash
    git clone --recursive -b ${branch} ${proj_url}
    ```

## Description

脚本执行结果如下:
1. 本地保存源仓库的景象，路径如：`./user/repo`
2. 在目标 Group 中创建 subgroup，命名为：`user`
3. 在 subgroup 中创建 proj，命名为：`repo`

此外，还在本地 `./.migrate_log` 目录下存储执行必要的跟踪文件

<p align="center">
    <img src="migrate.png">
</p>
