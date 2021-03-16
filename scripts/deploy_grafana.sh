#!/usr/bin/env bash

function show_help() {
   # Display Help
   echo "Run this script to deploy Grafana and Prometheus to jumpbox."
   echo
   echo "Syntax: ./deploy_grafana.sh [-flag parameter]"
   echo ""
   echo "Required list of flags:"
   echo "-sshPublicKeyPath Path to the SSH public key that should be used to connect to the jump box, which is the entry point to the Purdue network."
   echo "-jbUserAndFQDN Username and FQDN for accessing jumpbox"
   echo ""
   echo "List of optional flags:"
   echo "-h                Print this help."
   echo ""
}

function passArrayToARM() {
   array=("$@")
   output="["
   i=0
   for item in "${array[@]}"
   do
        if [[ $i -eq 0 ]]
        then
            output="${output}'${item}'"
        else
            output="${output}, '${item}'"
        fi
        ((i++))
   done
   output="${output}]"
   echo ${output}
}

#global variable
scriptFolder=$(dirname "$(readlink -f "$0")")

# Default settings
location="eastus"
resourceGroupPrefix="iotedge4iiot"
networkName="PurdueNetwork"
configFilePath="${scriptFolder}/../config.txt"
adminUsername="iiotadmin"
vmSize="Standard_B1ms" #"Standard_D3_v2"

# Get arguments
while :; do
    case $1 in
        -h|-\?|--help)
            show_help
            exit;;
        -jbUserAndFQDN=?*)
            jbUserAndFQDN=${1#*=}
            ;;
        -jbUserAndFQDN=)
            echo "Missing jbUserAndFQDN. Exiting."
            exit;;
        -sshPublicKeyPath=)
            echo "Missing path to jump box SSH public key. Exiting."
            exit;;
        -sshPublicKeyPath=?*)
            sshPublicKeyPath=${1#*=}
            ;;
        --)
            shift
            break;;
        *)
            break
    esac
    shift
done


#Verifying that mandatory parameters are there
if [ -z $jbUserAndFQDN ]; then
    echo "Missing jbUserAndFQDN. Exiting."
    exit 1
fi
if [ -z $sshPublicKeyPath ]; then
    echo "Missing file path to SSH public key. Exiting."
    exit 1
fi

# Prepare CLI
if [ ! -z $subscription ]; then
  az account set --subscription $subscription
fi


# Load IoT Edge VMs to deploy from config file
source ${scriptFolder}/parseConfigFile.sh $configFilePath

targets="[$(passArrayToARM ${iotEdgeDevicesSubnets[@]})]"

prometheusConfiguration=$(
cat <<-END
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    scrape_interval: 5s
    static_configs:
      - targets: $targets
END
)

prometheusServiceConfiguration=$(
cat <<-END
[Unit]
Description=Prometheus
Wants=network-online.target
After=network-online.target

[Service]
User=prome
Group=prome
Type=simple
ExecStart=/usr/local/bin/prometheus \
    --config.file /etc/prometheus/prometheus.yml \
    --storage.tsdb.path /var/lib/prometheus/ \
    --web.console.templates=/etc/prometheus/consoles \
    --web.console.libraries=/etc/prometheus/console_libraries

[Install]
WantedBy=multi-user.target
END
)

prometheusInstallScript=$(
cat <<-END
    sudo apt update &&
    sudo apt install nginx -y &&
    sudo systemctl start nginx &&
    sudo systemctl start nginx &&
    sudo useradd --no-create-home --shell /bin/false prome &&
    sudo useradd --no-create-home --shell /bin/false node_exporter &&
    sudo mkdir /etc/prometheus &&
    sudo mkdir /var/lib/prometheus &&
    wget https://github.com/prometheus/prometheus/releases/download/v2.0.0/prometheus-2.0.0.linux-amd64.tar.gz &&
    tar xvf prometheus-2.0.0.linux-amd64.tar.gz &&
    sudo cp prometheus-2.0.0.linux-amd64/prometheus /usr/local/bin/ &&
    sudo cp prometheus-2.0.0.linux-amd64/promtool /usr/local/bin/ &&
    sudo chown prome:prome /usr/local/bin/prometheus &&
    sudo chown prome:prome /usr/local/bin/promtool &&
    sudo chown prome:prome /var/lib/prometheus &&
    sudo cp -r prometheus-2.0.0.linux-amd64/consoles /etc/prometheus &&
    sudo cp -r prometheus-2.0.0.linux-amd64/console_libraries /etc/prometheus &&
    sudo chown -R prome:prome /etc/prometheus/consoles &&
    sudo chown -R prome:prome /etc/prometheus/console_libraries &&
    sudo $prometheusConfiguration > /etc/prometheus/prometheus.yml &&
    sudo $prometheusServiceConfiguration > /etc/systemd/system/prometheus.service &&
    sudo systemctl daemon-reload &&
    sudo systemctl start prometheus &&
    sudo systemctl enable prometheus &&
    sudo systemctl status prometheus
END
)

echo $prometheusInstallScript > $scriptFolder/prometheus_install.sh

grafanaInstallScript=$(
cat <<-END
    sudo apt-get install -y apt-transport-https &&
    sudo apt-get install -y software-properties-common wget &&
    wget -q -O - https://packages.grafana.com/gpg.key | sudo apt-key add - &&
    echo "deb https://packages.grafana.com/oss/deb stable main" | sudo tee -a /etc/apt/sources.list.d/grafana.list &&
    sudo apt-get update &&
    sudo apt-get install grafana
END
)

echo $grafanaInstallScript > $scriptFolder/grafana_install.sh

echo "==========================================================="
echo "==	            Grafana and Prometheus                 =="
echo "==========================================================="
echo ""

ssh $jbUserAndFQDN 'bash -s' < ./prometheus_install.sh
ssh $jbUserAndFQDN 'bash -s' < ./grafana_install.sh

echo ""
echo ""
echo "Grafana and Prometheus are installed and configured."
echo ""