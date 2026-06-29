---
name: docker
description: Use the Docker CLI to manage containers, images, networks, and volumes. Supports building images, running integration tests with Testcontainers-style workflows, and inspecting the Docker engine.
---

## What I do

- Build, run, stop, and remove containers via `docker run`, `docker build`, `docker ps`, `docker rm`.
- Manage images with `docker images`, `docker pull`, `docker rmi`.
- Inspect the engine with `docker info`, `docker version`, `docker context ls`.

## When to use me

Use this skill when the agent needs to run or inspect containers, build images, or debug a Docker-in-Docker setup. The
sandbox connects to a firewall-restricted Docker socket, so dangerous calls (e.g. mounting the host root) are blocked.
