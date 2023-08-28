#!/bin/bash

function print_log() {
    DATE=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "\033[32m$DATE [INFO]\033[0m $1"
    echo "[$DATE] [INFO] $1" >>$CWD/migrate.log
}

function print_error() {
    DATE=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "\033[31m$DATE [ERROR]\033[0m $1"
    echo "[$DATE] [ERROR] $1" >>$CWD/migrate.log
}

function _parse_url() { # Input(url) Return(proto, host, [owner, name, group])
    echo "$(echo "$1" | awk 'BEGIN{FS="://|/|.git"}{print $1" "$2" "$3" "$4" "$5}')"
}

function _get_project() { # Input(proj_full_name) Return(proj_id)
    norm=$(echo "$1" | sed -e 's/\//%2F/g')
    echo "$(
        curl --silent --request GET \
            --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            --header "Content-Type: application/json" \
            --url "$TAR_HOST/api/v4/projects/$norm" |
            jq .id
    )"
}

function _get_group() { # Input(group_full_name) Return(group_id)
    norm=$(echo "$1" | sed -e 's/\//%2F/g')
    echo "$(
        curl --silent --request GET \
            --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            --url "$TAR_HOST/api/v4/groups/$norm" |
            jq .id
    )"
}

function _create_project() { # Input(proj_name namespace_id) Return(proj_id)
    echo "$(
        curl --silent --request POST \
            --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            --header "Content-Type: application/json" \
            --url "$TAR_HOST/api/v4/projects/" \
            --data '{
            "name": "'$1'",
            "namespace_id": "'$2'",
            "lfs_enabled": "true",
            "visibility": "'$VIS_LEVEL'"
        }' | jq .id
    )"
}

function _create_subgroup() { # Input(subgroup_name, parent_group_id) Return(subgroup_id)
    echo "$(
        curl --silent --request POST \
            --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            --header "Content-Type: application/json" \
            --url "$TAR_HOST/api/v4/groups/" \
            --data '{
            "path": "'$1'",
            "name": "'$1'",
            "parent_id": '$2',
            "visibility": "'$VIS_LEVEL'"
        }' | jq .id
    )"
}

function _get_github_default_branch() { # Input(repo_full_name) Return(default_branch)
    _response=$(
        curl --silent --request GET \
            --header "Authorization: Bearer $GITHUB_TOKEN" \
            --header "Accept: application/vnd.github.raw+json" \
            --header "X-GitHub-Api-Version: 2022-11-28" \
            --url https://api.github.com/repos/$1
    )
    _branch=$(echo "$_response" | jq -r .default_branch)
    if [ "$_branch" == "null" ]; then
        # archived repo
        _url=$(echo "$_response" | jq -r .url)
        _branch=$(
            curl --silent --request GET \
                --header "Authorization: Bearer $GITHUB_TOKEN" \
                --header "Accept: application/vnd.github.raw+json" \
                --header "X-GitHub-Api-Version: 2022-11-28" \
                --url $_url |
                jq -r .default_branch
        )
    fi
    echo "$_branch"
}

function _get_github_branches() { # Return(branches)
    _response=$(
        curl --silent --request GET \
            --header "Authorization: Bearer $GITHUB_TOKEN" \
            --header "Accept: application/vnd.github.raw+json" \
            --header "X-GitHub-Api-Version: 2022-11-28" \
            --url https://api.github.com/repos/$SRC_OWNER/$SRC_NAME/branches
    )
    _branches=$(echo "$_response" | jq -r '.[] | .name')
    if [ "_branches" == "null" ]; then
        # archived repo
        _url=$(echo "$_response" | jq -r .url)
        _remote_sha=$(
            curl --silent --request GET \
                --header "Authorization: Bearer $GITHUB_TOKEN" \
                --header "Accept: application/vnd.github.raw+json" \
                --header "X-GitHub-Api-Version: 2022-11-28" \
                --url $_url |
                jq -r '.[] | .name'
        )
    fi
    echo "$_branches"
}

function _get_github_submodules() { # Input(repo_full_name, branch) Return([submodule_url, submodule_branch])
    _response=$(
        curl --silent --request GET \
            --header "Authorization: Bearer $GITHUB_TOKEN" \
            --header "Accept: application/vnd.github+json" \
            --header "X-GitHub-Api-Version: 2022-11-28" \
            --url https://api.github.com/repos/$1/contents/.gitmodules?ref=$2
    )
    _content=$(echo "$_response" | jq .content)
    if [ "$_content" == null ]; then
        # archived repo
        _url=$(echo "$_response" | jq -r .url)
        _content=$(
            curl --silent --request GET \
                --header "Authorization: Bearer $GITHUB_TOKEN" \
                --header "Accept: application/vnd.github.raw+json" \
                --header "X-GitHub-Api-Version: 2022-11-28" \
                --url $_url
        )
    else
        _content=$(
            curl --silent --request GET \
                --header "Authorization: Bearer $GITHUB_TOKEN" \
                --header "Accept: application/vnd.github.raw+json" \
                --header "X-GitHub-Api-Version: 2022-11-28" \
                --url https://api.github.com/repos/$1/contents/.gitmodules?ref=$2
        )
    fi
    echo "$(
        echo "$_content" |
            sed -e 's/\t//g' |
            awk '{FS="submodule \"| = "}{
                if($1=="["){printf "\n"}
                else if($1=="url"){printf $2}
                else if($1=="branch"){printf " " $2}
                } END {printf "\n"}'
    )"
}

function _need_update() { # Input(repo_full_name, branch, commit_sha) Return(bool)
    _response=$(
        curl --silent --request GET \
            --header "Authorization: Bearer $GITHUB_TOKEN" \
            --header "Accept: application/vnd.github.raw+json" \
            --header "X-GitHub-Api-Version: 2022-11-28" \
            --url https://api.github.com/repos/$1/branches/$2
    )
    _remote_sha=$(echo "$_response" | jq -r '.commit | .sha')
    if [ "$_remote_sha" == "null" ]; then
        # archived repo
        _url=$(echo "$_response" | jq -r .url)
        _remote_sha=$(
            curl --silent --request GET \
                --header "Authorization: Bearer $GITHUB_TOKEN" \
                --header "Accept: application/vnd.github.raw+json" \
                --header "X-GitHub-Api-Version: 2022-11-28" \
                --url $_url |
                jq -r '.commit | .sha'
        )
    fi
    if [ "$_remote_sha" == "$3" ]; then
        echo "false"
    else
        echo "true"
    fi
}

function _migrate() { # Input(src_owner, src_name, branch)
    _path=$1
    _name=$2
    _branch=$3
    ##### Recursively scan submodules #####
    _get_github_submodules $_path/$_name $_branch | while read _sub_url _sub_branch; do
        if [ ! -z "$_sub_url" ]; then
            read _sub_proto _sub_host _sub_owner _sub_name <<<$(_parse_url "$_sub_url")
            if [ -z "$_sub_branch" ]; then
                # Todo: check branch or tag ?
                _sub_branch=$(_get_github_default_branch $_sub_owner/$_sub_name)
            fi
            _sub_branch=$(echo "$_sub_branch" | sed -e 's/blessed\///g')
            _migrate $_sub_owner $_sub_name $_sub_branch
        fi
    done

    _local_path=$CWD/$_path/$_name
    ##### Create Proj ####
    _proj_id=$(_get_project $TAR_GROUP/$_path/$_name)
    if [ "$_proj_id" == "null" ]; then
        _group_id=$(_get_group $TAR_GROUP/$_path)
        if [ "$_group_id" == "null" ]; then
            print_log "create subgroup $TAR_PROTO://$TAR_HOST/$TAR_GROUP/$_path"
            _group_id=$(_create_subgroup $_path $TAR_GROUP_ID)
        fi
        print_log "create proj $TAR_PROTO://$TAR_HOST/$TAR_GROUP/$_path/$_name"
        _proj_id=$(_create_project $_name $_group_id)
    fi
    if [ ! -d "$_local_path" ]; then
        ##### Clone Repo #####
        print_log "clone $SRC_PROTO://$SRC_HOST/$_path/$_name"
        git clone --mirror $SRC_PROTO://oauth2:$GITHUB_TOKEN@$SRC_HOST/$_path/$_name $_local_path 2>&1 | tee -a $CWD/migrate.log
        ##### Push All #####
        cd $_local_path
        _has_lfs="$(git lfs ls-files)"
        if [ ! -z "$_has_lfs" ]; then
            git lfs fetch --all $SRC_PROTO://oauth2:$GITHUB_TOKEN@$SRC_HOST/$_path/$_name 2>&1 | tee -a $CWD/migrate.log &&
                git lfs push --all $TAR_PROTO://oauth2:$GITLAB_TOKEN@$TAR_HOST/$TAR_GROUP/$_path/$_name 2>&1 | tee -a $CWD/migrate.log
        fi
        git push --mirror $TAR_PROTO://oauth2:$GITLAB_TOKEN@$TAR_HOST/$TAR_GROUP/$_path/$_name 2>&1 | tee -a $CWD/migrate.log
        ##### Set Default Branch #####
        _default_branch=$(_get_github_default_branch $_path/$_name)
        _response=$(
            curl --silent --request PUT \
                --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
                --url "$TAR_PROTO://$TAR_HOST/api/v4/projects/$_proj_id" \
                --data "default_branch=$_default_branch"
        )
        print_log "set $TAR_GROUP/$_path/$_name <default_branch=$_default_branch>"
        cd $CWD
    else
        ##### Pull #####
        cd $_local_path
        _local_commit_sha=$(git rev-parse $_branch)
        _update_flag=$(_need_update $_path/$_name $_branch $_local_commit_sha)
        if [ "$_update_flag" == "true" ]; then
            print_log "update $_local_path <$_branch>"
            git remote update 2>&1 | tee -a $CWD/migrate.log
            ##### Push Branch #####
            if [ "$_push_flag" == "true" ]; then
                print_log "push $TAR_PROTO://$TAR_HOST/$TAR_GROUP/$_path/$_name <$_branch>"
                _has_lfs="$(git lfs ls-files)"
                if [ ! -z "$_has_lfs" ]; then
                    git lfs fetch $SRC_PROTO://oauth2:$GITHUB_TOKEN@$SRC_HOST/$_path/$_name $_branch 2>&1 | tee -a $CWD/migrate.log &&
                        git lfs push $TAR_PROTO://oauth2:$GITLAB_TOKEN@$TAR_HOST/$TAR_GROUP/$_path/$_name $branch 2>&1 | tee -a $CWD/migrate.log
                fi
                git push --force $TAR_PROTO://oauth2:$GITLAB_TOKEN@$TAR_HOST/$TAR_GROUP/$_path/$_name $_branch 2>&1 | tee -a $CWD/migrate.log
            fi
        else
            print_log "$_local_path <$_branch> is the latest version"
        fi
        cd $CWD
    fi
}

function _get_gitmodules_content() { # Input(proj_full_name, branch)
    _proj_id=$(_get_project $1)
    echo "$(
        curl --silent --request GET \
            --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            --url "$TAR_PROTO://$TAR_HOST/api/v4/projects/$_proj_id/repository/files/.gitmodules?ref=$2" |
            jq -r .content
    )"
}

function _linkmodules() { # Input(tar_subgroup, tar_name, branch)
    _path=$1
    _name=$2
    _branch=$3
    ##### Recursively scan submodules #####
    _get_github_submodules $_path/$_name $_branch | while read _sub_url _sub_branch; do
        if [ ! -z "$_sub_url" ]; then
            read _sub_proto _sub_host _sub_owner _sub_name <<<$(_parse_url $_sub_url)
            if [ -z "$_sub_branch" ]; then
                _sub_branch=$(_get_github_default_branch $_sub_owner/$_sub_name)
            fi
            _sub_branch=$(echo "$_sub_branch" | sed -e 's/blessed\///g')
            _linkmodules $_sub_owner $_sub_name $_sub_branch
        fi
    done

    ##### Link submodules #####
    _content=$(_get_gitmodules_content $TAR_GROUP/$_path/$_name $_branch)
    if [ ! -z "$_content" ] && [ "$_content" != "null" ]; then
        _new_content=$(echo $(
            echo "$_content" | base64 -d |
                sed -e 's/'$SRC_PROTO':\/\/'$SRC_HOST'\//'$TAR_PROTO':\/\/'$TAR_HOST'\/'$TAR_GROUP'\//g' |
                base64
        ) | sed -e 's/ //g')
        _content=$(echo $_content | sed -e 's/ //g')
        if [ "$_content" != "$_new_content" ]; then
            _response=$(
                curl --silent --request PUT \
                    --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
                    --header "Content-Type: application/json" \
                    --url "$TAR_PROTO://$TAR_HOST/api/v4/projects/$TAR_GROUP%2F$_path%2F$_name/repository/files/.gitmodules" \
                    --data '{
                        "branch": "'$_branch'",
                        "content": "'$_new_content'",
                        "commit_message": "Update .gitmodules",
                        "encoding": "base64"
                    }' | jq -r .file_path
            )
            if [ "$_response" == ".gitmodules" ]; then
                print_log "link $TAR_PROTO://$TAR_HOST/$TAR_GROUP/$_path/$_name/-/blob/$_branch/.gitmodules"
            else
                print_error "link $TAR_PROTO://$TAR_HOST/$TAR_GROUP/$_path/$_name/-/blob/$_branch/.gitmodules [$_response]"
            fi
        else
            print_log "$TAR_PROTO://$TAR_HOST/$TAR_GROUP/$_path/$_name/-/blob/$_branch/.gitmodules already linked"
        fi
    fi
}

function _get_gitlab_default_branch() { # Input(repo_full_name) Return(default_branch)
    _proj_id=$(_get_project $1)
    echo "$(
        curl --silent --request GET \
            --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            --header "Content-Type: application/json" \
            --url "http://192.168.1.203:3396/api/v4/projects/$_proj_id" |
            jq -r .default_branch
    )"
}

function _get_gitlab_submodules() { # Input(proj_full_name, branch) Return([submodule_url, submodule_branch])
    norm=$(echo "$1" | sed -e 's/\//%2F/g')
    echo "$(
        curl --silent --request GET \
            --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            --url "$TAR_HOST//api/v4/projects/$norm/repository/files/.gitmodules/raw?ref=$2" |
            sed -e 's/\t//g' |
            awk '{FS="submodule \"| = "}{
                if($1=="["){printf "\n"}
                else if($1=="url"){printf $2}
                else if($1=="branch"){printf " " $2}
                } END {printf "\n"}'
    )"
}

function _verify() { # Input(tar_subgroup, tar_name, branch)
    _path=$1
    _name=$2
    _branch=$3
    ##### Recursively scan submodules #####
    _get_gitlab_submodules $TAR_GROUP/$_path/$_name $_branch | while read _sub_url _sub_branch; do
        if [ ! -z "$_sub_url" ]; then
            read _sub_proto _sub_host _sub_group _sub_subgroup _sub_name <<<$(_parse_url $_sub_url)
            if [ -z "$_sub_branch" ]; then
                _sub_branch=$(_get_gitlab_default_branch $_sub_group/$_sub_subgroup/$_sub_name)
            fi
            _sub_branch=$(echo "$_sub_branch" | sed -e 's/blessed\///g')
            _verify $_sub_subgroup $_sub_name $_sub_branch $_level
        fi
    done

    ##### Verify #####
    _proj_id=$(_get_project $TAR_GROUP/$_path/$_name)
    if [ "$_proj_id" == "null" ]; then
        print_error "lose proj $TAR_PROTO://$TAR_HOST/$TAR_GROUP/$_path/$_name <$_branch>"
    else
        print_log "verify $TAR_PROTO://$TAR_HOST/$TAR_GROUP/$_path/$_name <$_branch>"
    fi
}

CWD=$(pwd)
BRANCH=""
VIS_LEVEL=public
while getopts "hs:t:b:v:" opt; do
    case $opt in
    h)
        echo '
    -s  source repo url, like "https://github.com/{owner}/{repo}"
    -t  target group url, like "http://127.0.0.1/{group}"
    -b  branch, specifies which branch to traverse, like "master", default "HEAD"
                if not set, migrate all branches
    -v  visibility level, like "public", default "public"
        '
        exit 0
        ;;
    s)
        SRC_URL=$OPTARG
        ;;
    t)
        TAR_URL=$OPTARG
        ;;
    b)
        BRANCH=$OPTARG
        ;;
    v)
        VIS_LEVEL=$OPTARG
        ;;
    :)
        exit 1
        ;;
    ?)
        exit 1
        ;;
    esac
done

##### Parse URL #####
read SRC_PROTO SRC_HOST SRC_OWNER SRC_NAME <<<$(_parse_url $SRC_URL)
read TAR_PROTO TAR_HOST TAR_GROUP <<<$(_parse_url $TAR_URL)
TAR_GROUP_ID=$(_get_group $TAR_GROUP)

if [ -z "$BRANCH" ]; then
    print_log "===================== Mirror All Branches ====================="
    echo 'src = ['$SRC_PROTO'] ['$SRC_HOST'] ['$SRC_OWNER'] ['$SRC_NAME']
tar = ['$TAR_PROTO'] ['$TAR_HOST'] ['$TAR_GROUP']
branches:
'"$(_get_github_branches)"'' | tee $CWD/migrate.log
    _get_github_branches | while read branch; do
        BRANCH=$branch
        print_log "===================== Migrate & Link Branch $BRANCH ====================="
        ##### Migrate #####
        _migrate $SRC_OWNER $SRC_NAME $BRANCH
        ##### Link #####
        # _linkmodules $SRC_OWNER $SRC_NAME $BRANCH
    done
    # _get_github_branches | while read branch; do
    #     BRANCH=$branch
    #     print_log "===================== Verify Branch $BRANCH ====================="
    #     _verify $SRC_OWNER $SRC_NAME $BRANCH
    # done
else
    print_log "===================== Mirror Branch $BRANCH ====================="
    echo '  src = ['$SRC_PROTO'] ['$SRC_HOST'] ['$SRC_OWNER'] ['$SRC_NAME']
    tar = ['$TAR_PROTO'] ['$TAR_HOST'] ['$TAR_GROUP']' | tee $CWD/migrate.log
    ##### Migrate #####
    _migrate $SRC_OWNER $SRC_NAME $BRANCH
    ##### Link #####
    _linkmodules $SRC_OWNER $SRC_NAME $BRANCH
    ##### Verify #####
    _verify $SRC_OWNER $SRC_NAME $BRANCH
fi
