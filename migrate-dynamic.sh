#!/bin/bash

function print_hit() {
    DATE=$(date "+%Y-%m-%d %H:%M:%S")
    printf "\033[32m${DATE} [INFO]\033[0m $1\n"
}

function print_miss() {
    DATE=$(date "+%Y-%m-%d %H:%M:%S")
    printf "\033[34m${DATE} [INFO]\033[0m $1\n"
}

function func() { # Input(work_dir)
    local work_dir=$1
    local sub_sha1 sub_name sub_info
    local base_dir=$(pwd)
    pushd $work_dir >/dev/null
    git submodule status | grep -v \\./ | while read sub_sha1 sub_path sub_info; do
        local sub_url=$(git config -f .gitmodules --get submodule.$sub_path.url)
        local sub_name=$(echo ${sub_url##*/} | sed 's/.git//g')
        local sub_owner=${sub_url%/*}
        sub_owner=${sub_owner##*/}
        sub_sha1=$(echo $sub_sha1 | sed 's/-//g')
        # migrate to gitlab ?
        local sub_proj_id=$(
            curl --silent --location --request GET \
                --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
                --header "Content-Type: application/json" \
                --url "${GITLAB_HOST}/api/v4/projects/${DEPS_GROUP}%2F${sub_owner}%2F${sub_name}" |
                jq -r .id
        )
        # need to update ?
        local sub_proj_sha1=$(
            curl --silent --location --request GET \
                --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
                --url "${GITLAB_HOST}/api/v4/projects/${sub_proj_id}/repository/commits/${sub_sha1}" |
                jq -r .id 
        )
        if [ "$sub_proj_id" != "null" ] && [ "$sub_proj_sha1" != "null" ]; then
            print_log "find deps at ${GITLAB_HOST}/${DEPS_GROUP}/${sub_owner}/${sub_name}"
            # replace
            git submodule --quiet set-url $sub_path ${GITLAB_HOST}/${DEPS_GROUP}/${sub_owner}/${sub_name}
            git submodule update --init $sub_path
        else
            print_miss "migrate deps to ${GITLAB_HOST}/${DEPS_GROUP}/${sub_owner}/${sub_name}"
            # migrate or update
            git submodule update --init $sub_path
            # new project
            local sub_group_id=$(
                curl --silent --location --request GET \
                    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
                    --url "${GITLAB_HOST}/api/v4/groups/${DEPS_GROUP}%2F${sub_owner}" |
                    jq -r .id
            )
            if [ "$sub_group_id" == "null" ]; then
                sub_group_id=$(
                    curl --silent --location --request POST \
                        --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
                        --header "Content-Type: application/json" \
                        --url "${GITLAB_HOST}/api/v4/groups/" \
                        --data '{
                            "path": "'${sub_owner}'",
                            "name": "'${sub_owner}'",
                            "parent_id": '${DEPS_GROUP_ID}'
                        }' | jq -r .id
                )
            fi
            sub_proj_id=$(
                curl --silent --location --request POST \
                    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
                    --header "Content-Type: application/json" \
                    --url "${GITLAB_HOST}/api/v4/projects/" \
                    --data '{
                        "name": "'${sub_name}'",
                        "namespace_id": "'${sub_group_id}'",
                        "lfs_enabled": "true"
                    }' | jq -r .id
            )
            # push to gitlab
            pushd $sub_path >/dev/null
            git push --force ${GITLAB_HOST}/${DEPS_GROUP}/${sub_owner}/${sub_name} HEAD:refs/heads/_${sub_sha1}
            popd >/dev/null
        fi
        func ${work_dir}/${sub_path}
    done
    popd >/dev/null
}

DEPS_GROUP_ID=$(
    curl --silent --location --request GET \
        --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        --url "${GITLAB_HOST}/api/v4/groups/${DEPS_GROUP}" |
        jq .id
)
func $1
