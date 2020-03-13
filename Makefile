SHELL=/bin/bash

APP=deces-dataprep
PWD := $(shell pwd)
GIT = $(shell which git)
GITROOT = https://github.com/matchid-project
GITBACKEND = backend
MAKE = $(shell which make)
RECIPE = deces_dataprep
RECIPE_THREADS = 4
RECIPE_QUEUE = 1
TIMEOUT = 2520
DATAGOUV_API = https://www.data.gouv.fr/api/1/datasets
DATAGOUV_DATASET = fichier-des-personnes-decedees
DATA_DIR = ${PWD}/data
BACKUP_DIR = ${PWD}/${GITBACKEND}/backup
# files to sync:
FILES_TO_SYNC=(^|\s)deces-.*.txt(.gz)?($$|\s)
# files to process:
FILES_TO_PROCESS=deces-([0-9]{4}|2020-m[0-9]{2}).txt.gz
#FILES_TO_PROCESS_DIFF=deces-2020-m[0-9]{2}.txt.gz
DATAGOUV_CATALOG = ${DATA_DIR}/${DATAGOUV_DATASET}.datagouv.list
S3_BUCKET = ${DATAGOUV_DATASET}
S3_CATALOG = ${DATA_DIR}/${DATAGOUV_DATASET}.s3.list
S3_CONFIG = s3_scaleway.conf
DATAPREP_VERSION := $(shell cat projects/deces-dataprep/recipes/deces_dataprep.yml projects/deces-dataprep/datasets/deces_index.yml  | sha1sum | awk '{print $1}' | cut -c-8)
SSHID=matchid@matchid.project.gmail.com
SSHKEY_PRIVATE = ${HOME}/.ssh/id_rsa_${APP}
SSHKEY = ${SSHKEY_PRIVATE}.pub
SSHKEYNAME = ${APP}
OS_TIMEOUT = 60
SCW_SERVER_FILE_ID=scw.id
SCW_TIMEOUT= 180
AWS=${PWD}/aws
EC2_PROFILE=default
EC2=ec2 ${EC2_ENDPOINT_OPTION} --profile ${EC2_PROFILE}
EC2_SERVER_FILE_ID=${PWD}/ec2.id
EC2_TIMEOUT= 120
CLOUD=SCW
SSHOPTS=-o "StrictHostKeyChecking no" -i ${SSHKEY} ${CLOUD_SSHOPTS}

dummy               := $(shell touch artifacts)
include ./artifacts

config: ${GITBACKEND}
	@echo checking system prerequisites
	@${MAKE} -C ${GITBACKEND} install-prerequisites
	@sudo apt-get install -yq jq curl
	@${MAKE} -C ${GITBACKEND} register-secrets
	@echo "prerequisites installed" > config

docker-post-config:
	@${MAKE} -C ${GITBACKEND} backend-docker-pull
	@docker pull matchid/tools

${DATA_DIR}:
	@if [ ! -d "${DATA_DIR}" ]; then mkdir -p ${DATA_DIR};fi

${DATAGOUV_CATALOG}: config ${DATA_DIR}
	@echo getting ${DATAGOUV_DATASET} catalog from data.gouv API ${DATAGOUV_API}
	@curl -s --fail ${DATAGOUV_API}/${DATAGOUV_DATASET}/ | \
		jq  -cr '.resources[] | .title + " " +.checksum.value + " " + .url' | sort > ${DATAGOUV_CATALOG}

datagouv-get-catalog: ${DATAGOUV_CATALOG}

datagouv-get-files: ${DATAGOUV_CATALOG}
	@if [ -s "${S3_CATALOG}" ]; then\
		(echo egrep -v $$(cat ${S3_CATALOG} | sed 's/\r//g' | tr '\n' '|' | sed 's/.gz//g;s/^/"(/;s/|$$/)"/') ${DATAGOUV_CATALOG} | sh > ${DATA_DIR}/tmp.list) || true;\
	else\
		cp ${DATAGOUV_CATALOG} ${DATA_DIR}/tmp.list;\
	fi

	@if [ -s "${DATA_DIR}/tmp.list" ]; then\
		i=0;\
		for file in $$(awk '{print $$1}' ${DATA_DIR}/tmp.list); do\
			if [ ! -f ${DATA_DIR}/$$file.gz.sha1 ]; then\
				echo getting $$file ;\
				grep $$file ${DATA_DIR}/tmp.list | awk '{print $$3}' | xargs curl -s > ${DATA_DIR}/$$file; \
				grep $$file ${DATA_DIR}/tmp.list | awk '{print $$2}' > ${DATA_DIR}/$$file.sha1.src; \
				sha1sum < ${DATA_DIR}/$$file | awk '{print $$1}' > ${DATA_DIR}/$$file.sha1.dst; \
				((diff ${DATA_DIR}/$$file.sha1.src ${DATA_DIR}/$$file.sha1.dst > /dev/null) || echo error downloading $$file); \
				gzip ${DATA_DIR}/$$file; \
				sha1sum ${DATA_DIR}/$$file.gz > ${DATA_DIR}/$$file.gz.sha1; \
				((i++));\
			fi;\
		done;\
		if [ "$$i" == "0" ]; then\
			echo no new file downloaded from datagouv;\
		else\
			echo "$$i file(s) donwloaded from datagouv";\
		fi;\
	else\
		echo no new file downloaded from datagouv;\
	fi

${S3_CATALOG}: config ${DATA_DIR}
	@echo getting ${S3_BUCKET} catalog from s3 API
	@${AWS} s3 ls ${S3_BUCKET} | awk '{print $$NF}' | egrep '${FILES_TO_SYNC}' | sort > ${S3_CATALOG}

s3-get-catalog: ${S3_CATALOG}

datagouv-to-s3: s3-get-catalog datagouv-get-files
	@for file in $$(ls ${DATA_DIR} | egrep '${FILES_TO_SYNC}');do\
		${AWS} s3 cp ${DATA_DIR}/$$file s3://${S3_BUCKET}/$$file;\
		${AWS} s3api put-object-acl --acl public-read --bucket ${S3_BUCKET} --key $$file && echo $$file acl set to public;\
	done
	@touch datagouv-to-s3

${GITBACKEND}:
	@echo configuring matchID
	@${GIT} clone ${GITROOT}/${GITBACKEND}
	@cp artifacts ${GITBACKEND}/artifacts
	@cp docker-compose-local.yml ${GITBACKEND}/docker-compose-local.yml
	@echo "export ES_NODES=1" >> ${GITBACKEND}/artifacts
	@echo "export PROJECTS=${PWD}/projects" >> ${GITBACKEND}/artifacts
	@echo "export S3_BUCKET=${S3_BUCKET}" >> ${GITBACKEND}/artifacts

dev: config docker-post-config
	${MAKE} -C ${GITBACKEND} frontend-build backend elasticsearch frontend

dev-stop:
	${MAKE} -C ${GITBACKEND} frontend-stop backend-stop elasticsearch-stop

up:
	${MAKE} -C ${GITBACKEND} elasticsearch wait-elasticsearch backend wait-backend

recipe-run: s3.tag
	@if [ ! -f "recipe-run" ];then\
		${MAKE} up;\
		echo running recipe on full data;\
		${MAKE} -C ${GITBACKEND} recipe-run RECIPE=${RECIPE} RECIPE_THREADS=${RECIPE_THREADS} RECIPE_QUEUE=${RECIPE_QUEUE} &&\
			touch recipe-run s3-pull &&\
			(echo esdata_${DATAPREP_VERSION}_$$(cat s3.tag).tar > elasticsearch-restore);\
	fi

full-check: datagouv-to-s3 s3-backup-list
	@if [ -s s3-backup-list ]; then\
		echo recipe has already been runned on full and saved on s3;\
		touch recipe-run watch-run backup s3-push no-remote;\
	fi

full: diff-check full-check recipe-run
	@touch full

recipe-run-diff: s3-diff.tag
	@if [ ! -f "recipe-run-diff" ];then\
		${MAKE} up;\
		echo running recipe on diff;\
		rm -f elasticsearch-restore watch-run;\
		${MAKE} -C ${GITBACKEND} recipe-run RECIPE=${RECIPE} RECIPE_THREADS=${RECIPE_THREADS} RECIPE_QUEUE=${RECIPE_QUEUE} FILES_TO_PROCESS=${FILES_TO_PROCESS_DIFF}\
			&& touch recipe-run-diff;\
	fi

diff-check: datagouv-to-s3 s3-backup-list-diff
	@if [ -s s3-backup-list-diff ]; then\
		echo diff recipe has already been runned and saved on s3;\
		touch elasticsearch-restore full recipe-run backup s3-push \
			s3-pull recipe-run-diff watch-run backup-diff s3-push-diff;\
	fi;

wait-recipe-diff-up:
	@timeout=10 ; ret=1 ; \
	until [ "$$timeout" -le 0 -o "$$ret" -eq "0"  ] ; do \
		f=$$(find ${GITBACKEND}/log/ -iname '*${RECIPE}*' | sort | tail -1);\
		if [ -z "$$f" ] ; then \
			echo "waiting for start of job $$timeout" ; \
			sleep 1 ;\
		else\
			ret=0;\
		fi ; ((timeout--)); done ; exit $$ret;
	@echo "recipe properly launched"

diff: diff-check elasticsearch-restore recipe-run-diff
	@touch diff

backend-clean-logs:
	rm -f ${PWD}/${GITBACKEND}/log/*${RECIPE}*log

ls:
	@echo iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii
	@ls | grep watch-run || true
	@echo yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy

watch-run:
	@timeout=${TIMEOUT} ; ret=1 ; \
		until [ "$$timeout" -le 0 -o "$$ret" -eq "0"  ] ; do \
			f=$$(find ${GITBACKEND}/log/ -iname '*${RECIPE}*' | sort | tail -1);\
			((tail $$f | grep "end of all" > /dev/null) || exit 1) ; \
			ret=$$? ; \
			if [ "$$ret" -ne "0" ] ; then \
				echo "waiting for end of job $$timeout" ; \
				grep wrote $$f |awk 'BEGIN{s=0}{t=$$4;s+=$$12}END{print t " wrote " s}' ;\
				sleep 10 ;\
			fi ; ((timeout--)); done ; exit $$ret
	@find ${GITBACKEND}/log/ -iname '*dataprep_personnes-dedecees_search*' | sort | tail -1 | xargs tail

watch-run-diff:
	@if [ ! -s s3-backup-list ];then\
		timeout=${TIMEOUT} ; ret=1 ; \
			until [ "$$timeout" -le 0 -o "$$ret" -eq "0"  ] ; do \
				f=$$(find ${GITBACKEND}/log/ -iname '*${RECIPE}*' | sort | tail -1);\
				((tail $$f | grep "end of all" > /dev/null) || exit 1) ; \
				ret=$$? ; \
				if [ "$$ret" -ne "0" ] ; then \
					echo "waiting for end of job $$timeout" ; \
					grep wrote $$f |awk 'BEGIN{s=0}{t=$$4;s+=$$12}END{print t " wrote " s}' ;\
					sleep 10 ;\
				fi ; ((timeout--)); done ; exit $$ret;\
		(find ${GITBACKEND}/log/ -iname '*dataprep_personnes-dedecees_search*' | sort | tail -1 | xargs tail);\
	fi


s3.tag:
	@${AWS} s3 ls ${S3_BUCKET} | egrep '${FILES_TO_PROCESS}' | awk '{print $$NF}' | sort | sed 's/\s*$$//'| sha1sum | awk '{print $1}' | cut -c-8 > s3.tag

s3-diff.tag:
	@${AWS} s3 ls ${S3_BUCKET} | egrep '${FILES_TO_PROCESS_DIFF}' | awk '{print $$NF}' | sort | sed 's/\s*$$//'| sha1sum | awk '{print $1}' | cut -c-8 > s3-diff.tag

s3-backup-list: s3.tag
	@(${AWS} s3 ls ${S3_BUCKET} | awk '{print $$NF}' | grep esdata_${DATAPREP_VERSION}_$$(cat s3.tag).tar > /dev/null)\
		&& ((echo esdata_${DATAPREP_VERSION}_$$(cat s3.tag).tar > s3-backup-list) && touch backup s3-push)\
		|| touch s3-backup-list

s3-backup-list-diff: s3.tag s3-diff.tag
	@(${AWS} s3 ls ${S3_BUCKET} | awk '{print $$NF}' | grep esdata_${DATAPREP_VERSION}_$$(cat s3.tag)_$$(cat s3-diff.tag).tar > /dev/null)\
		&& ((echo esdata_${DATAPREP_VERSION}_$$(cat s3.tag)_$$(cat s3-diff.tag).tar > s3-backup-list-diff) && touch backup-diff s3-push-diff)\
		|| touch s3-backup-list-diff

s3-pull:
	@if [ ! -f "s3-pull" ];then\
		ES_BACKUP_FILE=esdata_${DATAPREP_VERSION}_$$(cat s3.tag).tar;\
		ES_BACKUP_FILE_SNAR=esdata_${DATAPREP_VERSION}_$$(cat s3.tag).snar;\
		if [ ! -f "${BACKUP_DIR}/$$ES_BACKUP_FILE" ];then\
				echo pulling s3://${S3_BUCKET}/$$ES_BACKUP_FILE;\
				${AWS} s3 cp s3://${S3_BUCKET}/$$ES_BACKUP_FILE ${BACKUP_DIR}/$$ES_BACKUP_FILE;\
				${AWS} s3 cp s3://${S3_BUCKET}/$$ES_BACKUP_FILE_SNAR ${BACKUP_DIR}/$$ES_BACKUP_FILE_SNAR;\
		fi;\
	fi

elasticsearch-restore: s3-pull
	@if [ ! -f "elasticsearch-restore" ];then\
		${MAKE} -C ${GITBACKEND} elasticsearch-restore ES_BACKUP_FILE=esdata_${DATAPREP_VERSION}_$$(cat s3.tag).tar \
			&& (echo esdata_${DATAPREP_VERSION}_$$(cat s3.tag).tar > elasticsearch-restore);\
	fi

backup-dir:
	mkdir -p ${BACKUP_DIR}

backup: s3.tag
	@ES_BACKUP_FILE=esdata_${DATAPREP_VERSION}_$$(cat s3.tag).tar;\
	ES_BACKUP_FILE_SNAR=esdata_${DATAPREP_VERSION}_$$(cat s3.tag).snar;\
	if [ ! -f "${BACKUP_DIR}/$$ES_BACKUP_FILE" ];then\
		${MAKE} -C ${GITBACKEND} elasticsearch-backup \
			ES_BACKUP_FILE=$$ES_BACKUP_FILE\
			ES_BACKUP_FILE_SNAR=$$ES_BACKUP_FILE_SNAR;\
	fi;\
	touch backup

backup-diff: s3-diff.tag
	@ES_BACKUP_FILE=esdata_${DATAPREP_VERSION}_$$(cat s3.tag)_$$(cat s3-diff.tag).tar;\
	ES_BACKUP_FILE_SNAR=esdata_${DATAPREP_VERSION}_$$(cat s3.tag).snar;\
	ES_BACKUP_FILE_SNAR_NEW=esdata_${DATAPREP_VERSION}_$$(cat s3.tag)_$$(cat s3-diff.tag).snar;\
	if [ ! -f "${BACKUP_DIR}/$$ES_BACKUP_FILE" ];then\
		${MAKE} -C ${GITBACKEND} elasticsearch-backup \
			ES_BACKUP_FILE=$$ES_BACKUP_FILE\
			ES_BACKUP_FILE_SNAR=$$ES_BACKUP_FILE_SNAR;\
		sudo cp ${BACKUP_DIR}/$$ES_BACKUP_FILE_SNAR ${BACKUP_DIR}/$$ES_BACKUP_FILE_SNAR_NEW;\
	fi;\
	touch backup-diff

s3-push: s3.tag backup
	${MAKE} -C ${GITBACKEND} elasticsearch-s3-push S3_BUCKET=fichier-des-personnes-decedees ES_BACKUP_FILE=esdata_${DATAPREP_VERSION}_$$(cat s3.tag).tar ES_BACKUP_FILE_SNAR=esdata_${DATAPREP_VERSION}_$$(cat s3.tag).snar

s3-push-diff: s3.tag backup-diff
	${MAKE} -C ${GITBACKEND} elasticsearch-s3-push S3_BUCKET=fichier-des-personnes-decedees ES_BACKUP_FILE=esdata_${DATAPREP_VERSION}_$$(cat s3.tag)_$$(cat s3-diff.tag).tar ES_BACKUP_FILE_SNAR=esdata_${DATAPREP_VERSION}_$$(cat s3.tag)_$$(cat s3-diff.tag).snar


${SSHKEY}:
	@echo ssh keygen
	@ssh-keygen -t rsa -b 4096 -C "${SSHID}" -f ${SSHKEY_PRIVATE} -q -N "${SSH_PASSPHRASE}"

EC2-add-sshkey:
	@(\
		((${AWS} ${EC2} describe-key-pairs --key-name ${SSHKEYNAME}  > /dev/null 2>&1) &&\
			echo "ssh key already deployed to EC2") \
	|| \
		((${AWS} ${EC2} import-key-pair --key-name ${SSHKEYNAME} --public-key-material file://${SSHKEY} > /dev/null 2>&1) &&\
			echo "ssh key deployed with success to EC2") \
	)

${EC2_SERVER_FILE_ID}:
	@((${AWS} ${EC2} run-instances --key-name ${SSHKEYNAME} \
		 	--image-id ${EC2_IMAGE_ID} --instance-type ${EC2_FLAVOR_TYPE} \
			--tag-specifications "Tags=[{Key=Name,Value=${APP}}]" | jq -r '.Instances[0].InstanceId' > ${EC2_SERVER_FILE_ID} 2>&1 \
		 ) &&\
			echo "EC2 instance ordered with success")

EC2-instance-order: EC2-add-sshkey ${EC2_SERVER_FILE_ID}



EC2-instance-wait-running: EC2-instance-order
	@EC2_SERVER_ID=$$(cat ${EC2_SERVER_FILE_ID});\
	timeout=${EC2_TIMEOUT} ; ret=1 ; until [ "$$timeout" -le 0 -o "$$ret" -eq "0"  ] ; do\
	  ${AWS} ${EC2} describe-instances --instance-ids $$EC2_SERVER_ID | jq -c '.Reservations[].Instances[].State.Name' | (grep running > /dev/null);\
	  ret=$$? ; \
	  if [ "$$ret" -ne "0" ] ; then echo "waiting for EC2 instance $$EC2_SERVER_ID to start $$timeout" ; fi ;\
	  ((timeout--)); sleep 1 ; \
    done ; exit $$ret

EC2-instance-wait-ssh: EC2-instance-wait-running
	@EC2_SERVER_ID=$$(cat ${EC2_SERVER_FILE_ID});\
	HOST=$$(${AWS} ${EC2} describe-instances --instance-ids $$EC2_SERVER_ID |\
		jq -r ".Reservations[].Instances[].${EC2_IP}");\
	(ssh-keygen -R $$HOST > /dev/null 2>&1) || true;\
	timeout=${EC2_TIMEOUT} ; ret=1 ; until [ "$$timeout" -le 0 -o "$$ret" -eq "0"  ] ; do\
	  ((ssh ${SSHOPTS} ${EC2_SSHUSER}@$$HOST sleep 1) > /dev/null 2>&1);\
	  ret=$$? ; \
	  if [ "$$ret" -ne "0" ] ; then echo "waiting for ssh service on EC2 instance $$EC2_SERVER_ID - $$timeout" ; fi ;\
	  ((timeout--)); sleep 1 ; \
    done ; exit $$ret

EC2-instance-wait: EC2-instance-wait-ssh

EC2-instance-delete:
	@if [ -f "${EC2_SERVER_FILE_ID}" ];then\
		EC2_SERVER_ID=$$(cat ${EC2_SERVER_FILE_ID});\
		${AWS} ${EC2} terminate-instances --instance-ids $$EC2_SERVER_ID |\
			jq -r '.TerminatingInstances[0].CurrentState.Name' | sed 's/$$/ EC2 instance/';\
	fi
	@rm ${EC2_SERVER_FILE_ID} > /dev/null 2>&1 | true;

OS-add-sshkey: ${SSHKEY}
	@(\
		(nova keypair-list | sed 's/|//g' | egrep -v '\-\-\-|Name' | (egrep '^\s*${SSHKEYNAME}\s' > /dev/null) &&\
		 echo "ssh key already deployed to openstack" ) \
	  || \
		(nova keypair-add --pub-key ${SSHKEY} ${SSHKEYNAME} &&\
		 nova keypair-list | sed 's/|//g' | egrep -v '\-\-\-|Name' | (egrep '^\s*${SSHKEYNAME}\s' > /dev/null) &&\
		 echo "ssh key deployed with success to openstack" ) \
	  )

OS-instance-order: OS-add-sshkey
	@(\
		(nova list | sed 's/|//g' | egrep -v '\-\-\-|Name' | (egrep '\s${APP}\s' > /dev/null) && \
		echo "openstack instance already ordered")\
	 || \
		(nova boot --key-name ${SSHKEYNAME} --flavor ${OS_FLAVOR_ID} --image ${OS_IMAGE_ID} ${APP} && \
	 		echo "openstack intance ordered with success") || echo "openstance instance order failed"\
	)

OS-instance-wait-running: OS-instance-order
	@timeout=${OS_TIMEOUT} ; ret=1 ; until [ "$$timeout" -le 0 -o "$$ret" -eq "0"  ] ; do\
	  nova list | sed 's/|//g' | egrep -v '\-\-\-|Name' | (egrep '\s${APP}\s.*Running' > /dev/null) ;\
	  ret=$$? ; \
	  if [ "$$ret" -ne "0" ] ; then echo "waiting for openstack instance to start $$timeout" ; fi ;\
	  ((timeout--)); sleep 1 ; \
	done ; exit $$ret

OS-instance-wait-ssh: OS-instance-wait-running
	@HOST=$$(nova list | sed 's/|//g' | egrep -v '\-\-\-|Name' | egrep '\s${APP}\s.*Running' | sed 's/.*Ext-Net=//;s/,.*//') ;\
		(ssh-keygen -R $$HOST > /dev/null 2>&1) || true;\
		SSHUSER=${OS_SSHUSER};\
	timeout=${OS_TIMEOUT} ; ret=1 ; until [ "$$timeout" -le 0 -o "$$ret" -eq "0"  ] ; do\
	  ((ssh ${SSHOPTS} $$SSHUSER@$$HOST sleep 1) > /dev/null 2>&1);\
	  ret=$$? ; \
	  if [ "$$ret" -ne "0" ] ; then echo "waiting for ssh service on openstack instance $$SCW_SERVER_ID - $$timeout" ; fi ;\
	  ((timeout--)); sleep 1 ; \
    done ; exit $$ret

OS-instance-wait: OS-instance-wait-ssh

OS-instance-delete:
	nova delete ${APP}

${SCW_SERVER_FILE_ID}:
	@curl -s ${SCW_API}/servers -H "X-Auth-Token: ${SCW_SECRET_TOKEN}" \
		-H "Content-Type: application/json" \
		-d '{"name": "${APP}", "image": "${SCW_IMAGE_ID}", "commercial_type": "${SCW_FLAVOR}", "organization": "${SCW_ORGANIZATION_ID}"}' | jq -r '.server.id' > ${SCW_SERVER_FILE_ID}

SCW-instance-start: ${SCW_SERVER_FILE_ID}
	@SCW_SERVER_ID=$$(cat ${SCW_SERVER_FILE_ID});\
		(curl -s ${SCW_API}/servers -H "X-Auth-Token: ${SCW_SECRET_TOKEN}" | jq -cr  ".servers[] | select (.id == \"$$SCW_SERVER_ID\") | .state" | (grep running > /dev/null) && \
		echo scaleway instance already running)\
		|| \
	 	(\
			(\
				(curl -s --fail ${SCW_API}/servers/$$SCW_SERVER_ID/action -H "X-Auth-Token: ${SCW_SECRET_TOKEN}" \
					-H "Content-Type: application/json" -d '{"action": "poweron"}' > /dev/null) &&\
				echo scaleway instance starting\
			) || echo scaleway instance still starting\
		)

SCW-instance-wait-running: SCW-instance-start
	@SCW_SERVER_ID=$$(cat ${SCW_SERVER_FILE_ID});\
	timeout=${SCW_TIMEOUT} ; ret=1 ; until [ "$$timeout" -le 0 -o "$$ret" -eq "0"  ] ; do\
	  curl -s ${SCW_API}/servers -H "X-Auth-Token: ${SCW_SECRET_TOKEN}" | jq -cr  ".servers[] | select (.id == \"$$SCW_SERVER_ID\") | .state" | (grep running > /dev/null);\
	  ret=$$? ; \
	  if [ "$$ret" -ne "0" ] ; then echo "waiting for scaleway instance $$SCW_SERVER_ID to start $$timeout" ; fi ;\
	  ((timeout--)); sleep 1 ; \
    done ; exit $$ret

SCW-instance-wait-ssh: SCW-instance-wait-running
	@SCW_SERVER_ID=$$(cat ${SCW_SERVER_FILE_ID});\
	HOST=$$(curl -s ${SCW_API}/servers -H "X-Auth-Token: ${SCW_SECRET_TOKEN}" | jq -cr  ".servers[] | select (.id == \"$$SCW_SERVER_ID\") | .${SCW_IP}" ) ;\
	(ssh-keygen -R $$HOST > /dev/null 2>&1) || true;\
	timeout=${SCW_TIMEOUT} ; ret=1 ; until [ "$$timeout" -le 0 -o "$$ret" -eq "0"  ] ; do\
	  ((ssh ${SSHOPTS} root@$$HOST sleep 1) > /dev/null 2>&1);\
	  ret=$$? ; \
	  if [ "$$ret" -ne "0" ] ; then echo "waiting for ssh service on scaleway instance $$SCW_SERVER_ID - $$timeout" ; fi ;\
	  ((timeout--)); sleep 1 ; \
    done ; exit $$ret

SCW-instance-wait: SCW-instance-wait-ssh


SCW-instance-delete:
	@if [ -f "${SCW_SERVER_FILE_ID}" ];then\
		SCW_SERVER_ID=$$(cat ${SCW_SERVER_FILE_ID});\
		((curl -s --fail ${SCW_API}/servers/$$SCW_SERVER_ID/action -H "X-Auth-Token: ${SCW_SECRET_TOKEN}" \
			-H "Content-Type: application/json" -d '{"action": "terminate"}' > /dev/null) && \
			echo scaleway server terminating) ||\
		echo scaleway error while terminating server;\
		rm ${SCW_SERVER_FILE_ID};\
	else\
		echo no scw.id for deletion;\
	fi

down:
	${MAKE} -C ${GITBACKEND} backend-stop elasticsearch-stop frontend-stop || true

clean: down
	sudo rm -rf ${GITBACKEND} frontend ${DATA_DIR} s3.tag config \
		recipe-run recipe-run-diff s3-backup-list s3-backup-list-diff elasticsearch-restore watch-run full diff\
		backup backup-diff s3-pull s3-pull no-remote

# launch all locally
# configure
all-step0: ${GITBACKEND} config

# first step should be 4 to 10 hours if not already runned (can't be travis-ed)
all-step1: docker-post-config full

# second step is backup, diff run and <5 minutes (can be travis-ed
all-step2: s3-push

all-step3: backend-clean-logs diff watch-run-diff s3-push-diff

all: all-step0 all-step1 watch-run all-step2
	@echo ended with succes !!!

# launch remote

remote-config: ${CLOUD}-instance-wait
	@if [ "${CLOUD}" == "OS" ];then\
		HOST=$$(nova list | sed 's/|//g' | egrep -v '\-\-\-|Name' | egrep '\s${APP}\s.*Running' | sed 's/.*Ext-Net=//;s/,.*//') ;\
		(ssh-keygen -R $$HOST > /dev/null 2>&1) || true;\
		SSHUSER=${OS_SSHUSER};\
	elif [ "${CLOUD}" == "EC2" ];then\
		EC2_SERVER_ID=$$(cat ${EC2_SERVER_FILE_ID});\
		HOST=$$(${AWS} ${EC2} describe-instances --instance-ids $$EC2_SERVER_ID |\
				jq -r ".Reservations[].Instances[].${EC2_IP}");\
		(ssh-keygen -R $$HOST > /dev/null 2>&1) || true;\
		SSHUSER=${EC2_SSHUSER};\
	else\
		SCW_SERVER_ID=$$(cat ${SCW_SERVER_FILE_ID});\
		HOST=$$(curl -s ${SCW_API}/servers -H "X-Auth-Token: ${SCW_SECRET_TOKEN}" | jq -cr  ".servers[] | select (.id == \"$$SCW_SERVER_ID\") | .${SCW_IP}" ) ;\
		(ssh-keygen -R $$HOST > /dev/null 2>&1) || true;\
		SSHUSER=${SCW_SSHUSER};\
		ssh ${SSHOPTS} root@$$HOST apt-get install -o Dpkg::Options::="--force-confold" -yq sudo;\
	fi;\
		ssh ${SSHOPTS} $$SSHUSER@$$HOST git clone ${GITROOT}/${APP};\
		ssh ${SSHOPTS} $$SSHUSER@$$HOST sudo apt-get update -y;\
		ssh ${SSHOPTS} $$SSHUSER@$$HOST sudo apt-get install -y make;\
		ssh ${SSHOPTS} $$SSHUSER@$$HOST make -C ${APP} all-step0 ${MAKEOVERRIDES};

remote-step1:
	@if [ "${CLOUD}" == "OS" ];then\
		HOST=$$(nova list | sed 's/|//g' | egrep -v '\-\-\-|Name' | egrep '\s${APP}\s.*Running' | sed 's/.*Ext-Net=//;s/,.*//') ;\
		SSHUSER=${OS_SSHUSER};\
	elif [ "${CLOUD}" == "EC2" ];then\
		EC2_SERVER_ID=$$(cat ${EC2_SERVER_FILE_ID});\
		HOST=$$(${AWS} ${EC2} describe-instances --instance-ids $$EC2_SERVER_ID |\
				jq -r ".Reservations[].Instances[].${EC2_IP}");\
		SSHUSER=${EC2_SSHUSER};\
	else\
		SCW_SERVER_ID=$$(cat ${SCW_SERVER_FILE_ID});\
		HOST=$$(curl -s ${SCW_API}/servers -H "X-Auth-Token: ${SCW_SECRET_TOKEN}" | jq -cr  ".servers[] | select (.id == \"$$SCW_SERVER_ID\") | .${SCW_IP}" ) ;\
		SSHUSER=${SCW_SSHUSER};\
	fi;\
		ssh ${SSHOPTS} $$SSHUSER@$$HOST 'echo "export FILES_TO_PROCESS=${FILES_TO_PROCESS}" > ${APP}/artifacts';\
		ssh ${SSHOPTS} $$SSHUSER@$$HOST mkdir -p .aws;\
		cat ${S3_CONFIG} | ${REMOTE_HOST} ssh ${SSHOPTS} $$SSHUSER@$$HOST "cat > .aws/config";\
		echo -e "[default]\naws_access_key_id=${aws_access_key_id}\naws_secret_access_key=${aws_secret_access_key}\n" |\
			ssh ${SSHOPTS} $$SSHUSER@$$HOST 'cat > .aws/credentials';\
		ssh ${SSHOPTS} $$SSHUSER@$$HOST make -C ${APP} all-step1 aws_access_key_id=${aws_access_key_id} aws_secret_access_key=${aws_secret_access_key} ${MAKEOVERRIDES};

remote-watch:
	@if [ "${CLOUD}" == "OS" ];then\
		HOST=$$(nova list | sed 's/|//g' | egrep -v '\-\-\-|Name' | egrep '\s${APP}\s.*Running' | sed 's/.*Ext-Net=//;s/,.*//') ;\
		SSHUSER=${OS_SSHUSER};\
	elif [ "${CLOUD}" == "EC2" ];then\
		EC2_SERVER_ID=$$(cat ${EC2_SERVER_FILE_ID});\
		HOST=$$(${AWS} ${EC2} describe-instances --instance-ids $$EC2_SERVER_ID |\
				jq -r ".Reservations[].Instances[].${EC2_IP}");\
		SSHUSER=${EC2_SSHUSER};\
	else\
		SCW_SERVER_ID=$$(cat ${SCW_SERVER_FILE_ID});\
		HOST=$$(curl -s ${SCW_API}/servers -H "X-Auth-Token: ${SCW_SECRET_TOKEN}" | jq -cr  ".servers[] | select (.id == \"$$SCW_SERVER_ID\") | .${SCW_IP}" ) ;\
		SSHUSER=${SCW_SSHUSER};\
	fi;\
		ssh ${SSHOPTS} $$SSHUSER@$$HOST make -C ${APP} watch-run ${MAKEOVERRIDES};

remote-step2: remote-watch
	@if [ "${CLOUD}" == "OS" ];then\
		HOST=$$(nova list | sed 's/|//g' | egrep -v '\-\-\-|Name' | egrep '\s${APP}\s.*Running' | sed 's/.*Ext-Net=//;s/,.*//') ;\
		SSHUSER=${OS_SSHUSER};\
	elif [ "${CLOUD}" == "EC2" ];then\
		EC2_SERVER_ID=$$(cat ${EC2_SERVER_FILE_ID});\
		HOST=$$(${AWS} ${EC2} describe-instances --instance-ids $$EC2_SERVER_ID |\
				jq -r ".Reservations[].Instances[].${EC2_IP}");\
		SSHUSER=${EC2_SSHUSER};\
	else\
		SCW_SERVER_ID=$$(cat ${SCW_SERVER_FILE_ID});\
		HOST=$$(curl -s ${SCW_API}/servers -H "X-Auth-Token: ${SCW_SECRET_TOKEN}" | jq -cr  ".servers[] | select (.id == \"$$SCW_SERVER_ID\") | .${SCW_IP}" ) ;\
		SSHUSER=${SCW_SSHUSER};\
	fi;\
		ssh ${SSHOPTS} $$SSHUSER@$$HOST make -C ${APP} all-step2 aws_access_key_id=${aws_access_key_id} aws_secret_access_key=${aws_secret_access_key} ${MAKEOVERRIDES};\
		ssh ${SSHOPTS} $$SSHUSER@$$HOST rm .aws/credentials;

remote-clean: ${CLOUD}-instance-delete

remote-all: full-check
	@if [ ! -f "no-remote" ];then\
		${MAKE} remote-config remote-step1 remote-watch remote-step2 remote-clean;\
	fi

