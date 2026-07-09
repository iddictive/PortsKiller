#!/bin/bash

set -e

function default_portskiller_version() {
    echo "0.1.0"
}

function version_sort_key() {
    local version=${1#v}
    local major
    local minor
    local patch

    IFS='.' read -r major minor patch _ <<< "$version"

    if [[ ! "$major" =~ ^[0-9]+$ ]]; then
        major=0
    fi
    if [[ ! "$minor" =~ ^[0-9]+$ ]]; then
        minor=0
    fi
    if [[ ! "$patch" =~ ^[0-9]+$ ]]; then
        patch=0
    fi

    printf "%08d.%08d.%08d\n" "$major" "$minor" "$patch"
}

function max_portskiller_version() {
    local first=${1#v}
    local second=${2#v}

    if [ -z "$first" ]; then
        echo "$second"
        return
    fi
    if [ -z "$second" ]; then
        echo "$first"
        return
    fi

    if [[ "$(version_sort_key "$second")" > "$(version_sort_key "$first")" ]]; then
        echo "$second"
    else
        echo "$first"
    fi
}

function next_portskiller_version() {
    local current=${1#v}
    local major
    local minor
    local patch

    IFS='.' read -r major minor patch _ <<< "$current"

    if [[ ! "$major" =~ ^[0-9]+$ ]]; then
        echo "$(default_portskiller_version)"
        return
    fi
    if [[ ! "$minor" =~ ^[0-9]+$ ]]; then
        minor=0
    fi

    echo "$major.$((minor + 1)).0"
}

function latest_portskiller_tag_version() {
    git tag -l 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null \
        | sed 's/^v//' \
        | awk -F. '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ { print }' \
        | sort -t. -k1,1n -k2,2n -k3,3n \
        | tail -n 1
}

function current_portskiller_version() {
    if [ -n "${PORTSKILLER_VERSION:-}" ]; then
        echo "$PORTSKILLER_VERSION"
    else
        default_portskiller_version
    fi
}

function next_release_version() {
    local current
    local latest_tag
    local base

    current="$(current_portskiller_version)"
    latest_tag="$(latest_portskiller_tag_version)"
    base="$(max_portskiller_version "$current" "$latest_tag")"

    if [ -z "$base" ]; then
        base="$(default_portskiller_version)"
    fi

    if [ "$base" = "$current" ] && [ -n "$latest_tag" ] && [[ "$(version_sort_key "$current")" > "$(version_sort_key "$latest_tag")" ]]; then
        echo "$current"
    else
        next_portskiller_version "$base"
    fi
}

function resolve_portskiller_version() {
    if [ -n "${PORTSKILLER_VERSION:-}" ]; then
        echo "$PORTSKILLER_VERSION"
    elif [ "${PORTSKILLER_BUMP_VERSION:-0}" = "1" ]; then
        next_release_version
    else
        current_portskiller_version
    fi
}
