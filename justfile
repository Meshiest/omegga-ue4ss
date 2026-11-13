# List available recipes
default:
    @just --list

typecheck:
    npm run typecheck

test:
    npm test

# Build UE4SS and the bridge mod into runtime/ (needs Epic GitHub access); the plugin then uses it as is
runtime:
    native/build.sh
