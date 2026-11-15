# podman inspect <container> | jq --arg net <network> -> container IP on that network
.[0].NetworkSettings.Networks[$net].IPAddress // empty
