# runai-template

Scripts for running interactive dev containers and batch training jobs on a Run:ai cluster, with SSH access through port forwarding. The container creates your cluster user account at startup, keeps your home directory on a persistent volume, and runs sshd alongside your workload so VS Code can connect to it.

## Layout

```
scripts/cluster/
├── Dockerfile                  Dev image: PyTorch base, sshd, uv, sudo
├── entrypoint.sh               Creates the user, starts sshd, runs your command
├── docker_build_publish.py     Builds and optionally pushes the image
└── runai_submit.py             Submits a workspace or a training job
```

## Prerequisites

- The `runai` CLI, installed and authenticated (`runai login`). Ask your cluster admin for access to a project.
- A Run:ai project with an existing PVC that will hold your data and home directory.
- Docker, if you want to build and publish the image.
- A username of your choice, plus your LDAP uid and gid on the cluster. On a cluster login node, run `id` and note both numbers. If you have no shell access, your admin can tell you.

## The image

All examples use my prebuilt image [`arashsm79/mlruntime:latest`](https://hub.docker.com/r/arashsm79/mlruntime). It is NVIDIA's PyTorch image with sshd, uv, sudo, and a pile of dev tools installed, so it works with these scripts out of the box. You do not need to build anything to use them.

If you want your own image instead, build and publish it with:

```
uv run scripts/cluster/docker_build_publish.py \
    --image docker.io/yourname/mlruntime \
    --tag latest \
    --push
```

You can point at any registry your cluster can pull from. The base image tag lives at the top of the Dockerfile, so swap it there if you need a different CUDA or PyTorch version. Any image built from this Dockerfile works with the submit script; a random image without the entrypoint will not set up SSH.

## Set up your identity

The submit script takes the same identity flags every time:

- `--ldap-user`: your login name (can be whatever you want)
- `--ldap-uid`: your user ID
- `--ldap-gid`: your group ID
- `--password`: the SSH password

The entrypoint creates the user inside the container, mounts your home at `/scratch/<project>/home/<ldap-user>` on the PVC, gives you passwordless sudo, and generates SSH host keys that persist on the PVC so they survive across jobs.

## Launch an interactive workspace

A workspace is a long-running pod with no GPU by default, meant for developing in VS Code. Here is the same job with every available flag spelled out:

```
uv run scripts/cluster/runai_submit.py \
    --name mldev \
    --project myproject \
    --pvc myproject-pvc \
    --image docker.io/arashsm79/mlruntime:latest \
    --ldap-user yourusername --ldap-uid 2401 --ldap-gid 1552 \
    --gpu-portion-request 0.1 \
    --cpu-core-request 1.0 \
    --password "yourpassword"
```

Every parameter the script accepts:

| Flag | Default | Meaning |
|------|---------|---------|
| `--project` | required | Run:ai project name. The PVC is also mounted at `/scratch/<project>` |
| `--name` | `mldev` | Workload name. Use a unique name per job |
| `--training` | off | Submit a training workload instead of a workspace. Requires a command after `--` |
| `--image` | required | Container image to run |
| `--pvc` | required | Existing PVC name to mount |
| `--ldap-user` | required | Login name created inside the container |
| `--ldap-uid` | required | Your numeric user ID |
| `--ldap-gid` | required | Your numeric group ID |
| `--gpu-portion-request` | `0.0` workspace, `1.0` training | GPU fraction between 0 and 1 |
| `--cpu-core-request` | `1.0` | CPU cores to request |
| `--cpu-memory-request` | none | Memory request, for example `16G`. Training only |
| `--node-pool` | none | Node pool to schedule on. Training only |
| `--password` | required | SSH password |
| `-- <command>` | `sleep infinity` | Command to run inside the container |

## Port forward

The script prints the port-forward command. After a couple minutes, run it in a second terminal and leave it running:
This might be a bit finicky. If the SSH connection doesn't work, stop the port forward and rerun it again.

```
runai workspace port-forward mldev \
    --project myproject \
    --port 2222:2222 \
    --address 127.0.0.1
```

## Connect with VS Code

Install the Remote-SSH extension, then add this to `~/.ssh/config`:

```
Host runai-dev
    HostName 127.0.0.1
    Port 2222
    User you
```

With the port-forward running, open the command palette, run `Remote-SSH: Connect to Host`, pick `runai-dev`, and enter your SSH password. VS Code installs its server into `.vscode-server` under your persistent home, so the second connect is fast and survives pod restarts.

From the integrated terminal you are inside the container as your LDAP user, on the PVC. Anything you install with `uv` or `pip` persists in your home directory.

## Launch a training job

Add `--training` and a command after `--`. The job runs as a standard Run:ai training workload with `OnFailure` restart, so it retries on crashes. This example uses every flag, including the two that only apply to training:

```
uv run scripts/cluster/runai_submit.py \
    --training \
    --name train-run-0 \
    --project myproject \
    --pvc myproject-pvc \
    --image docker.io/arashsm79/mlruntime:latest \
    --ldap-user you --ldap-uid 1000 --ldap-gid 1000 \
    --gpu-portion-request 1.0 \
    --cpu-core-request 4.0 \
    --cpu-memory-request 32G \
    --node-pool gpu \
    --password "SSH_PASSWORD" \
    -- uv run train.py --epochs 10
```

You can still SSH into a training pod the same way, since sshd runs alongside the workload.

## Submit a bunch of training jobs

A shell loop is all you need for a sweep. Each job gets its own name, and because the PVC is shared, the only thing you have to manage yourself is writing outputs to distinct paths (or reading them from the job name in your script):

```
for i in 0 1 2 3 4 5 6 7; do
    uv run scripts/cluster/runai_submit.py \
        --training \
        --name sweep-lr-$i \
        --project myproject \
        --pvc myproject-pvc \
        --image docker.io/arashsm79/mlruntime:latest \
        --ldap-user you --ldap-uid 1000 --ldap-gid 1000 \
        --gpu-portion-request 0.5 \
        --password "SSH_PASSWORD" \
        -- uv run train.py --lr 0.001 --seed $i --out runs/lr-$i
    sleep 2
done
```

