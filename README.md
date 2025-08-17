# amd64 Chroot on Raspberry Pi
## Installation

<pre>sudo chmod +x install-amd64-chroot.sh
sudo ./install-amd64-chroot.sh</pre>

## Commands
<pre>sudo amd64-chroot              # enter as non-root user (svc)
sudo amd64-chroot root         # enter as root
sudo amd64-chroot root -- CMD  # run one-off command as root
sudo amd64-chroot status       # show mounts and user info
sudo amd64-chroot umount       # unmount cleanly</pre>


## Folders
<pre>chroot rootfs                  /opt/amd64-root
Shared folder                  /mnt/shared</pre>
