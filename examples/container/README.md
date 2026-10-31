# Pi in a container

This is an example of a pi.nvim workspace descriptor that runs Pi in a throwaway Docker container, not a supported provisioner. Adapt it to your own setup.

- `Dockerfile` builds an image with Pi installed, following Pi's [containerization guide](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/containerization.md).
- `pi.nvim.json` is the descriptor. Your tooling copies it into a worker clone or worktree as `.pi.nvim.json`, then opens a tab there with `:tcd`.

## Try it

```sh
docker build -t pi-sandbox examples/container
git worktree add ~/Worktrees/myproject-sandbox
cp examples/container/pi.nvim.json ~/Worktrees/myproject-sandbox/.pi.nvim.json
```

In Neovim, open a tab with `:tabnew | tcd ~/Worktrees/myproject-sandbox`, then run `:Pi`. pi.nvim asks once whether to trust the descriptor. After that, `:Pi`, `:PiContinue`, and `:PiResume` work in that tab as usual, with Pi inside the container.

## What it sets up

- The worktree is mounted at the same path inside the container, so Pi's edits land in the worktree and paths read the same on both sides. `"paths": { "workspace": "${{WORKSPACE}}" }` tells pi.nvim that Pi runs in a separate filesystem where the workspace is mounted at that path.
- Sessions are stored in `<worktree>/.pi/sessions`, inside the mounted workspace, so they survive the container and pi.nvim can list and resume them. Add `.pi/` to the worktree's ignore rules if you don't want them in Git.
- `docker run --rm -i` keeps Pi's input open for RPC. When pi.nvim stops Pi, it closes that input; Pi exits and Docker removes the container.
- Credentials: Pi inside the container doesn't see your host's Pi agent folder. `-e ANTHROPIC_API_KEY` forwards that variable from Neovim's environment; forward what your provider needs, or mount a dedicated volume for Pi's agent folder. See Pi's guide for the trade-offs.
