# amd64 Chroot on Raspberry Pi
## Installation

<pre>niux@raspberrypi:~ $ sudo chmod +x install-amd64-chroot.sh
niux@raspberrypi:~ $ sudo ./install-amd64-chroot.sh</pre>

## Entering
<pre>niux@raspberrypi:~ $ sudo amd64-chroot
[*] Entering amd64 chroot at /opt/amd64-root 
root@raspberrypi:/# uname -m x86_64 </pre>

## Shared Folder
<pre>root@raspberrypi:/# cd /mnt/shared
root@raspberrypi:/mnt/shared# nano arf
root@raspberrypi:/mnt/shared# exit
exit
niux@raspberrypi:~ $ cd /mnt/shared
niux@raspberrypi:/mnt/shared $ ls
arf
niux@raspberrypi:/mnt/shared $ cat arf
I like potatoes
</pre>
