#!/usr/bin/env bash

started=$((docker inspect -f '{{.State.Running}}' matchid-tools > /dev/null 2>&1) || echo false)
if [ "$started" == "false" ];then \
	docker run --rm -d\
		--name matchid-tools\
		-v "$(pwd):/tools/data" \
		-v "$HOME/.aws/:/root/.aws"\
		matchid/tools;\
fi
docker exec -i matchid-tools "$@";
