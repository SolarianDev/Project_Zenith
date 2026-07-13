# Project Zenith

**Project Zenith** is an automated deployment script designed to bring a fully functional, rootless Linux container environment to restricted macOS/Linux workstations (specifically tailored for 42 School environments using `goinfre` storage). 

By combining **Rootless Podman** with **Distrobox**, Project Zenith allows unprivileged users to create isolated development environments where they possess "root" access, install system packages (via `apt`, `pacman`, `dnf`), and seamlessly integrate with the host's home directory and hardware devices.

## How It Works (The User Perspective)
When you run Project Zenith, it bypasses the need for system-level package managers (like `apt` or `brew`) which require administrator privileges.

1. **Dynamic Pathing:** It detects your actual unprivileged user ID and dynamically maps out your personal `goinfre` storage (a large, temporary storage drive often used in 42 environments).
2. **Binary Fetching:** It downloads pre-compiled, static binaries for Podman and its core dependencies directly from their official GitHub releases.
3. **Configuration Injection:** It builds a custom Podman configuration tree in your `~/.config/containers` directory, instructing Podman to store all heavy container images and runtimes inside `goinfre` rather than your limited home directory quota.
4. **Distrobox Wrapping:** Finally, it installs Distrobox, a wrapper around Podman that seamlessly mounts your home directory, USB devices, and audio/video sockets into the container, making the container feel like a native application on the host.

## Implementation Details
Project Zenith is implemented as a pure Bash script (`#!/usr/bin/env bash`) strictly utilizing POSIX-compliant tools (`curl`, `tar`, `find`, `readlink`) to ensure execution on heavily locked-down host machines.

### Core Components Downloaded:
* **Podman (Engine):** The daemonless container engine.
* **crun (Runtime):** A fast, lightweight OCI container runtime written in C.
* **conmon (Monitor):** A utility used to monitor the container runtime, handle logging, and serve as the parent process for the container.
* **Netavark & Aardvark-dns (Networking):** Rust-based network stack tools for Podman to handle IP allocations, container-to-container networking, and DNS resolution without requiring root firewall rules.

### Storage & Home Directory Redirection
Restricted accounts usually have strict quotas on `$HOME`. The script explicitly handles this in two ways:

1. **Engine Storage:** Generates a `storage.conf` to redirect the heavy lifting of container layers:
```ini
graphroot = "/goinfre/username/containers/storage"
runroot = "/run/user/<UID>"
```

2. **Container Home Directory:** When you create a container, Project Zenith's setup command explicitly maps your container's internal home directory into `goinfre` using the `--home` flag (e.g., `--home /goinfre/username/homes/my-box`). 
   * *Why this matters:* By default, Distrobox tightly mounts your actual host `~` into the container. If you were to run `npm install`, compile large binaries, or cache large files inside the container, it would immediately eat into your restricted host quota. By mapping the container's home to `goinfre/homes/`, you get unlimited space for your development tools while keeping your actual host profile clean.

## The "False Root" Illusion: How Rootless Containers Work
The core magic of Project Zenith is giving you `root` inside the container when you are a standard `user` on the host. This is achieved through **User Namespaces** (`user_namespaces(7)`).

### 1. UID Mapping
When Podman starts a container, it leverages the Linux kernel's user namespace feature. It creates a mapping between the User IDs (UIDs) inside the container and the UIDs on the host machine.
* **Inside the container:** You are `root` (UID 0).
* **Outside the container:** The kernel translates UID 0 to your unprivileged host UID (e.g., UID 1000 or 50000).

When you run `apt install` inside the container, the files written to the disk appear to be owned by `root` from the container's perspective. However, if an administrator checks the host filesystem, those exact same files are owned by your standard user account.

### 2. The Storage Driver: `vfs` and `ignore_chown_errors`
In a standard Docker/Podman setup, the container uses **OverlayFS**, a filesystem that efficiently layers files. However, OverlayFS historically required root privileges to mount. Because Project Zenith operates in a fully unprivileged environment (often without `/etc/subuid` or `/etc/subgid` delegations that Podman usually relies on), the script forces the **`vfs` (Virtual File System)** storage driver.

Furthermore, to maintain the "false root" illusion when a package tries to change file ownership (`chown`) during an installation, the script uses:
```ini
ignore_chown_errors = "true"
```
Without this, package managers like `apt` would crash because the host kernel would deny an unprivileged user the right to assign file ownership to arbitrary other users.

## Known Limitations
Because Project Zenith relies entirely on unprivileged execution and the `vfs` driver, it comes with unavoidable technical tradeoffs:

### 1. Severe Storage Bloat (`vfs` Driver)
Unlike OverlayFS, which shares identical files between containers using Copy-on-Write (CoW), the `vfs` driver physically **copies the entire filesystem** every time a new container or layer is created.
* *Impact:* If you download a 1GB Ubuntu image and create three Distroboxes from it, it will consume 4GB of disk space (1GB for the base image + 3GB for the identical container clones). This is why routing to `goinfre` is mandatory.

### 2. Networking Restrictions
Because you are not root on the host, Podman cannot bind to privileged network ports (ports under `1024`).
* *Impact:* You cannot run a web server inside your container on port 80 or 443. You must configure your development servers to run on high ports (e.g., `8080`, `3000`).
* *Impact:* `ping` (ICMP traffic) may fail inside the container depending on how the host kernel's `net.ipv4.ping_group_range` is configured.

### 3. Slower Performance
The `vfs` driver has significantly higher disk I/O overhead compared to native filesystems or OverlayFS. Heavy disk operations (like compiling massive C++ codebases or running `npm install` for huge projects) will be noticeably slower than running directly on the host.

### 4. Hardware/Systemd Pass-through
While Distrobox does an excellent job passing through USB controllers, you cannot easily run `systemd` inside these rootless containers. Background services (like `sshd`, `nginx`, or `postgresql` daemons) must usually be started manually in the foreground rather than relying on `systemctl`.
