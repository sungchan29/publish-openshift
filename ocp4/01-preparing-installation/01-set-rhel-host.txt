###
###
###
subscription-manager register

subscription-manager list --available --matches "Employee SKU" |egrep "Pool ID|^Ends"

subscription-manager attach --pool=<Pool ID>

subscription-manager repos --list-enabled


###
###
###
dnf update -y

### RHEL GUI 꾸미기 위해 "gnome-tweaks" 설치
###   "Show Applications"에서 "Utilities"에 포함 됨

dnf install -y gnome-tweaks

### Tweaks 실행 설정


### 한글 입력 설정
dnf install @input-methods

### Setting > Keyboard
###     "Input Sources"를 "Korean(한글)"로 변경


### D2Coding 폰트 추가
###   D2Coding 폰트 다운로드: https://github.com/naver/d2codingfont

wget https://github.com/naver/d2codingfont/releases/download/VER1.3.2/D2Coding-Ver1.3.2-20180524.zip

unzip D2Coding-Ver1.3.2-20180524.zip

mkdir -p /usr/share/fonts/D2Coding

cp ./D2CodingAll/D2Coding-Ver1.3.2-20180524-all.ttc /usr/share/fonts/D2Coding/

fc-cache -v


###############################
### Enabling virtualization ###
###############################
dnf install -y qemu-kvm libvirt virt-install virt-viewer

for drv in qemu network nodedev nwfilter secret storage interface; do
    systemctl start virt${drv}d{,-ro,-admin}.socket
done


virt-host-validate

systemctl start libvirtd.service

systemctl enable libvirtd.service
systemctl is-enabled libvirtd.service

systemctl status libvirtd.service


### QEMU: Checking if IOMMU is enabled by kernel : WARN (IOMMU appears to be disabled in kernel. Add intel_iommu=on to kernel cmdline arguments)
### https://access.redhat.com/solutions/1136173
grubby --info DEFAULT

grubby --args intel_iommu=on --update-kernel DEFAULT

grubby --info DEFAULT

######################################################################################
### The Virtual Machine Manager (virt-manager) application is supported in RHEL 8, ###
###  but has been deprecated.                                                      ###
######################################################################################
#yum -y install virt-manager


#############################################################
### Setting up the web console to manage virtual machines ###
#############################################################
dnf -y install cockpit-machines

systemctl enable cockpit.socket
systemctl is-enabled cockpit.socket

systemctl start cockpit.socket
systemctl status cockpit.socket



###
### NTP Server 설치
###
dnf install -y chrony


if [[ ! -f /etc/chrony.conf.orig ]]; then
  mv /etc/chrony.conf /etc/chrony.conf.orig
fi

cat <<EOF > /etc/chrony.conf
pool 2.rhel.pool.ntp.org iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
allow all
local stratum 10
keyfile /etc/chrony.keys
leapsectz right/UTC
logdir /var/log/chrony
EOF

chcon --reference=/etc/chrony.conf.orig /etc/chrony.conf

systemctl enable chronyd

systemctl start chronyd

firewall-cmd --permanent --add-service=ntp --zone=public
firewall-cmd --reload

chronyc tracking

chronyc sources


###
### Network Interface 설정(bridge0 생성)
###
[sungchan@thinkpad rhel-host-setting]$ ls
install-packages.txt
[sungchan@thinkpad rhel-host-setting]$ cat install-packages.txt

###
###
###
subscription-manager register

subscription-manager list --available --matches "Employee SKU" |egrep "Pool ID|^Ends"

subscription-manager attach --pool=<Pool ID>

subscription-manager repos --list-enabled


###
###
###
dnf update -y

### RHEL GUI 꾸미기 위해 "gnome-tweaks" 설치
###   "Show Applications"에서 "Utilities"에 포함 됨

dnf install -y gnome-tweaks

### Tweaks 실행 설정


### 한글 입력 설정
dnf install @input-methods

### Setting > Keyboard
###     "Input Sources"를 "Korean(한글)"로 변경


### D2Coding 폰트 추가
###   D2Coding 폰트 다운로드: https://github.com/naver/d2codingfont

wget https://github.com/naver/d2codingfont/releases/download/VER1.3.2/D2Coding-Ver1.3.2-20180524.zip

unzip D2Coding-Ver1.3.2-20180524.zip

mkdir -p /usr/share/fonts/D2Coding

cp ./D2CodingAll/D2Coding-Ver1.3.2-20180524-all.ttc /usr/share/fonts/D2Coding/

fc-cache -v


###############################
### Enabling virtualization ###
###############################
dnf install -y qemu-kvm libvirt virt-install virt-viewer

for drv in qemu network nodedev nwfilter secret storage interface; do
    systemctl start virt${drv}d{,-ro,-admin}.socket
done


virt-host-validate

systemctl start libvirtd.service

systemctl enable libvirtd.service
systemctl is-enabled libvirtd.service

systemctl status libvirtd.service


### QEMU: Checking if IOMMU is enabled by kernel : WARN (IOMMU appears to be disabled in kernel. Add intel_iommu=on to kernel cmdline arguments)
### https://access.redhat.com/solutions/1136173
grubby --info DEFAULT

grubby --args intel_iommu=on --update-kernel DEFAULT

grubby --info DEFAULT

######################################################################################
### The Virtual Machine Manager (virt-manager) application is supported in RHEL 8, ###
###  but has been deprecated.                                                      ###
######################################################################################
#yum -y install virt-manager


#############################################################
### Setting up the web console to manage virtual machines ###
#############################################################
dnf -y install cockpit-machines

systemctl enable cockpit.socket
systemctl is-enabled cockpit.socket

systemctl start cockpit.socket
systemctl status cockpit.socket



###
### NTP Server 설치
###
dnf install -y chrony


if [[ ! -f /etc/chrony.conf.orig ]]; then
  mv /etc/chrony.conf /etc/chrony.conf.orig
fi

cat <<EOF > /etc/chrony.conf
pool 2.rhel.pool.ntp.org iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
allow all
local stratum 10
keyfile /etc/chrony.keys
leapsectz right/UTC
logdir /var/log/chrony
EOF

chcon --reference=/etc/chrony.conf.orig /etc/chrony.conf

systemctl enable chronyd

systemctl start chronyd

firewall-cmd --permanent --add-service=ntp --zone=public
firewall-cmd --reload

chronyc tracking

chronyc sources


###
### Network Interface 설정(bridge0 생성)
###



### sshKey 생성
###   eval "$(ssh-agent -s)"    : SSH 에이전트를 백그라운드로 실행
###   ssh-add ~/.ssh/id_ed25519 : SSH 에이전트에 키 등록

if [[ ! -f ~/.ssh/id_ed25519 ]]; then
  ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519
else
  ls -al ~/.ssh/id_ed25519
  echo ""
fi
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519


### 공개 키를 원격 머신에 복사
ssh-copy-id <username>@<ssh-server-example.com>
