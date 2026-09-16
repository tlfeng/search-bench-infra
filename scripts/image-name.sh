#!/bin/bash
# 镜像命名规则（唯一事实来源）：build-image.sh 构建新镜像、image.sh fix-names
# 修正存量镜像名，都调用这里的 compose_image_name，保证两边起的名字一致。
#
#   es:    {prefix}-{es|ez}-{引擎版本}-{arch}
#   rally: {prefix}-rally-{esrally版本}-{arch}[-corpus]
#
# 版本留空时取默认（es=default 占位、rally=2.12.0，与 install.sh 的 RALLY_VERSION 一致）；
# prefix 里已经带「-{版本}」段时不再追加，避免名字里出现两段版本号。

compose_image_name() {
  local prefix=$1 role=$2 engine=$3 version=$4 arch=$5 corpus=$6
  local name
  if [ "$role" = "es" ]; then
    local tok="es"
    if [ "$engine" = "easysearch" ]; then tok="ez"; fi
    if [ -n "$version" ] \
       && case "$prefix" in *"-$version"-* | *"-$version") true ;; *) false ;; esac; then
      name="${prefix}-${arch}"
    else
      name="${prefix}-${tok}-${version:-default}-${arch}"
    fi
  else
    local rv="${version:-2.12.0}"
    if case "$prefix" in *"-$rv"-* | *"-$rv") true ;; *) false ;; esac; then
      name="${prefix}-${arch}"
    else
      name="${prefix}-rally-${rv}-${arch}"
    fi
    if [ -n "$corpus" ]; then name="${name}-corpus"; fi
  fi
  printf '%s' "$name"
}
