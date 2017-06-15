#!/bin/bash

set -e
set -u

RABBITMQ_IMAGE="rabbitmq"
RABBITMQ_VERSION="3-management"
RABBITMQ_CONTAINER="borges-rabbitmq"
# rabbitmq stores data according to the hostname, so we need to pass one
# to docker instead of letting docker chose a random one, that way we can
# search for the data easily.
RABBITMQ_HOSTNAME="rabbitmq-host"
RABBITMQ_PORT_INTERNAL="5672"
RABBITMQ_PORT_EXTERNAL="5672"
RABBITMQ_PORT_HTTP_INTERNAL="15672"
RABBITMQ_PORT_HTTP_EXTERNAL="8080"
RABBITMQ_RUN="docker run -d \
    --hostname ${RABBITMQ_HOSTNAME} \
    --name ${RABBITMQ_CONTAINER} \
    --publish ${RABBITMQ_PORT_EXTERNAL}:${RABBITMQ_PORT_INTERNAL} \
    --publish ${RABBITMQ_PORT_HTTP_EXTERNAL}:${RABBITMQ_PORT_HTTP_INTERNAL} \
    ${RABBITMQ_IMAGE}:${RABBITMQ_VERSION}"

POSTGRES_IMAGE="postgres"
POSTGRES_VERSION="9"
POSTGRES_CONTAINER="borges-postgres"
POSTGRES_PASSWORD="testing"
POSTGRES_USER="testing"
POSTGRES_PORT_INTERNAL=5432
POSTGRES_PORT_EXTERNAL=5432
POSTGRES_RUN="docker run -d \
    --name ${POSTGRES_CONTAINER} \
    --env POSTGRES_USER=${POSTGRES_USER} \
    --env POSTGRES_PASSWORD=${POSTGRES_PASSWORD} \
    --publish ${POSTGRES_PORT_EXTERNAL}:${POSTGRES_PORT_INTERNAL} \
    ${POSTGRES_IMAGE}:${POSTGRES_VERSION}"
POSTGRES_CLIENT="psql"
POSTGRES_CLIENT_COMMAND="CREATE TABLE IF NOT EXISTS repositories (
    id uuid PRIMARY KEY,
    created_at timestamptz,
    updated_at timestamptz,
    endpoints text[],
    status varchar(20),
    fetched_at timestamptz,
    fetch_error_at timestamptz,
    last_commit_at timestamptz,
    _references jsonb
); CREATE INDEX idx_endpoints on \"repositories\" USING GIN (\"endpoints\");"
POSTGRES_CREATE_TABLES="docker exec \
    --tty=true \
    --interactive=true \
    ${POSTGRES_CONTAINER} \
    ${POSTGRES_CLIENT} \
    --username=${POSTGRES_USER} \
    --command='${POSTGRES_CLIENT_COMMAND}'"

BORGES_INPUT="borges_input.txt"
BORGES_QUEUE="borges"
BORGES_NUM_WORKERS="2"
BORGES_RUN_PRODUCER="borges producer \
    --source=file --file=${BORGES_INPUT} \
    --broker=amqp://127.0.0.1:${RABBITMQ_PORT_EXTERNAL} \
    --queue=${BORGES_QUEUE}"
BORGES_RUN_CONSUMER="borges consumer \
    --broker=amqp://127.0.0.1:${RABBITMQ_PORT_EXTERNAL} \
    --queue=${BORGES_QUEUE} \
    --workers=${BORGES_NUM_WORKERS}"
BORGES_ARCHIVE="/tmp/root-repositories"

isRunning() {
    status=`docker inspect --format='{{.State.Status}}' --type=container $1 2>&1`
    if [ $? != 0 ] ; then
        echo ${status}
        exit
    fi
    if [ ${status} == "running" ] ; then
        return 0 # true
    else
        return 1 # false
    fi
}

exists() {
    docker inspect --type=container $1 &>/dev/null
    if [ $? == "0" ] ; then
        return 0 # true
    else
        return 1 # false
    fi
}

stop() {
    docker stop $1 1>/dev/null
}

remove() {
    if exists $1
    then
        if isRunning $1
        then
            echo [$1] stopping docker container...
            stop $1
        fi
        echo [$1] removing docker container...
        docker rm $1 1>/dev/null
    fi
}

compile_borges() {
    echo [borges] compiling and installing...
    pushd ${GOPATH}/src/github.com/src-d/borges >/dev/null
    go install ./...
    popd >/dev/null
}


restart_rabbitmq() {
    remove ${RABBITMQ_CONTAINER}
    echo [${RABBITMQ_CONTAINER}] running docker container...
    eval "${RABBITMQ_RUN}" >/dev/null
}

restart_postgres() {
    remove ${POSTGRES_CONTAINER}
    echo [${POSTGRES_CONTAINER}] running docker container...
    eval "${POSTGRES_RUN}" >/dev/null
}

wait_for_containers() {
    echo waiting for containers to boot up...
    sleep 10
}

create_tables() {
    echo [borges-postgres] creating tables...
    eval "${POSTGRES_CREATE_TABLES}" >/dev/null
}

delete_archive() {
    echo deleting archive from previous executions...
    rm -rf "${BORGES_ARCHIVE}"
}

run_producer() {
    echo [borges] running producer...
    ${BORGES_RUN_PRODUCER}
    sleep 2
}

run_consumer() {
    echo [borges] running consumer...
    ${BORGES_RUN_CONSUMER}
}


compile_borges

restart_postgres
restart_rabbitmq
wait_for_containers

create_tables
delete_archive

run_producer
run_consumer
