# lite-xl-maintenance

Scripts that are helpful for maintaing the lite-xl project and its various subprojects.

## Usage

By default, lpm doesn't load any extra functionality. You can change this one of two ways.

1. Add in `--plugin` to your lpm call with the path the the plugin you'd like to have extend `lpm`'s functionality. You can specify `--plugin` multiple times. Best place to do this is in an `lpm` BASH script in your path, like so:

```bash
lpm $@ --plugin ~/lite-xl-maintenance/lpm-plugins/gh.lua
```

2. Export the variable `LPM_PLUGINS` to your environment; this is a colon separated list of plugin paths that will be loaded with each lpm call.

## lpm plugins

### gh

Adds github-related functionality to lpm. Requires `gh` installed.

* Allows you to supply PR urls to `run`, which will automatically decode the PR, and supply the appropriate repo.
* Allows you to automatically create PRs in [`lite-xl-plugins`](https://github.com/lite-xl/lite-xl-plugins) in your CI, in order to backfill your stubs with the following line.
(ensure that your user has a fork of lite-xl-plugins in which to stage the change, and that your manifest is fully up to date).

```
name: Create PR to lite-xl-plugins
on:
  workflow_dispatch:
jobs:
  create_pr:
    name: Create PR to lite-xl-plugins
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Create PR
        env: { GITHUB_TOKEN: "${{ github.token }}" }
        run: |
          wget https://github.com/lite-xl/lite-xl-plugin-manager/releases/download/latest/lpm.x86_64-linux -O lpm && chmod +x lpm &&
            ./lpm --plugin https://raw.githubusercontent.com/adamharrison/lite-xl-maintenance/latest/lpm-plugins/gh.lua create-addon-update-pr
```
