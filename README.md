# github-migrate-tool

用于将 github repo 及其 submodules 整体(包含 submodule 的 submodules)迁移到 gitlab group 的工具

## Running

1. 设置 Github Token 及 Gitlab Token 用于访问服务，获取方法参考:  
    Github: https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens#creating-a-personal-access-token-classic  
    Gitlab: https://docs.gitlab.com/ee/user/profile/personal_access_tokens.html#create-a-personal-access-token

    ```bash
    export GITHUB_TOKEN="<GITHUB_TOKEN>"
    export GITLAB_TOKEN="<GITLAB_TOKEN>"
    ```

2. 创建 gitlab group 作为迁移目标，参考: https://docs.gitlab.com/ee/user/group/#create-a-group

3. 迁移 & 同步

    ```bash
    chmod +x ./migrate-local.sh
    ./migrate-local.sh \
        -s "https://github.com/{owner}/{repo}" \
        -t "http://127.0.0.1/{group}" \
        -b "master"
    ```

## Description

1. 首先，脚本会将远端的代码仓库（及submodules）仓库都克隆为本地仓库。
2. 之后，将仓库push到gitlab服务器。
3. 最后，迭代地修改gitlab group中各个project地submodule地址。

    <mark>注意</mark>：push使用“--force”参数，会强制覆盖所有gitlab更改历史，因此gitlab project只能作为镜像仓库，无法跟踪开发。
