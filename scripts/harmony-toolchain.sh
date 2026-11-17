#!/usr/bin/env bash

# Resolve the Harmony SDK root and packaging tools used by the HAR scripts.
harmony_toolchain_resolve() {
  local candidate app_root sdk_root command_path configured_name
  local -a sdk_candidates=()

  sdk_root=''
  if [[ -n ${DEVECO_SDK_HOME:-} ]]; then
    configured_name=DEVECO_SDK_HOME
    sdk_candidates=("$DEVECO_SDK_HOME")
  elif [[ -n ${HOS_SDK_HOME:-} ]]; then
    configured_name=HOS_SDK_HOME
    sdk_candidates=("$HOS_SDK_HOME")
  elif [[ -n ${OHOS_BASE_SDK_HOME:-} ]]; then
    configured_name=OHOS_BASE_SDK_HOME
    sdk_candidates=("$OHOS_BASE_SDK_HOME")
  elif [[ -n ${DEVECO_HOME:-} ]]; then
    configured_name=DEVECO_HOME
    app_root=$DEVECO_HOME
    sdk_candidates=("$app_root/Contents/sdk" "$app_root/sdk" "$app_root")
  elif [[ -d /Applications/DevEco-Studio.app/Contents/sdk ]]; then
    configured_name='default DevEco installation'
    app_root=/Applications/DevEco-Studio.app
    sdk_candidates=("$app_root/Contents/sdk")
  else
    configured_name=''
  fi

  for candidate in "${sdk_candidates[@]}"; do
    if [[ -d "$candidate/default/openharmony/native" ]]; then
      sdk_root=$candidate
      break
    fi
    if [[ -d "$candidate/native" && "$candidate" == */default/openharmony ]]; then
      sdk_root=${candidate%/default/openharmony}
      break
    fi
  done

  if [[ -z $sdk_root ]]; then
    if [[ -n $configured_name ]]; then
      echo "$configured_name does not identify a Harmony SDK: ${sdk_candidates[*]}" >&2
      return 1
    fi
    echo 'Harmony SDK not found; set DEVECO_SDK_HOME, HOS_SDK_HOME, OHOS_BASE_SDK_HOME, or DEVECO_HOME.' >&2
    return 1
  fi
  DEVECO_SDK_HOME=$sdk_root
  export DEVECO_SDK_HOME
  OHOS_NATIVE_HOME="$DEVECO_SDK_HOME/default/openharmony/native"
  if [[ -d "$DEVECO_SDK_HOME/native" ]]; then OHOS_NATIVE_HOME="$DEVECO_SDK_HOME/native"; fi
  if [[ -z ${AR:-} && ! -x "$OHOS_NATIVE_HOME/llvm/bin/llvm-ar" ]]; then
    echo "Harmony SDK is missing llvm-ar: $OHOS_NATIVE_HOME/llvm/bin/llvm-ar" >&2
    return 1
  fi

  if [[ -z ${HVIGORW:-} ]]; then
    command_path=$(command -v hvigorw || true)
    if [[ -n $command_path ]]; then
      HVIGORW=$command_path
    else
      for candidate in "$DEVECO_SDK_HOME/command-line-tools/bin/hvigorw" "$DEVECO_SDK_HOME/../command-line-tools/bin/hvigorw" "${DEVECO_HOME:-}/Contents/tools/hvigor/bin/hvigorw" "${app_root:-}/Contents/tools/hvigor/bin/hvigorw"; do
        if [[ -x $candidate ]]; then HVIGORW=$candidate; break; fi
      done
    fi
  fi
  if [[ -z ${HVIGORW:-} || ! -x $HVIGORW ]]; then
    echo 'Hvigor wrapper not found; set HVIGORW or add hvigorw to PATH.' >&2
    return 1
  fi

  if [[ -z ${OHPM:-} ]]; then
    command_path=$(command -v ohpm || true)
    if [[ -n $command_path ]]; then
      OHPM=$command_path
    else
      for candidate in "$DEVECO_SDK_HOME/command-line-tools/bin/ohpm" "$DEVECO_SDK_HOME/../command-line-tools/bin/ohpm" "${DEVECO_HOME:-}/Contents/tools/ohpm/bin/ohpm" "${app_root:-}/Contents/tools/ohpm/bin/ohpm"; do
        if [[ -x $candidate ]]; then OHPM=$candidate; break; fi
      done
    fi
  fi
  if [[ -z ${OHPM:-} || ! -x $OHPM ]]; then
    echo 'ohpm not found; set OHPM or add ohpm to PATH.' >&2
    return 1
  fi

  if [[ -z ${AR:-} ]]; then AR=$OHOS_NATIVE_HOME/llvm/bin/llvm-ar; fi
  if [[ ! -x $AR ]]; then
    command_path=$(command -v "$AR" || true)
    if [[ -n $command_path ]]; then AR=$command_path; fi
  fi
  if [[ ! -x $AR ]]; then
    echo "Archive tool is not executable: $AR" >&2
    return 1
  fi
  export OHOS_NATIVE_HOME HVIGORW OHPM AR
}
