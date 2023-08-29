# github-migrate-tool

用于将 GitHub Repo 及其 submodules 整体迁移到 GitLab Project 的工具

## Requirement

1. 安装 git-lfs，参考：[[installing-git-large-file-storage]](https://docs.github.com/en/repositories/working-with-files/managing-large-files/installing-git-large-file-storage)

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
    chmod +x ./migrate-local.sh

    # 迁移指定分支，如"master"
    ./migrate-local.sh \
        -s "https://github.com/{owner}/{repo}" \
        -t "http://127.0.0.1/{group}" \
        -b "master"

    # 迁移所有分支
    ./migrate-local.sh \
        -s "https://github.com/{owner}/{repo}" \
        -t "http://127.0.0.1/{group}"
    ```

4. 从 GitLab 克隆项目，注意要使用 `--remote` 参数

    ```bash
    git clone --recursive --remote -b ${branch} ${proj_url}
    ```

## Description

以 https://github.com/{owner}/{repo}.git 为例，脚本执行结果如下:
1. 脚本将 GitHub Repo 克隆到本地 {pwd}/{owner}/{repo} 路径下
2. 在指定的 GitLab Group 中创建 subgroup {owner}
3. 在 {owner} 中创建 project {repo}

注意：迁移脚本会移除 .gitmodules 中的 "blessed/" 分支前缀

<p align="center">
    <img src="migrate.png">
</p>
