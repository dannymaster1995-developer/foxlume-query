# Source this before running swift. Keeps every compiler, SwiftPM and temp cache inside the repository's
# .build folder, so nothing is written to ~/Library, ~/.swiftpm or the folder around the clone.
FQ_PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
FQ_CACHE="$FQ_PROJECT/.build/env"
export FQ_PROJECT FQ_CACHE
export TMPDIR="$FQ_CACHE/tmp/"
export CLANG_MODULE_CACHE_PATH="$FQ_CACHE/clang-module-cache"
export SWIFTPM_CACHE="$FQ_CACHE/swiftpm"
export XDG_CACHE_HOME="$FQ_CACHE/xdg-cache"
mkdir -p "$TMPDIR" "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_CACHE"
FQ_SWIFTPM_FLAGS=(
  --scratch-path "$FQ_PROJECT/.build"
  --cache-path "$SWIFTPM_CACHE/cache"
  --config-path "$SWIFTPM_CACHE/config"
  --security-path "$SWIFTPM_CACHE/security"
  --disable-sandbox
)
# SwiftPM creates ~/.swiftpm symlinks even with explicit paths, so give it a project-local HOME.
export FQ_HOME="$FQ_CACHE/home"
mkdir -p "$FQ_HOME"
fqswift() {
  local sub="$1"; shift
  HOME="$FQ_HOME" CFFIXED_USER_HOME="$FQ_HOME" swift "$sub" "${FQ_SWIFTPM_FLAGS[@]}" "$@"
}
# With only the Command Line Tools, Swift Testing lives outside the default search paths; Xcode needs no flags.
FQ_TESTING_FRAMEWORKS=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
FQ_TESTING_LIBS=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
fqtest() {
  local flags=()
  if [[ "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* ]]; then
    flags=(-Xswiftc -F -Xswiftc "$FQ_TESTING_FRAMEWORKS" -Xlinker -F -Xlinker "$FQ_TESTING_FRAMEWORKS"
      -Xlinker -rpath -Xlinker "$FQ_TESTING_FRAMEWORKS" -Xlinker -rpath -Xlinker "$FQ_TESTING_LIBS")
  fi
  mkdir -p "$FQ_CACHE/test-data"
  FOXLUME_DATA_DIR="$FQ_CACHE/test-data" fqswift test ${flags[@]+"${flags[@]}"} "$@"
}
