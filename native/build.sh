#!/usr/bin/env bash
# Build the UE4SS runtime this plugin installs: tc-imba's Linux port of RE-UE4SS
# (upstream PR #1342) at the commits in patches/*.base plus patches/, and the
# BrickadiaBridge native mod.
#
#   native/build.sh [work dir]     (default: native/work)
#
# Produces runtime/ (what the plugin uses). CI publishes the same two binaries
# to the `runtime` release by content key (src/runtime-keys.ts).
#
# Needs clang 18+, Rust, Python 3 (for a local cmake/ninja venv) and SSH access
# to github.com/tc-imba/UEPseudo, which is gated behind the Epic Games GitHub
# link, so HTTPS clones of it fail.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
work=${1:-$here/work}
src=$work/RE-UE4SS
build=$work/build

if [[ ! -d $src ]]; then
  git clone https://github.com/tc-imba/RE-UE4SS.git "$src"
  git -C "$src" checkout "$(cat "$here/patches/RE-UE4SS.base")"
  git -C "$src" submodule init
  git -C "$src" config submodule.deps/first/Unreal.url git@github.com:tc-imba/UEPseudo.git
  git -C "$src" config submodule.deps/first/patternsleuth.url https://github.com/tc-imba/patternsleuth.git
  git -C "$src" submodule update --recursive
  git -C "$src" apply "$here/patches/RE-UE4SS.patch"
  git -C "$src/deps/first/Unreal" apply "$here/patches/UEPseudo.patch"
fi

if [[ ! -x $work/venv/bin/cmake ]]; then
  python3 -m venv "$work/venv"
  "$work/venv/bin/pip" install -q cmake ninja
fi
export PATH=$work/venv/bin:$PATH

# libstdc++ only exposes std::expected (needed by glaze) when __cpp_concepts >=
# 202002, which clang 18 doesn't advertise although it compiles the code fine
cmake -S "$src" -B "$build" -G Ninja \
  -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
  -DCMAKE_BUILD_TYPE=Game__Shipping__Linux -DUE4SS_GUI=OFF -DUE4SS_BUILD_TESTS=ON \
  "-DCMAKE_CXX_FLAGS=-Wno-builtin-macro-redefined -U__cpp_concepts -D__cpp_concepts=202002L" \
  "-DUE4SS_EXTRA_CPPMODS=$here/BrickadiaBridge"
cmake --build "$build" --parallel "$(( $(nproc) * 2 / 3 + 1 ))"
ctest --test-dir "$build" --output-on-failure

lib=$build/Game__Shipping__Linux/lib
rm -rf "$root/runtime"
mkdir -p "$root/runtime/BrickadiaBridge"
install -m 755 "$lib/libUE4SS.so" "$root/runtime/libUE4SS.so"
install -m 755 "$lib/main.so" "$root/runtime/BrickadiaBridge/main.so"
install -m 644 "$root/LICENSE-UE4SS" "$root/runtime/LICENSE-UE4SS"
# the plugin uses a local build as it is and never downloads over it; delete
# runtime/ to go back to the published binaries
touch "$root/runtime/.local"
ls -la "$root/runtime"
