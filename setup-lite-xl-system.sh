#!/bin/bash

cd lite-xl-system && \
  git fetch upstream && git fetch origin && \
  git checkout '3.0-preview'; 
  echo "Starting from Virtual Lines..." && \
  git reset origin/PR/reconcile-virtual-lines-multi-window --hard && \
  echo "Merging storage class..." && \
  git merge origin/PR/add-storage-class -m 'Merge Commit' && \
  echo "Merging Move SDL to Lua..." &&\
  git merge origin/PR/move-sdl-to-lua -m "Merge Commit" && \
  echo "Merging fuzzy match commit..." &&\
  git merge origin/PR/fix-autocomplete-fuzzy-match -m "Merge Commit" && \
  echo "Merging Scroll CommandView..." &&\
  git merge origin/PR/scroll-command-view -m "Merge Commit" && \
  echo "Merging Preview Releases..." &&\
  git merge origin/PR/preview-releases -m "Merge Commit" && \
  echo "Merging Plugin Require Errors..." &&\
  git merge origin/PR/plugin-require-error -m "Merge Commit" && \
  echo "Merging Remove Release Notes..." &&\
  git merge origin/remove-release-notes -m "Merge Commit" && \
  git apply ../setup-lite-xl-system.patch && git add data/meson.build scripts/generate-release-notes.sh && git commit -m '3.0 Merge Commit' && \
  build-lite
  git tag v3.0-preview -f
  git push origin v3.0-preview -f
  git push --set-upstream origin 3.0-preview -f
