#!/bin/bash

function print_job() {
    # param: log message
    DATE=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "\033[34m$DATE [INFO]\033[0m $1"
}

function print_log() {
    # param: log message
    DATE=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "\033[32m$DATE [INFO]\033[0m $1"
}

function print_error() {
    # param: log message
    DATE=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "\033[31m$DATE [ERROR]\033[0m $1"
}

function get_github_repo_info() {
    # input repo full name, like "ClickHouse/ClickHouse"
    # output repo info, like "{"id": "660841205", "name": "ClickHouse"}"
    # reference: https://docs.github.com/en/rest/repos/repos?apiVersion=2022-11-28#get-a-repository
    echo $(
        curl --silent --request GET \
            --header "Accept: application/vnd.github+json" \
            --header "Authorization: Bearer $GITHUB_TOKEN" \
            --header "X-GitHub-pi-Version: 2022-11-28" \
            --url https://api.github.com/repos/$1
    )
}

function get_gitlab_proj_info() {
    # input proj full name, like "migrate-test/ClickHouse"
    # output proj info, like "{"id": "46", "name": "ClickHouse"}"
    # reference: https://docs.gitlab.com/ee/api/projects.html#get-single-project
    proj_full_name=$(echo $1 | sed 's/\//%2F/g')
    echo $(
        curl --silent --request GET \
            --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            --header "Content-Type: application/json" \
            --url "$TAR_HOST/api/v4/projects/$proj_full_name"
    )
}

function get_github_submodules() {
    # input repo full name, like "ClickHouse/ClickHouse"
    #       branch, like "master"
    # output submodule url list
    # reference: https://docs.github.com/en/rest/repos/contents?apiVersion=2022-11-28#get-repository-content
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

function get_gitlab_submodules() {
    # input repo full name, like "migrate-test/ClickHouse"
    #       branch, like "master"
    # output submodule url list
    # reference: https://docs.github.com/en/rest/repos/contents?apiVersion=2022-11-28#get-repository-content
    proj_full_name=$(echo $1 | sed 's/\//%2F/g')
    echo "$(
        curl --silent --request GET \
            --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            --url "$TAR_HOST//api/v4/projects/$proj_full_name/repository/files/.gitmodules/raw?ref=$2" |
            sed 's/\t//g' |
            awk '{FS="submodule \"| = "}{
                if($1=="["){printf "\n"}
                else if($1=="url"){printf $2}
                else if($1=="branch"){printf " " $2}
                } END {printf "\n"}'
    )"
}

function recursive_migrate() {
    # input src repo url, like "https://github.com/ClickHouse/ClickHouse"
    #       branch, like "master"

    # get source informations
    src_url=$(echo $1 | sed -e 's/\.git//g')
    branch=$2
    src_full_name=$(echo $src_url | sed -e 's/https*:\/\/github.com\///g')
    src_info=$(get_github_repo_info $src_full_name)
    src_id=$(echo $src_info | jq .id)
    src_name=$(echo $src_info | jq .name | sed 's/\"//g')
    # get target informations
    tar_name=$src_name
    tar_full_name=$TAR_GROUP/$tar_name
    tar_info=$(get_gitlab_proj_info $tar_full_name)
    tar_id=$(echo $tar_info | jq .id)
    tar_url=$TAR_HOST/$TAR_GROUP/$tar_name

    # recursive migrate submodules
    get_github_submodules $src_full_name $branch | while read -a submodule; do
        sub_url=${submodule[0]}
        sub_branch=${submodule[1]}
        if [ -z $sub_url ]; then
            continue
        elif [ -z $sub_branch ]; then
            sub_branch="HEAD"
        fi
        sub_branch=${sub_branch##*/}
        recursive_migrate $sub_url $sub_branch
    done

    local_path=$CWD/$src_name
    print_job "migrate from $local_path to $tar_url"
    if [ ! -d $local_path ]; then
        # if local repo not exist, clone
        print_log "local repo not exist, clone from $src_url"
        git clone $src_url $local_path
        cd $local_path && rm -rf .git/
        git clone --mirror $src_url .git
    else
        # if local repo already exist, pull
        print_log "local repo already exist, pull from $src_url"
        cd $local_path
        git pull origin
    fi
    
    if [ $tar_id == "null" ]; then
        print_log "create gitlab project $tar_url"
        curl --silent --request POST \
            --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            --header "Content-Type: application/json" \
            --url "$TAR_HOST/api/v4/projects/" \
            --data '{
            "name": "'$tar_name'",
            "namespace_id": "'$TAR_GROUP_ID'"
        }' &> /dev/null
    fi

    # push to target project
    tar_proto=${tar_url%%://*}
    tar_host=$(echo $TAR_HOST | sed -e 's/'$tar_proto':\/\///g')
    tar_url_with_token=$tar_proto://auth2:$GITLAB_TOKEN@$tar_host/$TAR_GROUP/$tar_name.git
    cd $local_path
    git remote rm gitlab &> /dev/null
    git remote add gitlab $tar_url_with_token
    git push --force gitlab --all
    cd $CWD
}

function link_submodules() {
    # input tar proj url, like "http://127.0.0.1/migrate-test/ClickHouse"
    #       branch, like "master"
    # reference: https://docs.gitlab.com/ee/api/repository_files.html#update-existing-file-in-repository

    # get target informations
    tar_url=$(echo $1 | sed -e 's/\.git//g')
    branch=${2##*/}
    tar_name=${tar_url##*/}
    tar_proto=${tar_url%%://*}
    tar_group_url=${tar_url%/*}
    tar_group=${tar_group_url##*/}
    tar_host=$(echo $tar_group_url | sed -e 's/'$tar_proto':\/\///g' -e 's/\/'$tar_group'//g')
    tar_full_name=$tar_group/$tar_name
    tar_info=$(get_gitlab_proj_info $tar_full_name)
    tar_id=$(echo $tar_info | jq .id)

    if [ $tar_id == "null" ]; then
        print_error "project $tar_url not exists"
    else
        # recursive link submodules
        get_gitlab_submodules $tar_full_name $branch | while read -a submodule; do
            sub_url=${submodule[0]}
            sub_branch=${submodule[1]}
            if [ -z $sub_url ]; then
                continue
            elif [ -z $sub_branch ]; then
                sub_branch="HEAD"
            fi
            sub_url=$(echo $sub_url | sed -e 's/https*:\/\/github.com\/[^\/]*\//'$tar_proto':\/\/'$tar_host'\/'$tar_group'\//g')
            sub_branch=${sub_branch##*/}
            link_submodules $sub_url $sub_branch
        done
        print_job "update .gitmodules for $tar_url"
        # build .gitmodules
        submodule_status=$(
            curl --silent -w %{http_code} -o /dev/null --request GET \
                --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
                --url "$tar_proto://$tar_host/api/v4/projects/$tar_id/repository/files/.gitmodules/raw?ref=$branch"
        )
        if [ $submodule_status != "404" ]; then
            old_links=$(
                curl --silent --request GET \
                    --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
                    --url "$tar_proto://$tar_host/api/v4/projects/$tar_id/repository/files/.gitmodules/raw?ref=$branch"
            )
            new_links=$(
                echo "$old_links" |
                    sed -e 's/https*:\/\/github.com\/[^\/]*\//'$tar_proto':\/\/'$tar_host'\/'$tar_group'\//g' |
                    base64
            )
            # update .gitmodules
            message=$(
                curl --silent --request PUT \
                    --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
                    --header "Content-Type: application/json" \
                    --url "$tar_proto://$tar_host/api/v4/projects/$tar_id/repository/files/.gitmodules" \
                    --data '{
                    "branch": "'$branch'",
                    "content": "'$new_links'",
                    "commit_message": "update .gitmodules",
                    "encoding": "base64"
                }' | jq .message | sed -e 's/\"//g'
            )
            print_log "update success"
        else
            print_log "don't have .gitmodules"
        fi
    fi
}

while getopts "s:t:b:" opt; do
    case $opt in
    h)
        echo '
    -s  source repo url, like "https://github.com/{owner}/{repo}"
    -t  target proj url, like "http://127.0.0.1/{group}"
    -b  branch, like "master", default HEAD
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
    :)
        exit 1
        ;;
    ?)
        exit 2
        ;;
    esac
done

TAR_HOST=${TAR_URL%/*}
TAR_GROUP=${TAR_URL##*/}
TAR_GROUP_ID=$(
    curl --silent --request GET \
        --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        --url "$TAR_HOST/api/v4/groups/$TAR_GROUP" |
        jq .id
)
CWD=$(pwd)

echo "################## Migrate ##################"
recursive_migrate $SRC_URL $BRANCH
src_name=${SRC_URL##*/}
src_name=$(echo $src_name | sed -e 's/\.git//g')
echo "################## Update .gitmodules ##################"
link_submodules $TAR_URL/$src_name $BRANCH

# Todo: reset update and then pull and push
# Todo: add ssh auth for pull and push
