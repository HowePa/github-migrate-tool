#!/bin/bash

function get_handles() {
    TARGET_GROUP=${TARGET_URL##*/}
    TARGET_PROTO=${TARGET_URL%%://*}
    TARGET_HOST=$(echo $TARGET_URL | sed -e 's/'$TARGET_PROTO':\/\///g' -e 's/\/'$TARGET_GROUP'//g')
    TARGET_GROUP_ID=$(
        curl --silent --request GET \
            --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            --url "$TARGET_PROTO://$TARGET_HOST/api/v4/groups/$TARGET_GROUP" | jq .id
    )
}

function print_log() {
    # param: log message
    DATE=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "\033[34m$DATE [INFO]\033[0m $1"
}

function print_error() {
    # param: log message
    DATE=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "\033[31m$DATE [ERROR]\033[0m $1"
}

function get_github_repo_name() {
    # param: github repo url
    echo $(echo $1 | sed -e 's/https:\/\/github.com\///g' -e 's/.git//g')
}

function get_github_repo_id() {
    # param: github repo name
    api_handle="https://api.github.com/repos/$1"
    id=$(
        curl --silent --request GET \
            --url $api_handle \
            --header "Authorization: Bearer $GITHUB_TOKEN" \
            --header "Accept: application/vnd.github+json" \
            --header "X-GitHub-Api-Version: 2022-11-28" |
            jq .id
    )
    echo $id
}

function get_github_repo_submodules() {
    # param: github repo name
    api_handle="https://api.github.com/repos/$1/contents/.gitmodules"
    content=$(
        curl --silent --request GET \
            --url $api_handle \
            --header "Authorization: Bearer $GITHUB_TOKEN" \
            --header "Accept: application/vnd.github+json" \
            --header "X-GitHub-Api-Version: 2022-11-28" |
            jq .content
    )
    if [ $content != "null" ]; then
        echo $content | sed -e 's/\"//g' -e 's/\\n//g' | base64 -d |
            grep https://github.com | awk 'BEGIN {FS=" = "}{printf $2 "\n"}'
    fi
}

function import_to_gitlab() {
    # param: github repo id
    api_handle="$TARGET_PROTO://$TARGET_HOST/api/v4/import/github"
    errors=$(
        curl --silent --request POST \
            --url $api_handle \
            --header "content-type: application/json" \
            --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            --data '{
            "personal_access_token": "'$GITHUB_TOKEN'",
            "repo_id": "'$1'",
            "target_namespace": "'$TARGET_GROUP'"
        }' | jq .errors | sed -e 's/\"//g'
    )
    if [ "$errors" != "null" ]; then
        print_error "$errors"
    fi
}

function online_recursive_migrate() {
    # param: github repo url
    source_repo=$1
    source_repo_name=$(get_github_repo_name $source_repo)
    # Recursive migrate submodules
    get_github_repo_submodules $source_repo_name | while read submodule; do
        online_recursive_migrate $submodule
    done
    # Import project from github
    print_log "post request import $source_repo"
    source_repo_id=$(get_github_repo_id $source_repo_name)
    import_to_gitlab $source_repo_id
}

function get_gitlab_proj_name() {
    # param: gitlab project url
    echo $(echo ${1##*/} | sed -e 's/.git//g')
}

function get_gitlab_proj_id() {
    # param: gitlab project name
    echo $(
        curl --silent --request GET \
            --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            --header "Content-Type: application/json" \
            --url "$TARGET_PROTO://$TARGET_HOST/api/v4/projects/$TARGET_GROUP%2F$1" |
            jq .id
    )
}

function get_gitlab_submodule_branch() {
    # param: gitlab project name or id, branch
    echo "$(
        curl --silent --request GET \
            --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            --url "$TARGET_PROTO://$TARGET_HOST//api/v4/projects/$1/repository/files/.gitmodules/raw?ref=$2" |
            sed 's/\t//g' |
            awk '{FS="submodule \"| = "}{
                if($1=="\["){printf "\n"}
                else if($1=="url"){printf $2}
                else if($1=="branch"){printf " " $2}
                } END {printf "\n"}'
    )"
}

function update_gitlab_submodule_url() {
    # param: gitlab project name or id
    new_content=$(
        curl --silent --request GET \
            --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            --url "$TARGET_PROTO://$TARGET_HOST/api/v4/projects/$1/repository/files/.gitmodules/raw?ref=$2" |
            sed -e 's/https:\/\/github.com\/[^\/]*\//'$TARGET_PROTO':\/\/'$TARGET_HOST'\/'$TARGET_GROUP'\//g' |
            base64
    )
    message=$(
        curl --silent --request PUT \
            --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            --header "Content-Type: application/json" \
            --url "$TARGET_PROTO://$TARGET_HOST/api/v4/projects/$1/repository/files/.gitmodules" \
            --data '{
                "branch": "'$2'", 
                "content": "'$new_content'", 
                "commit_message": "update .gitmodules",
                "encoding": "base64"
            }' | jq .message | sed -e 's/\"//g'
    )
    if [ "$message" != "null" ]; then
        print_error "$message"
    fi
}

function recursive_update() {
    # param: gitlab repo url, specifica branch
    source_proj=$1
    # Todo: normalized branch name
    branch=${2##*/}
    source_proj_name=$(get_gitlab_proj_name $source_proj)
    source_proj_id=$(get_gitlab_proj_id $source_proj_name)
    if [ $source_proj_id == "null" ]; then
        print_error "project $source_proj not exists"
    else
        # Recursive migrate submodules
        get_gitlab_submodule_branch $source_proj_id $branch | while read -a tmp; do
            submodule=${tmp[0]}
            branch=${tmp[1]}
            if [ -z $submodule ]; then
                continue
            elif [ -z $branch ]; then
                branch="master"
            fi
            recursive_update $submodule $branch
        done
        print_log "update project:$source_proj id:$source_proj_id branch:$branch"
        update_gitlab_submodule_url $source_proj_id $branch
    fi
}

function offline_recursive_migrate() {
    # param: github repo url
    source_repo=$1
    source_repo_name=$(get_github_repo_name $source_repo)
    # # Recursive migrate submodules
    get_github_repo_submodules $source_repo_name | while read submodule; do
        offline_recursive_migrate $submodule
    done
    new_proj_name=${source_repo_name##*/}
    test_id=$(get_gitlab_proj_id $new_proj_name)
    if [ $test_id != "null" ]; then
        print_error "project $TARGET_URL/$new_proj_name already exists"
    else
        # Stage 1: clone repo and update .gitmodule
        print_log "clone $source_repo"
        git clone $source_repo ./temp && cd temp
        # Stage 2: push to gitlab repo
        print_log "create gitlab project $TARGET_URL/$new_proj_name"
        message=$(
            curl --silent --request POST \
                --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
                --header "Content-Type: application/json" \
                --url "$TARGET_PROTO://$TARGET_HOST/api/v4/projects/" \
                --data '{
                "name": "'$new_proj_name'",
                "namespace_id": "'$TARGET_GROUP_ID'"
            }' | jq .message | sed -e 's/\"//g'
        )
        if [ "$message" != "null" ]; then
            print_error "$message"
        fi
        print_log "push to $TARGET_URL/$new_proj_name"
        git remote add gitlab $TARGET_URL/$new_proj_name
        git push -u gitlab --all
        cd .. && rm -rf ./temp
    fi
}

# Todo: keep local repo for regular sync remote repo 
function _offline_recursive_migrate() {
    # param: github repo url
    source_repo=$1
    source_repo_name=$(get_github_repo_name $source_repo)
    # # Recursive migrate submodules
    get_github_repo_submodules $source_repo_name | while read submodule; do
        offline_recursive_migrate $submodule
    done
    new_proj_name=${source_repo_name##*/}
    test_id=$(get_gitlab_proj_id $new_proj_name)
    if [ $test_id != "null" ]; then
        print_error "project $TARGET_URL/$new_proj_name already exists"
    else
        # Stage 1: clone repo and update .gitmodule
        print_log "clone $source_repo"
        local_repo_name=${source_repo_name##*/}
        git clone $source_repo && cd $local_repo_name
        # Stage 2: push to gitlab repo
        print_log "create gitlab project $TARGET_URL/$new_proj_name"
        message=$(
            curl --silent --request POST \
                --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
                --header "Content-Type: application/json" \
                --url "$TARGET_PROTO://$TARGET_HOST/api/v4/projects/" \
                --data '{
                "name": "'$new_proj_name'",
                "namespace_id": "'$TARGET_GROUP_ID'"
            }' | jq .message | sed -e 's/\"//g'
        )
        if [ "$message" != "null" ]; then
            print_error "$message"
        fi
        print_log "push to $TARGET_URL/$new_proj_name"
        git remote add gitlab $TARGET_URL/$new_proj_name
        git push gitlab --all
        cd ..
    fi
}

function _recursive_sync() {
    # check update
    git fetch origin
    # merge update
    git merge origin/$branch
    # push to gitlab
    git push gitlab --all
}

SOURCE_REPO="null"
TARGET_URL="null"
TARGET_GROUP="null"
TARGET_PROTO="null"
TARGET_HOST="null"
TARGET_GROUP_ID="null"
TARGET_BRANCH="master"

while getopts "hfnus:t:b:" opt; do
    case $opt in
    h)
        echo '
    -f  offline mode
    -n  online mode
    -u  update .gitmodules for gitlab project and its submodules
    -s  source repo url, like "https://github.com/XXX/XXX.git"
    -t  target group url, like "http://127.0.0.1/XXX" for online and "http://127.0.0.1/XXX/XXX.git" for update
    -b  specifica branch for update, default as "master"
        '
        exit 0
        ;;
    f)
        HANDLE="offline"
        ;;
    n)
        HANDLE="online"
        ;;
    u)
        HANDLE="update"
        ;;
    s)
        SOURCE_REPO=$OPTARG
        ;;
    t)
        TARGET_URL=$OPTARG
        ;;
    b)
        TARGET_BRANCH=$OPTARG
        ;;
    :)
        exit 1
        ;;
    ?)
        exit 2
        ;;
    esac
done

# Todo: offline mode: keep local repos
# Todo: online mode: test mirror
# Todo: recursive migrate from .gitmodules branch, if each branch has different submodules
# Todo: if master branch not named 'master'
# Todo: warn log

case $HANDLE in
offline)
    if [ $SOURCE_REPO == "null" ]; then
        print_error "offline migration miss source repo url"
        exit 3
    fi
    if [ $TARGET_URL == "null" ]; then
        print_error "offline migration miss target group url"
        exit 3
    fi
    get_handles
    print_log "migrate offline from $SOURCE_REPO to $TARGET_URL"
    offline_recursive_migrate $SOURCE_REPO
    ;;
online)
    if [ $SOURCE_REPO == "null" ]; then
        print_error "online migration miss source repo url"
        exit 3
    fi
    if [ $TARGET_URL == "null" ]; then
        print_error "online migration miss target group url"
        exit 3
    fi
    get_handles
    print_log "migrate online from $SOURCE_REPO to $TARGET_URL"
    online_recursive_migrate $SOURCE_REPO
    ;;
update)
    if [ $TARGET_URL == "null" ]; then
        print_error "update miss target group url"
        exit 3
    fi
    root_proj_url=$TARGET_URL
    TARGET_URL=${root_proj_url%/*}
    get_handles
    print_log "update .gitmodules for $root_proj_url"
    recursive_update $root_proj_url $TARGET_BRANCH
    ;;
esac
