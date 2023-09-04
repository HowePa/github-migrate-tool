#!/bin/bash

function print_log() {
    DATE=$(date "+%Y-%m-%d %H:%M:%S")
    printf "\033[32m${DATE} [INFO]\033[0m $1\n"
}

function print_debug() {
    DATE=$(date "+%Y-%m-%d %H:%M:%S")
    printf "\033[34m${DATE} [INFO]\033[0m $1\n"
}

function _parse_url() { # Input(url) Return(proto, host, [group], owner, name)
    echo "$(echo "$1" | awk 'BEGIN{FS="://|/|.git"}{print $1" "$2" "$3" "$4" "$5}')"
}

function _schedule() { # Input(from:owner/name, to:group, ref)

    function _parse_submodule() { # Input(repo:owner/name, ref) Return(path, url)
        echo "$(
            curl --silent --location --request GET \
                --header "Authorization: Bearer ${GITHUB_TOKEN}" \
                --header "Accept: application/vnd.github.raw+json" \
                --header "X-GitHub-Api-Version: 2022-11-28" \
                --url https://api.github.com/repos/${1}/contents/.gitmodules?ref=${2} |
                sed -e 's/\t//g' -e 's/ //g' |
                awk '{ORS=" "}{FS="\"|="}{
                if($1=="[submodule"){printf "\n"}
                else if($1=="path"){print $2}
                else if($1=="url"){print $2}
                } END {printf "\n"}'
        )"
    }

    function _get_ref() { # Input(repo:owner/name, path, ref) Return(ref(commit_sha))
        echo "$(
            curl --silent --location --request GET \
                --header "Authorization: Bearer ${GITHUB_TOKEN}" \
                --header "Accept: application/vnd.github.raw+json" \
                --header "X-GitHub-Api-Version: 2022-11-28" \
                --url https://api.github.com/repos/${1}/contents/${2}?ref=${3} |
                jq -r .sha
        )"
    }

    function _recursive_schedule() { # Input(from:owner/name, to:group, ref, level)
        local _from=$1 _to=$2 _ref=$3 _level=$4
        print_log "%${_level}s%${_level}s |-> <${_from}:${_ref}>"
        ##### recursive travel submodule
        local _sub_path _sub_url
        _parse_submodule $_from $_ref | while read _sub_path _sub_url; do
            if [ ! -z "$_sub_path" ]; then
                local _sub_ref=$(_get_ref $_from $_sub_path $_ref)
                local _sub_owner _sub_name
                read _ _ _sub_owner _sub_name <<<$(_parse_url $_sub_url)
                _recursive_schedule $_sub_owner/$_sub_name $_to $_sub_ref $(expr $_level + 1)
            fi
        done
        ##### write schedule log
        local _last_level=$(tail -n 1 $SCHEDULE_LOG)
        local _is_leaf="-"
        if [ ! -z "$_last_level" ] && [ $_level -lt ${_last_level%%:*} ]; then
            _is_leaf="+"
        fi
        echo "${_level}:${_from}:${_to}/${_from}:${_ref}:${_is_leaf}" >>$SCHEDULE_LOG
    }

    local _ref=$3 _schedule_f=$(cat $SCHEDULE_LOG | grep ":${1}:${2}:${1}:${_ref}:")
    if [ ! -z "$_schedule_f" ]; then
        print_log "refresh schedule for ref <${1}:$_ref> ..."
    else
        print_log "creating schedule for ref <${1}:$_ref> ..."
    fi
    _recursive_schedule $1 $2 $_ref 0
}

function _get_project() { # Input(repo:[group/]owner/name) Return(id)
    local _norm=${1//\//%2F}
    echo "$(
        curl --silent --location --request GET \
            --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
            --header "Content-Type: application/json" \
            --url "${TAR_HOST}/api/v4/projects/${_norm}" |
            jq .id
    )"
}

function _get_group() { # Input(group[/owner]) Return(id)
    local _norm=${1//\//%2F}
    echo "$(
        curl --silent --location --request GET \
            --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
            --url "${TAR_HOST}/api/v4/groups/${_norm}" |
            jq .id
    )"
}

function _migrate() {

    function _create_project() { # Input(repo:name, group:id) Return(id)
        echo "$(
            curl --silent --location --request POST \
                --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
                --header "Content-Type: application/json" \
                --url "${TAR_HOST}/api/v4/projects/" \
                --data '{
                    "name": "'${1}'",
                    "namespace_id": "'${2}'",
                    "lfs_enabled": "true",
                    "visibility": "'${VIS_LEVEL}'"
                }' | jq .id
        )"
    }

    function _create_subgroup() { # Input(subgroup:group/owner) Return(id)
        local _parent_id=$(_get_group ${1%/*})
        echo "$(
            curl --silent --location --request POST \
                --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
                --header "Content-Type: application/json" \
                --url "${TAR_HOST}/api/v4/groups/" \
                --data '{
                    "path": "'${1#*/}'",
                    "name": "'${1#*/}'",
                    "parent_id": '${_parent_id}',
                    "visibility": "'${VIS_LEVEL}'"
                }'
        )"
    }

    function _get_default_branch() { # Input(repo:owner/name) Return(branch)
        echo "$(
            curl --silent --location --request GET \
                --header "Authorization: Bearer ${GITHUB_TOKEN}" \
                --header "Accept: application/vnd.github.raw+json" \
                --header "X-GitHub-Api-Version: 2022-11-28" \
                --url https://api.github.com/repos/${1} |
                jq -r .default_branch
        )"
    }

    ##### travel schedule
    print_log "migrating ..."
    local _level _from _to _ref _link_f
    echo "$(cat $SCHEDULE_LOG | sed -e 's/:/ /g')" |
        while read _level _from _to _ref _link_f; do
            local _migrate_f=$(cat $MIGRATE_LOG | grep "${_from}:${_to}")
            ##### remote repo
            local _proj_id _group_id
            _proj_id=$(_get_project $_to)
            if [ "$_proj_id" == "null" ]; then
                _group_id=$(_get_group ${_to%/*})
                if [ "$_group_id" == "null" ]; then
                    _group_id=$(_create_subgroup ${_to%/*})
                fi
                _proj_id=$(_create_project ${_to##*/} $_group_id)
            fi
            ##### local repo
            # Todo: error handling
            local _local_repo="${WORK_DIR}/${_from}"
            if [ -d "$_local_repo" ]; then
                ##### local repo already exists
                cd $_local_repo
                local _update_f=$(git show $_ref 2>/dev/null) # search commit in local repo
                ##### need refresh repo || need pull new commit
                if [ -z "$_migrate_f" ] || [ -z "$_update_f" ]; then
                    print_log "updating repo <${_to}> ..."
                    git remote update
                    git push --force --all "${TAR_HOST}/${_to}"
                fi
                cd - >/dev/null
            else
                print_log "initializing repo <${_to}> ..."
                ##### local repo not exists, clone
                git clone --mirror "${SRC_HOST}/${_from}" $_local_repo
                cd $_local_repo
                local _lfs_f="$(git lfs ls-files)"
                if [ ! -z "$_lfs_f" ]; then
                    git lfs fetch --all "${SRC_HOST}/${_from}"
                    git lfs push --all "${TAR_HOST}/${_to}"
                fi
                git push --mirror --force "${TAR_HOST}/${_to}"
                ##### set default branch
                local _default_branch=$(_get_default_branch $_from)
                local _response=$(
                    curl --silent --location --request PUT \
                        --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
                        --url "${TAR_HOST}/api/v4/projects/${_proj_id}" \
                        --data "default_branch=${_default_branch}"
                )
                cd - >/dev/null
            fi
            ##### write migrate log
            if [ -z "$_migrate_f" ]; then
                echo "${_from}:${_to}" >>$MIGRATE_LOG
            fi
        done
}

function _link() {

    function _get_gitmodules() { # Input(repo:group/owner/name, ref) Return(content)
        local _proj_id=$(_get_project $1)
        echo "$(
            curl --silent --location --request GET \
                --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
                --url "${TAR_HOST}/api/v4/projects/${_proj_id}/repository/files/.gitmodules/raw?ref=${2}"
        )"
    }

    function _get_ref() { # Input(repo:group/owner/name, path, ref) Return(commit_sha)
        local _proj_id=$(_get_project $1)
        echo "$(
            curl --silent --location --request GET \
                --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
                --header "Content-Type: application/json" \
                --url "${TAR_HOST}/api/v4/projects/${_proj_id}/repository/files/${2//\//%2F}?ref=${3}" |
                jq -r .blob_id
        )"
    }

    function _clean() {
        local _response
        local _proj _origin_ref _new_ref
        print_log "cleaning old temp link branch ..."
        echo "$(cat $LINK_LOG | sed -e 's/:/ /g')" | while read _proj _origin_ref _new_ref; do
            local _proj_id=$(_get_project $_proj)
            _response=$(
                curl --silent --location --request DELETE \
                    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
                    --url "${TAR_HOST}/api/v4/projects/${_proj_id}/repository/branches/_${_origin_ref}"
            )
            print_log " |-> delete <${_proj}:_${_origin_ref}>"
        done
        cat /dev/null >$LINK_LOG
    }

    ##### travel schedule
    local _level _from _to _ref _link_f
    echo "$(cat $SCHEDULE_LOG | sed -e 's/:/ /g')" |
        while read _level _from _to _ref _link_f; do
            local _linked_f=$(cat $LINK_LOG | grep "${_to}:${_ref}")
            ##### non-leaf node && never linked ref
            if [ "$_link_f" == "+" ] && [ -z "$_linked_f" ]; then
                local _content=$(_get_gitmodules $_to $_ref)
                if [ ! -z "$_content" ]; then # maybe empty .gitmodules
                    print_log "linking submodules for <${_to}:${_ref}> ..."
                    ##### build new .gitmodules
                    local _new_content=$(
                        echo "$_content" |
                            sed -e 's/'https':\/\/'github.com'\//'${TAR_HOST%%://*}':\/\/'${TAR_HOST##*@}'\/'${_to%%/*}'\//g'
                    )
                    ##### update .gitmodules
                    local _proj_id=$(_get_project $_to) _response _branch
                    local _post_content=$(echo $(echo "$_new_content" | base64) | sed -e 's/ //g')
                    if [ $_level -eq 0 ]; then
                        #### case 1: if root node, directly update
                        ### step 1: update .gitmodules
                        _response=$(
                            curl --silent --location --request PUT \
                                --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
                                --header "Content-Type: application/json" \
                                --url "${TAR_HOST}/api/v4/projects/${_to//\//%2F}/repository/files/.gitmodules" \
                                --data '{
                                    "branch": "'${_ref}'",
                                    "content": "'${_post_content}'",
                                    "commit_message": "Update .gitmodules",
                                    "encoding": "base64"
                                }'
                        )
                        _branch="${_ref}"
                        print_log " |-> update .gitmodules for <${_to}:${_branch}>"
                        ### step 2: store ref reflection
                        echo "${_to}:${_ref}:${_ref}" >>$LINK_LOG
                    else
                        #### case 2: if mid node, update to temp link branch
                        ### step 1: delete old temp link branch
                        _response=$(
                            curl --silent --location --request DELETE \
                                --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
                                --url "${TAR_HOST}/api/v4/projects/${_proj_id}/repository/branches/_${_ref}"
                        )
                        ### step 2: create new temp link branch
                        _response=$(
                            curl --silent --request POST \
                                --form "branch=_${_ref}" \
                                --form "commit_message=temp link branch for commit <${_ref}>" \
                                --form "start_sha=${_ref}" \
                                --form "actions[][action]=update" \
                                --form "actions[][file_path]=.gitmodules" \
                                --form "actions[][content]=${_post_content}" \
                                --form "actions[][encoding]=base64" \
                                --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
                                "${TAR_HOST}/api/v4/projects/${_proj_id}/repository/commits" |
                                jq -r .id
                        )
                        _branch="_${_ref}"
                        print_log " |-> create temp link branch <${_to}:${_response}>"
                        print_log " |-> update .gitmodules for <${_to}:${_response}>"
                        ### step 3: store ref reflection
                        echo "${_to}:${_ref}:${_response}" >>$LINK_LOG
                    fi
                    ##### redirect submodules with new ref
                    local _child_path _child_url
                    echo "$_new_content" |
                        sed -e 's/\t//g' -e 's/ //g' |
                        awk '{ORS=" "}{FS="\"|="}{
                            if($1=="[submodule"){printf "\n"}
                            else if($1=="path"){print $2}
                            else if($1=="url"){print $2}
                            } END {printf "\n"}' | while read _child_path _child_url; do
                        local _child_proto _child_host _child_group _child_owner _child_name
                        read _child_proto _child_host _child_group _child_owner _child_name <<<$(_parse_url $_child_url)
                        local _child_ref=$(_get_ref $_to $_child_path $_branch)
                        local _child_new_ref=$(cat $LINK_LOG | grep "${_child_group}/${_child_owner}/${_child_name}:${_child_ref}")
                        if [ ! -z "$_child_new_ref" ]; then # a submodule with submodules
                            _response=$(
                                curl --silent --location --request PUT \
                                    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
                                    --url "${TAR_HOST}/api/v4/projects/${_proj_id}/repository/submodules/${_child_path//\//%2F}" \
                                    --data "branch=${_branch}&commit_sha=${_child_new_ref##*:}" |
                                    jq -r .message
                            )
                            print_log " *-> redirect $_child_path to <${_child_new_ref##*:}>"
                        fi
                    done
                fi
            fi
        done
}

function _main() { # Input(from:url, to:url, ref:branch)

    function _get_refs() { # Input(repo:owner/name) Return(branches/commit_sha)
        local _next_refs _page=0 _refs=""
        while true; do
            let _page++
            _next_refs=$(
                curl --silent --location --request GET \
                    --header "Authorization: Bearer ${GITHUB_TOKEN}" \
                    --header "Accept: application/vnd.github.raw+json" \
                    --header "X-GitHub-Api-Version: 2022-11-28" \
                    --url https://api.github.com/repos/${1}/branches?page=${_page} |
                    jq -r '.[] | .name'
            )
            if [ -z "$_next_refs" ]; then
                break
            fi
            _refs=$(echo -e "${_refs}\n${_next_refs}")
        done
        echo "$(sed '1d' <<<"$_refs")"
    }

    ##### parse url
    local _src_proto _src_host _owner _name
    read _src_proto _src_host _owner _name <<<$(_parse_url $1)
    local _tar_proto _tar_host _group
    read _tar_proto _tar_host _group <<<$(_parse_url $2)
    SRC_HOST="${_src_proto}://oauth2:${GITHUB_TOKEN}@${_src_host}"
    TAR_HOST="${_tar_proto}://oauth2:${GITLAB_TOKEN}@${_tar_host}"
    ##### initial workspace
    WORK_DIR="$(pwd)"
    META_DIR="${WORK_DIR}/.migrate_log"
    if [ ! -d $META_DIR ]; then
        mkdir $META_DIR
    fi
    LOG_DIR="${META_DIR}/${_owner}_${_name}"
    if [ ! -d $LOG_DIR ]; then
        mkdir $LOG_DIR
    fi
    VIS_LEVEL="public"
    ##### MIGRATE_LOG record repos already migrate
    #---- <src_repo>:<tar_repo>
    MIGRATE_LOG="${LOG_DIR}/m_${_group}_${_owner}_${_name}"
    touch $MIGRATE_LOG
    ##### LINK_LOG record temp branches built for keep link
    #---- <tar_repo>:<branch/old_commit_sha>:<branch/new_commit_sha>
    LINK_LOG="${LOG_DIR}/l_${_group}_${_owner}_${_name}"
    touch $LINK_LOG
    local _ref=$3
    if [ ! -z $_ref ]; then
        SCHEDULE_LOG="${LOG_DIR}/s_${_group}_${_owner}_${_name}_${_ref//\//-}"
        touch $SCHEDULE_LOG
        _schedule "${_owner}/${_name}" $_group $_ref
        _migrate
        _link
    else
        _get_refs "${_owner}/${_name}" | while read _ref; do
            ##### SCHEDULE_LOG record migration plan
            #---- <tree_level>:<src_repo>:<tar_repo>:<branch/commit_sha>:<is_leaf(need_link)>
            SCHEDULE_LOG="${LOG_DIR}/s_${_group}_${_owner}_${_name}_${_ref//\//-}"
            touch $SCHEDULE_LOG
            _schedule "${_owner}/${_name}" $_group $_ref
            _migrate
            _link
        done
    fi
}

while getopts "hs:t:b:" opt; do
    case $opt in
    h)
        echo '
    -s  source repo url, like "https://github.com/{owner}/{repo}"
    -t  target group url, like "http://127.0.0.1/{group}"
    -b  branch, like "master"
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
        TAR_REF=$OPTARG
        ;;
    *)
        exit 1
        ;;
    esac
done

_main $SRC_URL $TAR_URL $TAR_REF
