#!/bin/sh

# Script is supposed to be run on cicd leader node (for ex.: cfg01)
# Joins gluster and swarm cluster and redeploys Gerrit, Jenkins and Openldap

CICD_DEPLOYED="/root/cicd_deployed"

# Check
if [ -e $CICD_DEPLOYED ]; then
  error "CICD cluster was already deployed. If you want to deploy it again delete $CICD_DEPLOYED file and run the script again."
fi

apt update
service salt-minion restart

#deploy the rest of cicd nodes
salt -C 'cid*' saltutil.refresh_pillar
salt -C 'cid*' saltutil.sync_all
salt -C 'cid*' cmd.shell 'salt-call state.sls salt.minion'
salt -C 'cid*' state.sls salt.minion,linux,openssh,ntp
salt -C 'cid*' state.sls glusterfs.server.service
service salt-minion restart
salt-call state.sls glusterfs.server

# remove running containers
echo "" > .ssh/known_hosts
docker stack rm gerrit; docker stack rm jenkins; docker stack rm ldap;
sleep 5
rm -rf /srv/volumes/mysql/* /srv/volumes/gerrit/* /srv/volumes/jenkins/* /srv/volumes/openldap/* /srv/jeepyb/;
salt-call state.sls linux.system.config

# add bricks to gluster
volumes=`gluster volume list`
cid02=`salt-call pillar.data _param:cluster_node02_address | sed -n 4p`
cid03=`salt-call pillar.data _param:cluster_node03_address | sed -n 4p`
for vol_name in $volumes; do gluster volume add-brick $vol_name replica 2 $cid02:/srv/glusterfs/$vol_name force; done
for vol_name in $volumes; do gluster volume add-brick $vol_name replica 3 $cid03:/srv/glusterfs/$vol_name force; done

# join docker swarm
salt -C 'cid*' state.sls glusterfs.client
salt -C 'cid*' state.sls haproxy,keepalived
salt -C 'cid*' state.sls docker.host

salt -C 'I@docker:swarm' state.sls salt
salt -C 'I@docker:swarm' mine.flush
salt -C 'I@docker:swarm' mine.update

salt -C 'I@docker:swarm' state.sls docker.swarm
sleep 10

# launch containers
salt -C 'I@docker:swarm:role:master' state.sls docker.client
sleep 5
salt -C 'I@docker:swarm:role:master' state.sls docker.client

cid=`salt-call pillar.data _param:cicd_control_address | sed -n 4p`

# max 100 checks if LDAP, Gerrit and Jenkins container is up
a=0
while [ $a -lt 100 ]
do
   curl -sf ldap://$cid >/dev/null
   RC=$?
   if [ $RC -eq 0 ]
   then
      break
   fi
   a=`expr $a + 1`
   echo "Waiting for LDAP container to be up"
   sleep 5
done

if [ $a -eq 100 ]
then
   echo "LDAP container did not come up. Please check the logs."
   exit 1
fi

salt -C 'I@openldap:client' cmd.shell 'salt-call state.sls openldap'

a=0
while [ $a -lt 100 ]
do
   curl -sf $cid:8080 >/dev/null
   RC=$?
   if [ $RC -eq 0 ]
   then
      break
   fi
   a=`expr $a + 1`
   echo "Waiting for gerrit_server container to be up"
   sleep 5
done

if [ $a -eq 100 ]
then
   echo "Gerrit_server container did not come up. Please check the logs and command 'docker node ls' if all cluster nodes are reachable"
   docker node ls
   exit 1
fi

salt -C 'I@gerrit:client' cmd.shell 'salt-call state.sls gerrit'

a=0
while [ $a -lt 100 ]
do
   curl -s $cid:8081 >/dev/null
   RC=$?
   if [ $RC -eq 0 ]
   then
      break
   fi
   a=`expr $a + 1`
   echo "Waiting for Jenkins container to be up"
   sleep 5
done

if [ $a -eq 100 ]
then
   echo "Jenkins container did not come up. Please check the logs and command 'docker node ls' if all cluster nodes are reachable"
   docker node ls
   exit 1
fi

salt -C 'I@jenkins:client' cmd.shell 'salt-call state.sls jenkins'

# create a flag file about cicd cluster deployment
touch $CICD_DEPLOYED

