# github-migrate-tool

用于将 github repo 及其 submodules 整体(包含 submodule 的 submodules)迁移到 gitlab group 的工具

## Running

1. 设置 Github Token 及 Gitlab Token 用于访问服务，获取方法参考:
    [[Github-repo权限]](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens#creating-a-personal-access-token-classic)
    [[Gitlab-api权限]](https://docs.gitlab.com/ee/user/profile/personal_access_tokens.html#create-a-personal-access-token)

    ```bash
    export GITHUB_TOKEN="<GITHUB_TOKEN>"
    export GITLAB_TOKEN="<GITLAB_TOKEN>"
    ```

2. 创建 gitlab group 作为迁移目标，参考: [[create-a-group]](https://docs.gitlab.com/ee/user/group/#create-a-group)

3. 迁移

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

## Description

<p align="center">
    <img src="migrate.png">
</p>
