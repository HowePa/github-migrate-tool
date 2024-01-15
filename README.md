# github-migrate-tool

用于将 GitHub Repo 及其 submodules 整体迁移到 GitLab Project 的工具  

## Requirement

1. 安装依赖

    ```bash
    sudo apt-get install curl jq -y
    # 若仓库存在大文件，需安装git-lfs，并设置以下权限
    git config --global lfs.locksverify true
    ```

    - git-lfs安装参考: [[installing-git-large-file-storage]](https://docs.github.com/en/repositories/working-with-files/managing-large-files/installing-git-large-file-storage)

2. 创建 GitHub Token 及 GitLab Token 用于访问服务，参考:
    [[GitHub-repo权限]](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens#creating-a-personal-access-token-classic)
    [[GitLab-api权限]](https://docs.gitlab.com/ee/user/profile/personal_access_tokens.html#create-a-personal-access-token)

3. 创建 GitLab Group 作为目标迁移路径，参考: [[create-a-group]](https://docs.gitlab.com/ee/user/group/#create-a-group)

## Running

### 动态迁移

扫描所有submodule，  
若已迁移则从gitlab下载，否则从github下载并push到gitlab;  
若gitlab分支过期(commit_id不存在)，从github重新下载并push到gitlab.  

```bash
# Step 1: 克隆仓库到本地（非recursive）
git clone <repo_url> -b <branch> <local_path>
# Step 2: 动态迁移
export GITHUB_TOKEN=<github_token>
export GITLAB_TOKEN=<gitlab_token>
export GITLAB_HOST=http://oauth2:<gitlab_token>@<gitlab_host>
export DEPS_GROUP=<deps_group_name>
./migrate-dynamic.sh <local_path>   # <local_path>是本地仓库的绝对路径
```


### 静态迁移

迁移根仓库**所有分支**以及所有submodule的**所有分支**

```bash
export GITHUB_TOKEN=<github_token>
export GITLAB_TOKEN=<gitlab_token>
./migrate-static.sh -s <src_repo> -t <tar_group> -b <branch>
```