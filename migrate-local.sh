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

function _get_project() { # Input(proj_full_name) Return(proj_id)
    norm=$(echo "$1" | sed 's/\//%2F/g')
    echo "$(
        curl --silent --request GET \
            --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            --header "Content-Type: application/json" \
            --url "$TAR_HOST/api/v4/projects/$norm" |
            jq .id
    )"
}

function _get_group() { # Input(group_full_name) Return(group_id)
    norm=$(echo "$1" | sed 's/\//%2F/g')
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
            "lfs_enabled": "true"
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
            "parent_id": '$2'
        }' | jq .id
    )"
}

function _parse_url() { # Input(url) Return(proto, host, [owner, name, group])
    echo "$(echo "$1" | awk 'BEGIN{FS="://|/|.git"}{print $1" "$2" "$3" "$4" "$5}')"
}

function _get_default_branch() { # Input(repo_full_name) Return(default_branch)
    _response=$(
        curl --silent --request GET \
            --url https://api.github.com/repos/$1 \
            --header "Authorization: Bearer $GITHUB_TOKEN" \
            --header "Accept: application/vnd.github.raw+json" \
            --header "X-GitHub-Api-Version: 2022-11-28"
    )
    _branch=$(echo "$_response" | jq -r .default_branch)
    if [ "$_branch" == "null" ]; then
        _url=$(echo "$_response" | jq -r .url)
        _branch=$(
            curl --silent --request GET \
                --url $_url \
                --header "Authorization: Bearer $GITHUB_TOKEN" \
                --header "Accept: application/vnd.github.raw+json" \
                --header "X-GitHub-Api-Version: 2022-11-28" |
                jq -r .default_branch
        )
    fi
    echo "$_branch"
}

function _get_github_submodules() { # Input(repo_full_name, branch) Return([submodule_url, submodule_branch])
    echo "$(
        curl --silent --request GET \
            --url https://api.github.com/repos/$1/contents/.gitmodules?ref=$2 \
            --header "Authorization: Bearer $GITHUB_TOKEN" \
            --header "Accept: application/vnd.github.raw+json" \
            --header "X-GitHub-Api-Version: 2022-11-28" |
            sed 's/\t//g' |
            awk '{FS="submodule \"| = "}{
                if($1=="["){printf "\n"}
                else if($1=="url"){printf $2}
                else if($1=="branch"){printf " " $2}
                } END {printf "\n"}'
    )"
}

function _migrate() { # Input(src_owner, src_name, branch)
    _path=$1
    _name=$2
    _branch=$3
    ##### Recursively scan submodules #####
    _get_github_submodules $_path/$_name $_branch | while read _sub_url _sub_branch; do
        if [ -z "$_sub_url" ]; then
            continue
        elif [ -z "$_sub_branch" ]; then
            _sub_branch=$(_get_default_branch $_path/$_name)
        fi
        read _sub_proto _sub_host _sub_owner _sub_name <<<$(_parse_url "$_sub_url")
        _sub_branch=$(echo "$_sub_branch" | sed 's/blessed\///g')
        _migrate $_sub_owner $_sub_name $_sub_branch
    done

    ##### Clone or Pull repo #####
    _local_path=$CWD/$_path/$_name
    if [ ! -d "$_local_path" ]; then
        print_log "clone $SRC_PROTO://$SRC_HOST/$_path/$_name"
        git clone --mirror $SRC_PROTO://oauth2:$GITHUB_TOKEN@$SRC_HOST/$_path/$_name $_local_path 2>&1 | tee -a $CWD/migrate.log
    else
        print_log "update $_local_path"
        cd $_local_path &&
            git remote update 2>&1 | tee -a $CWD/migrate.log
    fi

    ##### Create subgroup or project #####
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

    ##### Push repo #####
    print_log "push $TAR_PROTO://$TAR_HOST/$TAR_GROUP/$_path/$_name"
    cd $_local_path
    _has_lfs=$(echo "$(git lfs ls-files)" | sed -e 's/ //g')
    if [ ! -z "$_has_lfs" ]; then
        echo "$CWD/$_path/$_name" >>$CWD/lfs.log
        git lfs fetch --all 2>&1 | tee -a $CWD/migrate.log &&
            git lfs push --all $TAR_PROTO://oauth2:$GITLAB_TOKEN@$TAR_HOST/$TAR_GROUP/$_path/$_name 2>&1 | tee -a $CWD/migrate.log
    else
        git push --mirror $TAR_PROTO://oauth2:$GITLAB_TOKEN@$TAR_HOST/$TAR_GROUP/$_path/$_name 2>&1 | tee -a $CWD/migrate.log
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
        if [ -z "$_sub_url" ]; then
            continue
        fi
        read _sub_proto _sub_host _sub_owner _sub_name <<<$(_parse_url $_sub_url)
        if [ -z "$_sub_branch" ]; then
            _sub_branch=$(_get_default_branch $_sub_owner/$_sub_name)
        fi
        _sub_branch=$(echo "$_sub_branch" | sed 's/blessed\///g')
        _linkmodules $_sub_owner $_sub_name $_sub_branch
    done

    ##### Link submodules #####
    _content=$(_get_gitmodules_content $TAR_GROUP/$_path/$_name $_branch)
    if [ ! -z "$_content" ] && [ "$_content" != "null" ]; then
        _new_content=$(echo "$(
            echo "$_content" | base64 -d |
                sed -e 's/'$SRC_PROTO':\/\/'$SRC_HOST'\//'$TAR_PROTO':\/\/'$TAR_HOST'\/'$TAR_GROUP'\//g' |
                base64
        )" | sed 's/ //g')
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
            print_error "link $TAR_PROTO://$TAR_HOST/$TAR_GROUP/$_path/$_name/-/blob/$_branch/.gitmodules"
        fi
    fi
}

function _get_gitlab_submodules() { # Input(proj_full_name, branch) Return([submodule_url, submodule_branch])
    norm=$(echo "$1" | sed 's/\//%2F/g')
    echo "$(
        curl --silent --request GET \
            --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            --url "$TAR_HOST//api/v4/projects/$norm/repository/files/.gitmodules/raw?ref=$2" |
            sed 's/\t//g' |
            awk '{FS="submodule \"| = "}{
                if($1=="["){printf "\n"}
                else if($1=="url"){printf $2}
                else if($1=="branch"){printf " " $2}
                } END {printf "\n"}'
    )"
}

function _visibility() { # Input(tar_subgroup, tar_name, branch, visibility)
    _path=$1
    _name=$2
    _branch=$3
    _level=$4
    ##### Recursively scan submodules #####
    _get_gitlab_submodules $TAR_GROUP/$_path/$_name $_branch | while read _sub_url _sub_branch; do
        if [ -z "$_sub_url" ]; then
            continue
        elif [ -z "$_sub_branch" ]; then
            _sub_branch=HEAD # Todo: get default branch
        fi
        read _sub_proto _sub_host _sub_group _sub_subgroup _sub_name <<<$(_parse_url $_sub_url)
        _sub_branch=$(echo "$_sub_branch" | sed -e 's/blessed\///g')
        _visibility $_sub_subgroup $_sub_name $_sub_branch $_level
    done

    ##### Change visibility #####
    _subgroup_id=$(_get_group $TAR_GROUP/$_path)
    curl --silent --request PUT \
        --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        --url "$TAR_PROTO://$TAR_HOST/api/v4/groups/$_subgroup_id" \
        --data "visibility=$_level" &>/dev/null
    _proj_id=$(_get_project $TAR_GROUP/$_path/$_name)
    _response=$(
        curl --silent --request PUT \
            --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            --url "$TAR_PROTO://$TAR_HOST/api/v4/projects/$_proj_id" \
            --data "visibility=$_level" |
            jq -r .visibility
    )
    if [ "$_response" != "$_level" ]; then
        print_log "visibility $TAR_PROTO://$TAR_HOST/$TAR_GROUP/$_path/$_name"
    else
        print_error "visibility $TAR_PROTO://$TAR_HOST/$TAR_GROUP/$_path/$_name"
    fi
}

function _get_branches() {
    echo "$(
        curl --silent --request GET \
            --url https://api.github.com/repos/$SRC_OWNER/$SRC_NAME/branches \
            --header "Authorization: Bearer $GITHUB_TOKEN" \
            --header "Accept: application/vnd.github.raw+json" \
            --header "X-GitHub-Api-Version: 2022-11-28" |
            jq -r '.[] | .name'
    )"
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
'"$(_get_branches)"'' | tee $CWD/migrate.log
    echo "$(_get_branches)" | tee $CWD/migrate.log
    # Todo: eliminate redundant operations
    _get_branches | while read branch; do
        BRANCH=$branch
        print_log "===================== Migrate Branch $BRANCH ====================="
        ##### Migrate #####
        _migrate $SRC_OWNER $SRC_NAME $BRANCH
    done
    _get_branches | while read branch; do
        BRANCH=$branch
        print_log "===================== Link Branch $BRANCH ====================="
        ##### Link #####
        _linkmodules $SRC_OWNER $SRC_NAME $BRANCH
        ##### Visibility & Verify #####
        _visibility $SRC_OWNER $SRC_NAME $BRANCH $VIS_LEVEL
    done
else
    print_log "===================== Mirror Branch $BRANCH ====================="
    echo '  src = ['$SRC_PROTO'] ['$SRC_HOST'] ['$SRC_OWNER'] ['$SRC_NAME']
    tar = ['$TAR_PROTO'] ['$TAR_HOST'] ['$TAR_GROUP']' | tee $CWD/migrate.log
    ##### Migrate #####
    _migrate $SRC_OWNER $SRC_NAME $BRANCH
    ##### Link #####
    _linkmodules $SRC_OWNER $SRC_NAME $BRANCH
    ##### Visibility & Verify #####
    _visibility $SRC_OWNER $SRC_NAME $BRANCH $VIS_LEVEL
fi

# Todo: 支持lfs、支持检测更新
# Todo: 排除重复link
# Todo: response 用双引号扩起来
# Todo: Simple breakpoint continuation
# Todo: Check update
