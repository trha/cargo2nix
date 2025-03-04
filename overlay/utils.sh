extractFileExt() {
    local name=`basename $1`
    echo ${name##*.}
}
extractHash() {
    local name=`basename $1`
    echo ${name%%-*}
}
makeExternCrateFlags() {
    local i=
    for (( i=1; i<$#; i+=2 )); do
        local extern_name="${@:$i:1}"
        local crate="${@:((i+1)):1}"
        [ -f "$crate/.cargo-info" ] || continue
        local crate_name=`jq -r '.name' $crate/.cargo-info`
        local proc_macro=`jq -r '.proc_macro' $crate/.cargo-info`
        if [ "$proc_macro" ]; then
            echo "--extern" "${extern_name}=$crate/lib/$proc_macro"
        elif [ -f "$crate/lib/lib${crate_name}.rlib" ]; then
            echo "--extern" "${extern_name}=$crate/lib/lib${crate_name}.rlib"
        elif [ -f "$crate/lib/lib${crate_name}.so" ]; then
            echo "--extern" "${extern_name}=$crate/lib/lib${crate_name}.so"
        elif [ -f "$crate/lib/lib${crate_name}.a" ]; then
            echo "--extern" "${extern_name}=$crate/lib/lib${crate_name}.a"
        elif [ -f "$crate/lib/lib${crate_name}.dylib" ]; then
            echo "--extern" "${extern_name}=$crate/lib/lib${crate_name}.dylib"
        else
            echo do not know how to find $extern_name \($crate_name\) >&2
            exit 1
        fi
        echo "-L" dependency=$crate/lib/deps
        if [ -f "$crate/lib/.link-flags" ]; then
            cat $crate/lib/.link-flags
        fi
    done
}
loadExternCrateLinkFlags() {
    local i=
    for (( i=1; i<$#; i+=2 )); do
        local extern_name="${@:$i:1}"
        local crate="${@:((i+1)):1}"
        [ -f "$crate/.cargo-info" ] || continue
        local crate_name=`jq -r '.name' $crate/.cargo-info`
        if [ -f "$crate/lib/.link-flags" ]; then
            cat $crate/lib/.link-flags
        fi
    done
}
loadDepKeys() {
    for (( i=2; i<=$#; i+=2 )); do
        local crate="${@:$i:1}"
        [ -f "$crate/.cargo-info" ] && [ -f "$crate/lib/.dep-keys" ] || continue
        cat $crate/lib/.dep-keys
    done
}
linkExternCrateToDeps() {
    local deps_dir=$1; shift
    for (( i=1; i<$#; i+=2 )); do
        local dep="${@:((i+1)):1}"
        [ -f "$dep/.cargo-info" ] || continue
        local crate_name=`jq -r '.name' $dep/.cargo-info`
        local metadata=`jq -r '.metadata' $dep/.cargo-info`
        local proc_macro=`jq -r '.proc_macro' $dep/.cargo-info`
        if [ "$proc_macro" ]; then
            local ext=`extractFileExt $proc_macro`
            ln -sf $dep/lib/$proc_macro $deps_dir/`basename $proc_macro .$ext`-$metadata.$ext
        else
            ln -sf $dep/lib/lib${crate_name}.rlib $deps_dir/lib${crate_name}-${metadata}.rlib
        fi
        (
            shopt -s nullglob
            for subdep in $dep/lib/deps/*; do
                local subdep_name=`basename $subdep`
                ln -sf $subdep $deps_dir/$subdep_name
            done
        )
    done
}
upper() {
    echo ${1^^}
}
dumpDepInfo() {
    local link_flags="$1"; shift
    local dep_keys="$1"; shift
    local cargo_links="$1"; shift
    local dep_files="$1"; shift
    local depinfo="$1"; shift

    cat $depinfo | while read line; do
        [[ "x$line" =~ xcargo:([^=]+)=(.*) ]] || continue
        local key="${BASH_REMATCH[1]}"
        local val="${BASH_REMATCH[2]}"

        case $key in
            rustc-link-lib) ;&
            rustc-flags) ;&
            rustc-cfg) ;&
            rustc-env) ;&
            rerun-if-changed) ;&
            rerun-if-env-changed) ;&
            warning)
            ;;
            rustc-link-search)
                echo "-L" `printf '%q' $val` >>$link_flags
                ;;
            *)
                if [ -e "$val" ]; then
                    local dep_file_target=$dep_files/DEP_$(upper $cargo_links)_$(upper $key)
                    cp -r "$val" $dep_file_target
                    val=$dep_file_target
                fi
                printf 'DEP_%s_%s=%s\n' $(upper $cargo_links) $(upper $key) "$val" >>$dep_keys
        esac
    done
}

install_crate() {
    local host_triple=$1
    pushd target/${host_triple}/release
    local needs_deps=
    local has_output=
    for output in *; do
        if [ -d "$output" ]; then
            continue
        elif [ -x "$output" ]; then
            mkdir -p $out/bin
            cp $output $out/bin/
            has_output=1
        else
            case `extractFileExt "$output"` in
                rlib)
                    mkdir -p $out/lib/.dep-files
                    cp $output $out/lib/
                    local link_flags=$out/lib/.link-flags
                    local dep_keys=$out/lib/.dep-keys
                    touch $link_flags $dep_keys
                    for depinfo in build/*/output; do
                        dumpDepInfo $link_flags $dep_keys "$cargo_links" $out/lib/.dep-files $depinfo
                    done
                    needs_deps=1
                    has_output=1
                    ;;
                a) ;&
                so) ;&
                dylib)
                    mkdir -p $out/lib
                    cp $output $out/lib/
                    has_output=1
                    ;;
                *)
                    continue
            esac
        fi
    done
    popd

    touch $out/lib/.link-flags
    loadExternCrateLinkFlags $dependencies >> $out/lib/.link-flags

    if [ "$isProcMacro" ]; then
        pushd target/release
        for output in *; do
            if [ -d "$output" ]; then
                continue
            fi
            case `extractFileExt "$output"` in
                so) ;&
                dylib)
                    isProcMacro=`basename $output`
                    mkdir -p $out/lib
                    cp $output $out/lib
                    needs_deps=1
                    has_output=1
                    ;;
                *)
                    continue
            esac
        done
        popd
    fi

    if [ ! "$has_output" ]; then
        echo NO OUTPUT IS FOUND
        exit 1
    fi

    if [ "$needs_deps" ]; then
        mkdir -p $out/lib/deps
        linkExternCrateToDeps $out/lib/deps $dependencies
    fi

    echo {} | jq \
'{name:$name, metadata:$metadata, version:$version, proc_macro:$procmacro}' \
--arg name $crateName \
--arg metadata $NIX_RUST_METADATA \
--arg procmacro "$isProcMacro" \
--arg version $version >$out/.cargo-info
}
