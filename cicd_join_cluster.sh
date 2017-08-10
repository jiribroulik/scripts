#!/bin/sh

# Script is supposed to be run on cicd leader node (for ex.: cfg01)
# Joins gluster and swarm cluster

CICD_DEPLOYED="/root/cicd_deployed"

# Check
if [ -e $CICD_DEPLOYED ]; then
  error "CICD cluster was already deployed. If you want to deploy it again delete $CICD_DEPLOYED file and run the script again."
fi

apt update
service salt-minion restart

# initialize new docker swarm cluster
rm /var/lib/docker/swarm/docker-state.json
rm /var/lib/docker/swarm/state.json
salt-call state.sls docker.swarm
cd /etc/docker/compose/docker/
docker stack deploy --compose-file docker-compose.yml docker
cd /etc/docker/compose/aptly/
docker stack deploy --compose-file docker-compose.yml aptly
cd /etc/docker/compose/ldap/
docker stack deploy --compose-file docker-compose.yml ldap
cd /etc/docker/compose/gerrit/
docker stack deploy --compose-file docker-compose.yml gerrit
cd /etc/docker/compose/jenkins/
docker stack deploy --compose-file docker-compose.yml jenkins
cd /etc/docker/compose/aptly/
docker stack deploy --compose-file docker-compose.yml aptly
cd /etc/docker/compose/ldap/
docker stack deploy --compose-file docker-compose.yml ldap

#deploy the rest of cicd nodes
salt -C 'cid*' saltutil.refresh_pillar
salt -C 'cid*' saltutil.sync_all
salt -C 'cid*' cmd.shell 'salt-call state.sls salt.minion'
salt -C 'cid*' state.sls salt.minion,linux,openssh,ntp
salt -C 'cid*' state.sls glusterfs.server.service
service salt-minion restart
salt-call state.sls glusterfs.server

# add bricks to gluster
volumes=`gluster volume list`
cid02=`salt-call pillar.data _param:cluster_node02_address | sed -n 4p`
cid03=`salt-call pillar.data _param:cluster_node03_address | sed -n 4p`
for vol_name in $volumes; do gluster volume add-brick $vol_name replica 2 $cid02:/srv/glusterfs/$vol_name force; done
for vol_name in $volumes; do gluster volume add-brick $vol_name replica 3 $cid03:/srv/glusterfs/$vol_name force; done

# join docker swarm
salt -C 'cid*' state.sls glusterfs.client
salt -C 'cid*' state.sls keepalived,haproxy
salt -C 'cid*' state.sls docker.host

salt -C 'I@docker:swarm' state.sls salt
salt -C 'I@docker:swarm' mine.flush
salt -C 'I@docker:swarm' mine.update

salt -C 'cid*' state.sls docker.swarm
sleep 10
salt -C 'cid*' state.sls aptly
salt -C 'I@docker:swarm' cmd.shell 'systemctl restart docker' 

# create a flag file about cicd cluster deployment
touch $CICD_DEPLOYED

