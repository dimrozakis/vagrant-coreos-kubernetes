Vagrant + CoreOS + Kubernetes
=============================

Some helper scripts arround the single and multi node vagrant setup of
https://github.com/coreos/coreos-kubernetes.


Getting started
---------------

Clone the repo with:
```
git clone --recursive https://github.com/dimrozakis/vagrant-coreos-kubernetes
```

If you forgot to specify `--recursive` during cloning, then afterwards run:
```
git submodule init
git submodule update
```

You will also need to install vagrant and virtualbox.

By default this will start a multi node cluster with one controller, one etcd
and three workers. You can edit the configuration by copying (and optionally
editing) either `env-multi.sh` or `env-single.sh` to `env.sh`.

To initialize the environment, run `./bin/init`.


SSH
---

The command `vagrant ssh` uses the NAT interfaces of the virtualbox vm's which
are a lot slower than the private network interfaces and ocasionally tend to
freeze. Upon initialization, an SSH config file is generated in
`tmp/ssh-config` that uses the private network to connect to machines via SSH.

In single node mode simply run `./bin/ssh_vm [command]`.

In multi node mode, run `./bin/ssh_vm <vm> [command]`.

There's also `./bin/ssh_workers [command]` that will basically run
`./bin/ssh_vm` for every worker node. In single node mode, this is the same as
`./bin/ssh_vm`.


Docker images
-------------

The command `./bin/pull image ..` will put the specified images on the local
docker registries of each worker in the cluster.

If a docker daemon is running locally, then it will pull the image there,
export it as a tarball and load it on every worker. Otherwise, in a multi node
environment, it will use the first worker to actually pull the image, export it
and import it to all other nodes. This way, each image is only downloaded once
for each cluster. And if a local docker daemon is used, you don't need to
download it again even if you delete and recreate the cluster.

The command `./bin/push image` will push a local image tarball accross the
cluster.


Resetting
---------

If you ever need to change the configuration in `env.sh`, run `vagrant destroy`
before and `./bin/init` afterwards.
