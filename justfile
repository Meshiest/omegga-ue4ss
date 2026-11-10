# List available recipes
default:
    @just --list

build:
    npm run build

test:
    npm test

# Build UE4SS and the bridge mod into runtime/ and release/ (needs Epic GitHub access)
runtime:
    native/build.sh

REMOTE := env_var_or_default("REMOTE", "origin")

# Tag the version in package.json and push it, refusing to move an existing tag
tag:
    tools/tag.sh {{ REMOTE }}
