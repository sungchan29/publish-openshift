#!/bin/bash

mkdir -p /root/ocp4/support-system/scripts
mkdir -p /root/ocp4/download/scripts
mkdir -p /root/ocp4/upload/scripts
mkdir -p /root/agent-based/install/scripts
mkdir -p /root/agent-based/add-nodes/scripts

rm -Rf /root/ocp4/support-system/scripts
rm -Rf /root/ocp4/download/scripts
rm -Rf /root/ocp4/upload/scripts
rm -Rf /root/agent-based/install/scripts
rm -Rf /root/agent-based/add-nodes/scripts

cp -Rf sungchan/ocp4/01-preparing-installation /root/ocp4/support-system/scripts
cp -Rf sungchan/ocp4/02-download-images        /root/ocp4/download/scripts
cp -Rf sungchan/ocp4/03-upload-images          /root/ocp4/upload/scripts
cp -Rf sungchan/ocp4/04-agent-based-install    /root/agent-based/install/scripts
cp -Rf sungchan/ocp4/05-agent-based-add-nodes  /root/agent-based/add-nodes/scripts