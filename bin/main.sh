#!/bin/bash


set -e


BASE_DIR="$( dirname "$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )" )"

K8S_VERSION=v1.1.1

source $BASE_DIR/env-multi.sh
if [ -f $BASE_DIR/env.sh ]; then source $BASE_DIR/env.sh; fi

if [ $MODE = single ]; then
    VAGRANT_DIR=$BASE_DIR/coreos-kubernetes/single-node
    WORKERS=1
else
    VAGRANT_DIR=$BASE_DIR/coreos-kubernetes/multi-node/vagrant
fi

TMP_DIR=$BASE_DIR/tmp
SSH_CONFIG=$TMP_DIR/ssh-config
KUBECTL=$BASE_DIR/bin/kubectl
KUBE_CONTEXT="$( basename $BASE_DIR )"
[[ "$OSTYPE" == "darwin"* ]] && ARCH=darwin || ARCH=linux


cd $BASE_DIR
mkdir -p $TMP_DIR


error() { >&2 echo $@; }


conf_vagrant() {
    cat > $BASE_DIR/Vagrantfile << EOF
Dir.chdir "$VAGRANT_DIR"
load("Vagrantfile")
EOF
    if [ $MODE != single ]; then
        echo "Configuring vagrant vm settings..."
        cat > $VAGRANT_DIR/config.rb << EOF
\$update_channel="alpha"

\$controller_count=$CONTROLLERS
\$controller_vm_memory=$CONTROLLERS_MEM

\$worker_count=$WORKERS
\$worker_vm_memory=$WORKERS_MEM

\$etcd_count=$ETCD
\$etcd_vm_memory=$ETCD_MEM
EOF
    fi
}


get_kubectl() {
    echo "Downloading kubectl..."
    wget -c -O $KUBECTL \
        https://storage.googleapis.com/kubernetes-release/release/$K8S_VERSION/bin/$ARCH/amd64/kubectl
    chmod +x $KUBECTL
    echo "Configuring kubectl..."
    [ $MODE = single ] && server=172.17.4.99 || server=172.17.4.101
    $KUBECTL config set-cluster vagrant \
        --server=https://$server:443 \
        --certificate-authority=$VAGRANT_DIR/ssl/ca.pem
    $KUBECTL config set-credentials vagrant-admin \
        --certificate-authority=$VAGRANT_DIR/ssl/ca.pem \
        --client-key=$VAGRANT_DIR/ssl/admin-key.pem \
        --client-certificate=$VAGRANT_DIR/ssl/admin.pem
    $KUBECTL config set-context $KUBE_CONTEXT \
        --cluster=vagrant \
        --user=vagrant-admin
    $KUBECTL config use-context $KUBE_CONTEXT
}


wait_kube() {
    if ! $KUBECTL get nodes > /dev/null 2>&1; then
        echo -n "Waiting for Kubernetes API..."
        while ! $KUBECTL get nodes > /dev/null 2>&1; do
            echo -n "."; sleep 1;
        done
        echo
    fi
    echo "Kubernetes API is up."

    count=`$KUBECTL get nodes | tail -n +2 | wc -l`
    if [ "$count" -lt "$WORKERS" ]; then
        echo -n "Waiting for the $WORKERS kubernetes workers to come up..."
        while [ "$count" -lt "$WORKERS" ]; do
            sleep 1
            new_count=`$KUBECTL get nodes | tail -n +2 | wc -l`
            if [ "$count" -lt "$new_count" ]; then
                echo -n $new_count
                count=$new_count
            else
                echo -n "."
            fi
        done
        echo
    fi
    echo "All nodes connected to cluster."
    $KUBECTL get nodes

    echo
    echo "Pods..."
    $KUBECTL get pods --all-namespaces -o=wide
}


ssh_config() {
    echo "Configuring ssh config to connect to hosts over private ips..."
    key=`vagrant ssh-config 2>/dev/null | grep IdentityFile | head -n 1 | awk '{print $2}'`
    cat > $SSH_CONFIG << EOF
User core
Port 22
UserKnownHostsFile /dev/null
StrictHostKeyChecking no
PasswordAuthentication no
IdentityFile $key
IdentitiesOnly yes
LogLevel FATAL

EOF
    if [ $MODE = single ]; then
        cat >> $SSH_CONFIG << EOF
Host default
  Hostname 172.17.4.99
EOF
        return 0
    fi
    for i in `seq 1 $ETCD`; do
        cat >> $SSH_CONFIG << EOF
Host e$i
  HostName 172.17.4.5$i
EOF
    done
    for i in `seq 1 $CONTROLLERS`; do
        cat >> $SSH_CONFIG << EOF
Host c$i
  HostName 172.17.4.10$i
EOF
    done
    for i in `seq 1 $WORKERS`; do
        cat >> $SSH_CONFIG << EOF
Host w$i
  HostName 172.17.4.20$i
EOF
    done
}


ssh_vm() {
    if [ ! -f $SSH_CONFIG ]; then
        error "No ssh config found, run ssh_config to generate it."
        return 1
    fi
    if [ $MODE = single ]; then
        vm=default
    else
        [ -z "$1" ] && error "Call to ssh_vm with no vm specified" && return 1
        vm=$1
        shift
    fi
    cmd=$@
    error "Running command \"$cmd\" to vm $worker..."
    ssh -F $SSH_CONFIG $vm -C $cmd
}


ssh_workers() {
    if [ $MODE = single ]; then
        ssh_vm $@
    else
        for i in `seq 1 $WORKERS`; do ssh_vm w$i $@; done
    fi
}


local_docker() {
    which docker > /dev/null && docker info > /dev/null 2>&1 || return 1
}


pull() {
    [ -z "$1" ] && error "No image specified to pull." && return 1
    for image in $@; do
        file=$TMP_DIR/$image.tar
        mkdir -p `dirname $file`
        if local_docker; then
            echo "Pulling image $image using local docker daemon..."
            docker pull $image
            echo "Saving $image as $file in host..."
            docker save $image > $file
            from=1
        elif [ $MODE = single ]; then
            echo "Connecting to vm to pull docker image $image ..."
            ssh_vm docker pull $image
            return
        else
            echo "Connecting to w1 to pull docker image $image ..."
            ssh_vm w1 docker pull $image
            echo "Saving $image as $file in host..."
            ssh_vm w1 docker save $image > $file
            from=2
        fi
        if [ $MODE = single ]; then
            echo "Loading $image from $file to vm..."
            ssh_vm docker load < $file
        else
            for i in `seq $from $WORKERS`; do
                echo "Loading $image from $file to worker $i ..."
                ssh_vm w$i docker load < $file
            done
        fi
        echo
    done
}


push() {
    [ ! -f "$1" ] && error "No image specified to push." && return 1
    for file in $@; do
        if [ $MODE = single ]; then
            ssh_vm docker load < $file
        else
            for i in `seq 1 $WORKERS`; do
                echo "Loading image from $file to worker $i ..."
                ssh_vm w$i docker load < $file
            done
        fi
        echo
    done
}


init() {
    conf_vagrant
    echo
    echo "Running vagrant up..."
    vagrant up
    echo
    ssh_config
    echo
    get_kubectl
    echo
    wait_kube
}


cmd=`basename -s.sh ${BASH_SOURCE[0]}`
if [ $cmd != main ]; then $cmd $@; fi
