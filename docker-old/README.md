HomeLab Docker Compose
===
This is a repository handling all the docker compose file on my nas.

The containers are centered aroung the `nas` network. The `nginx` then have access to all the services and can reverse-proxy.

# Execute commands
```sh
docker compose -f <compose.yml> up -d
