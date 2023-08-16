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

3. 执行脚本

    ```bash
    chmod +x ./migrate-rest.sh
    # 离线方式: 
    # 1. clone 仓库到本地
    # 2. 修改 .gitmodules
    # 3. push 到 gitlab/group/project
    ./migrate-rest.sh -f \
        -s https://github.com/<source_repo> \
        -t http://<gitlab_host>/<target_group>

    # 在线方式: 
    # 1. 发送 import from github 请求到 gitlab
    # 2. 等待所有仓库导入成功
    # 3. 提交 update .gitmodules commit
    ./migrate-rest.sh -n \
        -s https://github.com/<source_repo> \
        -t http://<gitlab_host>/<target_group>
    # ... 此时可以在 gitlab 上看到仓库列表且仓库状态为 "Import in progress"
    # ... 等待所有仓库导入成功，导入时间取决于 gitlab 服务器网络
    ./migrate-rest.sh -u \
        -t http://<gitlab_host>/<target_group>

    ```