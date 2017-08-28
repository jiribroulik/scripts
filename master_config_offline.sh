#!/bin/bash -xe
export SALT_MASTER_DEPLOY_IP=172.16.164.15
export SALT_MASTER_MINION_ID=cfg01.deploy-name.local
export DEPLOY_NETWORK_GW=172.16.164.1
export DEPLOY_NETWORK_NETMASK=255.255.255.192
export DNS_SERVERS=8.8.8.8
export CICD_CONTROL_ADDRESS=172.16.174.90
export INFRA_CONFIG_ADDRESS=172.16.174.15


echo "Configuring network interfaces"
echo "127.0.0.1   cfg cfg01" >> /etc/hosts
envsubst < /root/interfaces > /etc/network/interfaces
ifdown ens3; ifup ens3

echo "Preparing metadata model"
mount /dev/cdrom /mnt/
cp -r /mnt/model/model11Stacklight/* /srv/salt/reclass/
chown root:root /srv/salt/reclass/*
chmod -R 644 /srv/salt/reclass/classes/cluster/*
chmod -R 644 /srv/salt/reclass/classes/system/*

echo "updating gerrit repos"
cp -r /mnt/mk-pipelines/* /srv/glusterfs/gerrit/git/mk/mk-pipelines.git/
cp -r /mnt/decapod-pipelines/* /srv/glusterfs/gerrit/git/mk/decapod-pipelines.git/
cp -r /mnt/pipeline-library/* /srv/glusterfs/gerrit/git/mcp-ci/pipeline-library.git/

umount /dev/cdrom

cd /srv/salt/reclass/classes/service
ln -s /usr/share/salt-formulas/reclass/service/devops_portal

echo "Configuring salt"
#service salt-master restart
envsubst < /root/minion.conf > /etc/salt/minion.d/minion.conf
service salt-minion restart
while true; do
    salt-key | grep "$SALT_MASTER_MINION_ID" && break
    sleep 5
done
sleep 5
for i in `salt-key -l accepted | grep -v Accepted | grep -v "$SALT_MASTER_MINION_ID"`; do
    salt-key -d $i -y
done

# replace IPs
if [ $CICD_CONTROL_ADDRESS != "10.167.4.90" ] ; then
    systemctl stop docker
    find /etc/docker/compose/* -type f -print0 | xargs -0 sed -i -e 's/10.167.4.90/'$CICD_CONTROL_ADDRESS'/g'
fi

if [ $INFRA_CONFIG_ADDRESS != "10.167.4.15" ] ; then
    systemctl stop docker
    find /etc/docker/compose/* -type f -print0 | xargs -0 sed -i -e 's/10.167.4.15/'$INFRA_CONFIG_ADDRESS'/g'
fi

# set proxy for gerrit, jenkins, aptly
find /etc/docker/compose/* -type f -print0 | xargs -0 sed -i -e 's/10.20.0.1/'$SALT_MASTER_DEPLOY_IP'/g'

# update jenkins repos
rm -rf /srv/glusterfs/jenkins/workspace/git-mirror-downstream-*
rm /srv/glusterfs/jenkins/.ssh/known_hosts

# update gerrit
systemctl status docker | grep inactive >/dev/null
RC=$?
if [ $RC -eq 0 ] ; then
    systemctl start docker
    cd /etc/docker/compose/gerrit/
    docker stack deploy --compose-file docker-compose.yml gerrit
    cd /etc/docker/compose/jenkins/
    docker stack deploy --compose-file docker-compose.yml jenkins
    cd /etc/docker/compose/aptly/
    docker stack deploy --compose-file docker-compose.yml aptly
fi

salt-call saltutil.refresh_pillar
salt-call saltutil.sync_all
salt-call state.sls linux,openssh,salt
salt-call state.sls maas.cluster,maas.region,keepalived,haproxy,reclass
reboot
