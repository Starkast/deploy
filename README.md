# Deploy

A GitHub Action that deploys the checked out commit to a host behind a WireGuard
gateway. The runner joins the WireGuard network as its own peer and pipes
`git archive` to `deploy <sha>` over SSH, so the deploy's output and exit status
end up in the job.

The host should give the SSH key a forced command that takes `deploy <sha>` and
the release tarball on stdin, and nothing else. The gateway should only let the
peer SSH to that host.

The action holds no secrets. Keep the repo's keys and settings in a GitHub
environment limited to `main`.

## Usage

Add a job to CI that needs the tests. Only `main` gets to it, and running CI by
hand on `main` can deploy another commit:

```yaml
name: CI

on:
  push:
    branches:
      - main
  pull_request:
  workflow_dispatch:
    inputs:
      ref:
        description: Commit, branch or tag to deploy
        default: main

concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

permissions:
  contents: read

jobs:
  test:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7
        with:
          persist-credentials: false
      - run: make test

  deploy:
    needs: test
    if: github.event_name != 'pull_request' && github.ref == 'refs/heads/main'
    concurrency: deploy
    runs-on: ubuntu-latest
    timeout-minutes: 30
    environment: production
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7
        with:
          ref: ${{ inputs.ref || github.sha }}
          persist-credentials: false
      - uses: Starkast/deploy@<full commit SHA>
        with:
          wireguard-private-key: ${{ secrets.WIREGUARD_PRIVATE_KEY }}
          wireguard-address: ${{ vars.WIREGUARD_ADDRESS }}
          wireguard-endpoint: ${{ vars.WIREGUARD_ENDPOINT }}
          wireguard-peer-public-key: ${{ vars.WIREGUARD_PEER_PUBLIC_KEY }}
          deploy-ssh-key: ${{ secrets.DEPLOY_SSH_KEY }}
          deploy-known-hosts: ${{ vars.DEPLOY_KNOWN_HOSTS }}
          deploy-host: ${{ vars.DEPLOY_HOST }}
          deploy-user: ${{ vars.DEPLOY_USER }}
```

Pin the action to a full commit SHA: it's handed the repo's deploy keys, so
whoever can move a tag here could read them.

The environment stays in the calling workflow. A composite action can't declare
one, and the keys are the environment's.
