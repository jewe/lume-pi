- fresh pi-lite install

sudo apt install git

optional ssh-copy-id
git clone https://github.com/jewe/lume-pi.git
cd lume-pi

cp .env.sample .env
nano .env

bash setup-lume.sh 

unable to get image 'lumeplayer/lume:core': permission denied while trying to connect to the docker API at unix:///var/run/docker.sock
sudo usermod -aG docker $USER