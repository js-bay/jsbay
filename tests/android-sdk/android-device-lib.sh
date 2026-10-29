#!/usr/bin/env bash

require_android_device_abi() {
    local jni_libs="$1"
    local abi_list abi
    ANDROID_DEVICE_ABI=''
    ANDROID_DEVICE_CORE=''
    ANDROID_DEVICE_ADAPTER=''
    abi_list="$("${ADB:-adb}" shell getprop ro.product.cpu.abilist | tr -d '\r')"
    if [ -z "$abi_list" ]; then
        abi_list="$("${ADB:-adb}" shell getprop ro.product.cpu.abi | tr -d '\r')"
    fi
    IFS=, read -r -a android_device_abis <<< "$abi_list"
    for abi in "${android_device_abis[@]}"; do
        case "$abi" in
            arm64-v8a|x86_64)
                if [ -f "$jni_libs/$abi/libjsbay.so" ] && [ -f "$jni_libs/$abi/libjsbay_android.so" ]; then
                    ANDROID_DEVICE_ABI="$abi"
                    ANDROID_DEVICE_CORE="$jni_libs/$abi/libjsbay.so"
                    ANDROID_DEVICE_ADAPTER="$jni_libs/$abi/libjsbay_android.so"
                    return 0
                fi
                ;;
        esac
    done
    echo "ERROR: no compatible Android ABI in device [$abi_list] and $jni_libs" >&2
    return 1
}

push_android_device_payload() {
    local dex="$1"
    local remote="$2"
    [ -n "$ANDROID_DEVICE_ABI" ] || { echo 'ERROR: select an Android ABI before pushing' >&2; return 1; }
    "${ADB:-adb}" push "$dex" "$ANDROID_DEVICE_CORE" "$ANDROID_DEVICE_ADAPTER" "$remote"
}

run_android_device_consumer() {
    local remote="$1"
    "${ADB:-adb}" shell "CLASSPATH='$remote/classes.dex' LD_LIBRARY_PATH='$remote' app_process -Djava.io.tmpdir='$remote' / io.jsbay.consumer.DeviceLoopMain"
}
