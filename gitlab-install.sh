echo "********************************"
echo "    GitLab Install script"
echo "********************************"
read -s -p "> MySQL root password(Default:Pa55w0rd): " mysqlpass
echo -e "\\n"
read -p "> Domain name(Default:localhost): " domain_name
echo -e "\\n"
read -p "> Install version 5.3?(yes/no)(default:5.0): " use53
echo -e "\\n"
read -p "> Use https?(yes/no)(default:http): " useSSL
[ -z mysqlpass ] && mysqlpass=Pa55w0rd
[ -z domain_name ] && domain_name=localhost
[ -z use53 ] && use53=no
[ -z useSSL ] && useSSL=no

sudo apt-get update
# Needed to create a unique password non-interactively.
sudo apt-get install -y makepasswd 
# Generate a random gitlab MySQL password
gitlabpass=$(makepasswd --char=16)
currentdir=$(pwd)

# Install essentials
sudo apt-get install -y build-essential zlib1g-dev libyaml-dev libssl-dev libgdbm-dev
sudo apt-get install -y libreadline-dev libncurses5-dev libffi-dev curl git-core 
sudo apt-get install -y openssh-server redis-server postfix checkinstall libxml2-dev 
sudo apt-get install -y libxslt-dev libcurl4-openssl-dev libicu-dev

# Install Python
sudo apt-get install -y python python2.7
sudo ln -s /usr/bin/python /usr/bin/python2

# Install Ruby
rm -rf /tmp/ruby
mkdir /tmp/ruby && cd /tmp/ruby
curl --progress ftp://ftp.ruby-lang.org/pub/ruby/2.0/ruby-2.0.0-p247.tar.gz | tar xz
cd ruby-2.0.0-p247
./configure
make
sudo make install

# Install Ruby Bundler
sudo gem install bundler --no-ri --no-rdoc

# Create git user
sudo adduser --disabled-login --gecos 'GitLab' git

# Go to home directory
cd /home/git

# Clone gitlab shell
sudo -u git -H git clone https://github.com/gitlabhq/gitlab-shell.git
cd gitlab-shell
if [ use53=="yes" ]
then
	sudo -u git -H git checkout v1.4.0
	sudo -u git -H git checkout -b v1.4.0
else
	sudo -u git -H git checkout v1.1.0
	sudo -u git -H git checkout -b v1.1.0
fi

sudo -u git -H cp config.yml.example config.yml

# Edit config and replace gitlab_url
# with something like 'http://domain.com/'

sudo -u git -H sed -i  "s/localhost/${domain_name}/g" config.yml

# Do setup
sudo -u git -H ./bin/install

# Install the database packages
sudo apt-get install -y mysql-server mysql-client libmysqlclient-dev

# Create a user for GitLab.
mysql -uroot -p$mysqlpass << QUERY
CREATE USER 'gitlab'@'localhost' IDENTIFIED BY '$gitlabpass';
CREATE DATABASE IF NOT EXISTS \`gitlabhq_production\` DEFAULT CHARACTER SET \`utf8\` COLLATE \`utf8_unicode_ci\`;
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, INDEX, ALTER ON \`gitlabhq_production\`.* TO 'gitlab'@'localhost';
QUERY
# Try connecting to the new database with the new user
sudo -u git -H mysql -ugitlab -p$gitlabpass -D gitlabhq_production -e "\\q"

# We'll install GitLab into home directory of the user "git"
cd /home/git

# Clone GitLab repository
sudo -u git -H git clone https://github.com/gitlabhq/gitlabhq.git gitlab

# Go to gitlab dir
cd /home/git/gitlab

if [ use53=="yes" ]
then
        sudo -u git -H git checkout 5-3-stable
else
        sudo -u git -H git checkout 5-0-stable
fi

cd /home/git/gitlab

# Copy the example GitLab config
sudo -u git -H cp config/gitlab.yml.example config/gitlab.yml

# Make sure to change "localhost" to the fully-qualified domain name of your
# host serving GitLab where necessary
sudo -u git -H sed -i "s/\ host:\ localhost/\ host:\ ${domain_name}/" config/gitlab.yml
#sudo -u git -H sed -i 's/port:\ 80/port:\ 3000/' config/gitlab.yml

# Make sure GitLab can write to the log/ and tmp/ directories
sudo chown -R git log/
sudo chown -R git tmp/
sudo chmod -R u+rwX log/
sudo chmod -R u+rwX tmp/

# Create directory for satellites
sudo -u git -H mkdir /home/git/gitlab-satellites

# Create directory for pids and make sure GitLab can write to it
sudo -u git -H mkdir tmp/pids/
sudo chmod -R u+rwX  tmp/pids/

if [ use53=="yes" ]
then
	sudo -u git -H cp config/puma.rb.example config/puma.rb

else
	sudo -u git -H cp config/unicorn.rb.example config/unicorn.rb
	sudo -u git -H sed -i 's/timeout\ 30/timeout\ 60/' config/unicorn.rb
fi

# Disable listen socket
#sudo -u git -H sed -i 's/\#listen\ \"127\.0\.0\.1\:8080\"/listen\ \"127\.0\.0\.1\:80\"/' config/unicorn.rb
#sudo -u git -H sed -i 's/listen\ \"\#{app_dir}\/tmp\/sockets\/gitlab\.socket\"/\#listen\ \"\#{app_dir}\/tmp\/sockets\/gitlab\.socket\"/' config/unicorn.rb

# Mysql
sudo -u git cp config/database.yml.mysql config/database.yml
sudo -u git -H  sed -i 's/username\:\ root/username\:\ gitlab/g' config/database.yml
sudo -u git -H  sed -i "s/secure\ password/${gitlabpass}/" config/database.yml # Insert the mysql root password.
sudo -u git -H  sed -i "s/ssh_host:\ localhost/ssh_host:\ ${domain_name}/" config/gitlab.yml
sudo -u git -H  sed -i "s/notify@localhost/notify@${domain_name}/" config/gitlab.yml

# Charlock Holmes
cd /home/git/gitlab
sudo gem install charlock_holmes --version '0.6.9'

# First run
sudo -u git -H bundle install --deployment --without development test postgres
sudo -u git -H bundle exec rake gitlab:setup RAILS_ENV=production << EOF
yes
EOF

# Init scripts
#sudo curl --output /etc/init.d/gitlab https://raw.github.com/gitlabhq/gitlab-recipes/5-0-stable/init.d/gitlab
sudo cp lib/support/init.d/gitlab /etc/init.d/gitlab
sudo chmod +x /etc/init.d/gitlab

sudo update-rc.d gitlab defaults 70 30
#sudo /usr/lib/insserv/insserv gitlab
#echo "sudo service gitlab start" | cat - /etc/rc.local > /tmp/out && sudo mv /tmp/out /etc/rc.local

# Test configuration
sudo -u git -H bundle exec rake gitlab:env:info RAILS_ENV=production
# Adding git config vars
sudo -u git -H git config --global user.name  "GitLab"
sudo -u git -H git config --global user.email "gitlab@localhost"


# Installing nginx
sudo apt-get install -y nginx
# Enable HTTPS
if [ useSSL=="yes" ]
then
	sudo curl https://raw.github.com/gitlabhq/gitlab-recipes/master/web-server/nginx/gitlab-ssl -o /etc/nginx/sites-available/gitlab-https
	sudo sed -i 's/unix\:\/home\/gitlab/unix\:\/home\/git/g' /etc/nginx/sites-available/gitlab-https
	sudo sed -i 's/TLSv2//g' /etc/nginx/sites-available/gitlab-https
	KEY=$(find /home/git/ | grep -i server.key | sed 's/\//\\\//g')
	CRT=$(find /home/git/ | grep -i server.crt | sed 's/\//\\\//g')
	sudo sed -i "s/\/etc\/nginx\/gitlab\.key/${KEY}/g" /etc/nginx/sites-available/gitlab-https
	sudo sed -i "s/\/etc\/nginx\/gitlab\.crt/${CRT}/g" /etc/nginx/sites-available/gitlab-https
	sudo -u git -H  sed -i 's/https\:\ false/https\:\ true/' config/gitlab.yml
	sudo sed -i "s/gitlab.stardrad.com/${domain_name}/g" /etc/nginx/sites-available/gitlab-https
	sudo sed -i "s/git.example.com/${domain_name}/g" /etc/nginx/sites-available/gitlab-https
	sudo ln -s /etc/nginx/sites-available/gitlab-https /etc/nginx/sites-enabled/gitlab-https
	sudo sed -i "s/Domain_NAME/${domain_name}/" /etc/nginx/sites-available/gitlab-https
	sudo -u git -H sed -i  "s/http/https/g" /home/git/gitlab-shell/config.yml
	sudo -u git -H sed -i  "s/ self_signed_cert: true/ self_signed_cert: false/g" /home/git/gitlab-shell/config.yml
else
	sudo curl https://raw.github.com/gitlabhq/gitlab-recipes/5-0-stable/nginx/gitlab -o /etc/nginx/sites-available/gitlab
	sudo ln -s /etc/nginx/sites-available/gitlab /etc/nginx/sites-enabled/gitlab
	sudo sed -i 's/YOUR_SERVER_IP:80/\*\:80/' /etc/nginx/sites-available/gitlab # Set Domain
	sudo sed -i "s/YOUR_SERVER_FQDN/${domain_name}/" /etc/nginx/sites-available/gitlab
fi

sudo rm -f /etc/nginx/sites-enabled/default

# Check if socket folder exists
[ -e /home/git/gitlab/tmp/sockets ] || sudo -u git mkdir /home/git/gitlab/tmp/sockets

# Start services
sudo service gitlab start
sudo service nginx start

echo "login.........admin@local.host"
echo "password......5iveL!fe"

