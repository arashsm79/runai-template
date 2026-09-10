#!/usr/bin/env python3

import argparse
import time
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--project",
        required=True,
        help="Run:ai project and PVC directory name",
    )
    parser.add_argument("--name", default="mldev")
    parser.add_argument(
        "--training",
        action="store_true",
        help="Submit a standard training workload instead of a workspace",
    )
    parser.add_argument(
        "--image",
        required=True,
        help="Container image to run",
    )
    parser.add_argument(
        "--pvc",
        required=True,
        help="Existing PVC mounted at the project directory",
    )
    parser.add_argument("--ldap-user", required=True, help="LDAP login name")
    parser.add_argument("--ldap-uid", required=True, help="LDAP user ID")
    parser.add_argument("--ldap-gid", required=True, help="LDAP group ID")
    parser.add_argument(
        "--gpu-portion-request",
        help="GPU fraction between 0 and 1 (default: 1.0 for training, 0.0 for workspace)",
    )
    parser.add_argument(
        "--cpu-core-request",
        default="1.0",
        help="CPU cores to request (default: 1.0)",
    )
    parser.add_argument(
        "--cpu-memory-request",
        help="Memory request for a training workload, for example 16G",
    )
    parser.add_argument(
        "--node-pool",
        help="Run:ai node pool for a training workload",
    )
    parser.add_argument(
        "--password",
        required=True,
        help="SSH password",
    )
    parser.add_argument(
        "command",
        nargs=argparse.REMAINDER,
        help="Command to run as the LDAP user after -- (default: sleep infinity)",
    )
    args = parser.parse_args()

    project_dir = f"/scratch/{args.project}"
    home_dir = f"{project_dir}/home/{args.ldap_user}"

    container_command = args.command
    if container_command[:1] == ["--"]:
        container_command = container_command[1:]
    if args.training and not container_command:
        parser.error("--training requires a command after --")

    submit_command = (
        ["runai", "training", "standard", "submit"]
        if args.training
        else ["runai", "workspace", "submit"]
    )
    command = [
        *submit_command,
        args.name,
        "--project",
        args.project,
        "--image",
        args.image,
        "--existing-pvc",
        f"claimname={args.pvc},path={project_dir}",
        "--working-dir",
        project_dir,
        "--environment-variable",
        f"HOME={home_dir}",
        "--environment-variable",
        f"XDG_CONFIG_HOME={home_dir}/.config",
        "--environment-variable",
        f"XDG_CACHE_HOME={home_dir}/.cache",
        "--environment-variable",
        f"XDG_DATA_HOME={home_dir}/.local/share",
        "--environment-variable",
        f"XDG_STATE_HOME={home_dir}/.local/state",
        "--environment-variable",
        f"VSCODE_AGENT_FOLDER={home_dir}/.vscode-server",
        "--environment-variable",
        f"LDAP_USER={args.ldap_user}",
        "--environment-variable",
        f"LDAP_UID={args.ldap_uid}",
        "--environment-variable",
        f"LDAP_GID={args.ldap_gid}",
        "--environment-variable",
        f"SSH_PASSWORD={args.password}",
    ]

    if args.training:
        command.extend([
            "--gpu-portion-request",
            args.gpu_portion_request or "1.0",
            "--cpu-core-request",
            args.cpu_core_request,
            "--restart-policy",
            "OnFailure",
        ])
        if args.cpu_memory_request:
            command.extend([
                "--cpu-memory-request",
                args.cpu_memory_request,
            ])
        if args.node_pool:
            command.extend(["--node-pools", args.node_pool])
    else:
        command.extend([
            "--gpu-portion-request",
            args.gpu_portion_request or "0.0",
            "--cpu-core-request",
            args.cpu_core_request,
        ])

    command.extend([
        "--run-as-uid",
        "0",
        "--run-as-gid",
        "0",
        "--port",
        "service-type=ClusterIP,container=2222",
    ])

    command.extend(["--", *(container_command or ["sleep", "infinity"])])

    subprocess.run(command, check=True)

    time.sleep(5)  # Wait for the workload to start
    port_forward_command = (
        "runai training standard port-forward"
        if args.training
        else "runai workspace port-forward"
    )
    print(
        f"Run the following to set up a port-forward to the workload:\n\n"
        f"{port_forward_command} {args.name} \\\n  --project {args.project} \\\n  --port 2222:2222 \\\n  --address 127.0.0.1\n"
    )


if __name__ == "__main__":
    main()
