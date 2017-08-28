#!/bin/sh

# Script is supposed to be run on cicd leader node (for ex.: cfg01)
# Joins gluster and swarm cluster

CICD_DEPLOYED="/root/cicd_deployed"

# Check
if [ -e $CICD_DEPLOYED ]; then
  error "CICD cluster was already deployed. If you want to deploy it again delete $CICD_DEPLOYED file and run the script again."
fi

echo "preparing kvm nodes"
# launch all vms
salt -C '*' saltutil.refresh_pillar
salt -C '*' saltutil.sync_all
salt 'kvm03*' cmd.shell 'virsh destroy cid03.deploy-name.local; virsh undefine cid03.deploy-name.local'
salt 'kvm02*' cmd.shell 'virsh destroy cid02.deploy-name.local; virsh undefine cid02.deploy-name.local'
salt-key -d cid03.deploy-name.local -y
salt-key -d cid02.deploy-name.local -y

echo "launching virtual machines"
salt -C 'I@salt:control' state.sls salt.control

apt update
service salt-minion restart

echo "initializing new docker swarm cluster"
rm /var/lib/docker/swarm/docker-state.json
rm /var/lib/docker/swarm/state.json
salt-call state.sls docker.host
salt-call state.sls docker.swarm
# cd /etc/docker/compose/docker/
# docker stack deploy --compose-file docker-compose.yml docker
# cd /etc/docker/compose/aptly/
# docker stack deploy --compose-file docker-compose.yml aptly
# cd /etc/docker/compose/ldap/
# docker stack deploy --compose-file docker-compose.yml ldap
# cd /etc/docker/compose/gerrit/
# docker stack deploy --compose-file docker-compose.yml gerrit
# cd /etc/docker/compose/jenkins/
# docker stack deploy --compose-file docker-compose.yml jenkins
# cd /etc/docker/compose/aptly/
# docker stack deploy --compose-file docker-compose.yml aptly

sleep 200

echo "deploy the rest of cicd nodes"
salt -C 'cid*' saltutil.refresh_pillar
salt -C 'cid*' saltutil.sync_all
salt -t 2 -C 'cid*' state.sls salt.minion
salt -C 'cid*' state.sls salt.minion,linux,openssh,ntp

echo "deploy gluster on cicd nodes"
salt -C 'cid*' state.sls glusterfs.server.service
salt-call state.sls glusterfs.server

echo "add bricks to gluster"
#volumes=`gluster volume list` cannot be used if stacklight is in place
volumes="aptly gerrit jenkins mysql openldap registry salt_pki"
cid02=`salt-call pillar.data _param:cluster_node02_address | sed -n 4p`
cid03=`salt-call pillar.data _param:cluster_node03_address | sed -n 4p`
for vol_name in $volumes; do gluster volume add-brick $vol_name replica 2 $cid02:/srv/glusterfs/$vol_name force; done
for vol_name in $volumes; do gluster volume add-brick $vol_name replica 3 $cid03:/srv/glusterfs/$vol_name force; done
salt -t 2 -C 'I@docker:swarm' state.sls glusterfs.client

echo "join docker swarm"
salt -t 2 -C 'cid*' state.sls keepalived,haproxy
salt -t 2 -C 'cid*' state.sls docker.host
salt -t 2 -C 'I@docker:swarm' state.sls salt
salt -t 2 -C 'I@docker:swarm' mine.flush
salt -t 2 -C 'I@docker:swarm' mine.update
salt -C 'cid*' state.sls docker.swarm
sleep 10

echo "launch containers"
salt-call state.sls docker.client
salt -C 'cid*' state.sls aptly
#salt -t 2 -C 'I@docker:swarm' cmd.shell 'systemctl restart docker' 

# create a flag file about cicd cluster deployment
touch $CICD_DEPLOYED
