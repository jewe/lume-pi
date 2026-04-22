# 04/2026

- Rasp lite via PI Imager Mac, configured
- config not set, ssh not enabled

ssh-copy-id -i /Users/jensweber/.ssh/id_ed25519.pub user@192.168.10.142 

rsync -av --delete ./lume-pi/ user@192.168.10.142:~/lume-pi/

user@raspberrypi:~/lume-pi $ ./setup-lume.sh 

error: docker login

!! login before
!! "wait..." when installing images
docker login
==> Setup complete

wrong hostname /etc/hostname 

!! sudo apt-get purge -y cloud-init
!! sudo reboot


lume-pi/setup-lume.sh
after reboot, no browser

!! remove cloud.init?

