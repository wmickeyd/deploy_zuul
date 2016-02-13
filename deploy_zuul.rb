#!/usr/bin/env ruby
#script to deploy Zuul in C3 XBO

require 'rubygems'
require 'net/ssh'
require 'net/scp'
require 'yaml'
require 'fileutils'

all_nodes = YAML.load_file('nodes.yml')
#puts nodes.inspect

#Find name of environment, use that name to determine the hostnames
directory = Dir.pwd
split_dir = directory.split("/")
env_dir = split_dir.last
dir = env_dir.gsub(/zuul/, "")
env_nodes = all_nodes["#{dir}"]
dc = dir.slice(0..1)
env = dir.slice(2..3)

#Get time for current deployment
time = Time.now
current_time = time.strftime("%Y%m%d_%H%M%S")

#read in name of file
puts "Enter full filename of Zuul tar.gz: "
filename = gets.chomp

#Tunnel to each node, transfer file, extract to folder, create/change symbolic link
env_nodes.each do |host|
#host = "ccpxbg-po-c325-p"
  puts "Working on #{host}"

#  puts "Uploading file to #{host}"
#  Net::SCP.upload!("#{host}", "xdeploy",
#    "#{filename}", "/home/xdeploy/",
#    :password => "")

  Net::SSH.start("#{host}", 'xdeploy', :password => "") do |ssh|
    output = ssh.exec!("hostname")

    puts "Stopping Zuul"
    ssh.exec! "sudo /etc/init.d/zuul stop"
    ssh.exec! "rm -rf ~/*"

    puts "Downloading Dynatrace"
    ssh.exec! "sudo yum -y install dynatrace-agent || ( sudo yum clean all ; sudo yum -y install dynatrace-agent )"

    puts "Downloading file from Nexus"
    ssh.exec! "wget --no-proxy http://nexus:8081/nexus/content/groups/master/com/comcast/xcal/xbo/bows-zuul/#{filename}"

    puts "Downloading Jetty 8.1.15"
    ssh.exec! "wget --no-proxy http://yum.#{dc}.ccp.cable.comcast.com/caprepo/buildrepo/jetty/jetty-distribution-8.1.15.v20140411.zip"

    puts "Creating jetty_bowszuul_#{current_time} directory"
    ssh.exec! "unzip jetty-distribution-8.1.15.v20140411.zip"
    ssh.exec! "mv jetty-distribution-8.1.15.v20140411 jetty_bowszuul_#{current_time}"
    ssh.exec! "rm jetty_bowszuul_#{current_time}/webapps/*.war"
    ssh.exec! "rm jetty_bowszuul_#{current_time}/contexts/test.xml"

    puts "Unzipping and extracting tar"
    ssh.exec! "tar -xvf #{filename}"

    puts "Moving files into jetty container"
    ssh.exec! "touch jetty_bowszuul_#{current_time}/logs/error.log"
    ssh.exec! "mv capistrano/filters jetty_bowszuul_#{current_time}"
    ssh.exec! "mv capistrano/config/* jetty_bowszuul_#{current_time}/resources"
    ssh.exec! "mv capistrano/war/bows-*.war capistrano/war/root.war && mv capistrano/war/root.war jetty_bowszuul_#{current_time}/webapps"

    puts "Moving directory and creating symbolic link"
    ssh.exec! "sudo [ -d /opt/ds ] || sudo mkdir /opt/ds"
    ssh.exec! "sudo mv jetty_bowszuul_#{current_time} /opt/ds/"
    #ssh.exec! "sudo cp /opt/ds/bows-zuul/jetty-wrapper.sh /opt/ds/jetty_bowszuul_#{current_time}"
    ssh.exec! "sudo ln -sfnv /opt/ds/jetty_bowszuul_#{current_time} /opt/ds/bows-zuul"
    ssh.exec! "sudo chown xdeploy:xdeploy /opt/ds/*"
    ssh.exec! "mkdir /opt/ds/bows-zuul/work"

    puts "Cleaning up home directory"
    ssh.exec! "rm -rf ~/*"
    ssh.exec! "echo #{filename} > /opt/ds/bows-zuul/VERSION.txt"

    #check java version
    puts "Checking java version"
    java = ssh.exec! "java -version"
      if java.include? "1.8.0_05"
        puts "Correct version installed"
      else
        puts "Installing java"
        ssh.exec! "sudo rpm -ivh --force http://yum.#{dc}.ccp.cable.comcast.com/repo/OPS/5/x86_64/RPMS/jdk-8u5-linux-x64.rpm"
        puts "Java installed"
      end

    #Check for start up script
    puts "Checking for Start Up script"
    start_up = ssh.exec! "if [ ! -f /etc/init.d/zuul ]; then echo 'Script is not present'; fi"
      if start_up.nil?
        puts "Script is present"
      else
        puts "#{start_up}"
        puts "Creating startup script"
        Net::SCP.upload!("#{host}", "xdeploy",
        "zuul", "/home/xdeploy/",
        :password => "")
        ssh.exec! "sudo mv zuul /etc/init.d/"
        ssh.exec! "sudo chmod +x /etc/init.d/zuul"
        ssh.exec! "sudo chkconfig --add zuul"
        puts "Created script"
      end

    #Updating Jetty Wrapper
    puts "Updating the jetty-wrapper"
    wrapper = ssh.exec! "if [ ! -f /opt/ds/bows-zuul/jetty-wrapper.sh ]; then echo 'Wrapper is not present'; fi"
      if wrapper.nil?
        puts "Script is present"
      else
        puts "#{wrapper}"
        puts "Creating wrapper script"
        Net::SCP.upload!("#{host}", "xdeploy",
        "Env/#{env}/#{dir}_wrapper.sh", "/home/xdeploy/",
        :password => "")
        ssh.exec! "sudo mv #{dir}_wrapper.sh jetty-wrapper.sh"
        ssh.exec! "sudo mv jetty-wrapper.sh /opt/ds/bows-zuul/"
        ssh.exec! "sudo chmod +x /opt/ds/bows-zuul/jetty-wrapper.sh"
        puts "Updated Wrapper"
      end

    #Add OOM script
    puts "Checking for OOM script"
    oom = ssh.exec! "if [ ! -f /opt/ds/bows-zuul/bin/OOM.rb ]; then echo 'OOM is not present'; fi"
      if oom.nil?
        puts "OOM is present"
      else
        puts "#{oom}"
        puts "Uploading OOM.rb"
        Net::SCP.upload!("#{host}", "xdeploy",
        "etc/OOM.rb", "/home/xdeploy/",
        :password => "")
        ssh.exec! "sudo mv OOM.rb /opt/ds/bows-zuul/bin/"
        ssh.exec! "sudo chmod +x /opt/ds/bows-zuul/bin/OOM.rb"
        puts "OOM uploaded"
      end

    #Change Jetty Logger
    puts "Uploading Jetty Logger"
    Net::SCP.upload!("#{host}", "xdeploy",
      "etc/jetty-logging.xml", "/home/xdeploy/",
      :password => "")
    ssh.exec! "sudo mv jetty-logging.xml /opt/ds/bows-zuul/etc/"
    puts "Jetty logger uploaded"

    #Change Jetty Webapps
    puts "Uploading Jetty Webapp.xml"
    Net::SCP.upload!("#{host}", "xdeploy",
      "etc/jetty-webapps.xml", "/home/xdeploy/",
      :password => "")
    ssh.exec! "sudo mv jetty-webapps.xml /opt/ds/bows-zuul/etc/"
    puts "Jetty webapps.xml uploaded"

    puts "Cleaning up opt dir"
#    ssh.exec! "sudo [ -d /opt/ds/lastknowngood ] || sudo mkdir /opt/ds/lastknowngood"
#    ssh.exec! 'sudo find /opt/ds/ -maxdepth 1 -mtime +30 -type d -name "jetty*" -exec mv -t /opt/ds/lastknowngood/ {};'
#    ssh.exec! 'sudo find /opt/ds/lastknowngood -maxdepth 1 -mtime +60 -type d -name "jetty*" -exec rm -rf {};'

    puts "Starting Zuul"
    ssh.exec! "sudo /etc/init.d/zuul start"
#    ssh.close
  end
end
  puts "Deployment completed"
exit
