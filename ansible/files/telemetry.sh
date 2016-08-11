#!/bin/bash

# logging for any errors during bootstrapping
exec > >(tee -i /var/log/bootstrap-script.log)
exec 2>&1

# we won't use `set -e` because that means that AWS would terminate the instance and we wouldn't get logs for why it failed

TELEMETRY_CONF_BUCKET=s3://telemetry-spark-emr-2
MEMORY_OVERHEAD=7000  # Tuned for c3.4xlarge
EXECUTOR_MEMORY=15000M
DRIVER_MIN_HEAP=1000M
DRIVER_MEMORY=$EXECUTOR_MEMORY

# Enable EPEL
sudo yum-config-manager --enable epel

# Install packages
curl https://bintray.com/sbt/rpm/rpm | sudo tee /etc/yum.repos.d/bintray-sbt-rpm.repo
sudo yum -y install git jq htop tmux libffi-devel aws-cli postgresql-devel zsh snappy-devel readline-devel emacs nethogs w3m
sudo yum -y install --nogpgcheck sbt # bintray doesn't sign packages for some reason, this isn't ideal but is the only way to install sbt

# Download jars
aws s3 sync $TELEMETRY_CONF_BUCKET/jars $HOME/jars

# Check for master node
IS_MASTER=true
if [ -f /mnt/var/lib/info/instance.json ]
then
    IS_MASTER=$(jq .isMaster /mnt/var/lib/info/instance.json)
fi

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --public-key)
            shift
            PUBLIC_KEY=$1
            ;;
        --timeout)
            shift
            TIMEOUT=$1
            ;;
        -*)
            # do not exit out, just note failure
            echo 1>&2 "unrecognized option: $1"
            ;;
        *)
            break;
            ;;
    esac
    shift
done

# Setup Python
export ANACONDAPATH=$HOME/anaconda2
ANACONDA_SCRIPT=Anaconda2-4.0.0-Linux-x86_64.sh
wget --no-clobber --no-verbose http://repo.continuum.io/archive/$ANACONDA_SCRIPT
bash $ANACONDA_SCRIPT -b

PIP_REQUIREMENTS_FILE=/tmp/requirements.txt
cat << EOF > $PIP_REQUIREMENTS_FILE
python_moztelemetry
python_mozaggregator
montecarlino
jupyter-notebook-gist>=0.4.0,<1.0.0
jupyter-spark>=0.3.0,<1.0.0
runipy
boto3
parquet2hive
py4j==0.8.2.1
pyliblzma==0.5.3
plotly==1.6.16
seaborn==0.6.0
EOF
$ANACONDAPATH/bin/pip install -r $PIP_REQUIREMENTS_FILE
rm $ANACONDA_SCRIPT
rm $PIP_REQUIREMENTS_FILE

# Add public key
if [ -n "$PUBLIC_KEY" ]; then
    echo $PUBLIC_KEY >> $HOME/.ssh/authorized_keys
fi

# Schedule shutdown at timeout
if [ ! -z $TIMEOUT ]; then
    sudo shutdown -h +$TIMEOUT&
fi

# Continue only if master node
if [ "$IS_MASTER" = false ]; then
    exit
fi

# Setup Spark logging
sudo mkdir -p /mnt/var/log/spark
sudo chmod a+rw /mnt/var/log/spark
touch /mnt/var/log/spark/spark.log

# Setup R environment
wget -nc https://mran.microsoft.com/install/RRO-3.2.1-el6.x86_64.tar.gz
tar -xzf RRO-3.2.1-el6.x86_64.tar.gz
rm RRO-3.2.1-el6.x86_64.tar.gz
cd RRO-3.2.1; sudo ./install.sh; cd ..
$ANACONDAPATH/bin/pip install rpy2
mkdir -p $HOME/R_libs

# Configure environment variables
echo "" >> $HOME/.bashrc
echo "export R_LIBS=$HOME/R_libs" >> $HOME/.bashrc
echo "export LD_LIBRARY_PATH=/usr/lib64/RRO-3.2.1/R-3.2.1/lib64/R/lib/" >> $HOME/.bashrc
echo "export PYTHONPATH=/usr/lib/spark/python/" >> $HOME/.bashrc
echo "export SPARK_HOME=/usr/lib/spark" >> $HOME/.bashrc
echo "export PYSPARK_PYTHON=$ANACONDAPATH/bin/python" >> $HOME/.bashrc
echo "export PATH=$ANACONDAPATH/bin:\$PATH" >> $HOME/.bashrc
echo "export _JAVA_OPTIONS=\"-Djava.io.tmpdir=/mnt1/ -Xmx$DRIVER_MEMORY -Xms$DRIVER_MIN_HEAP\"" >> $HOME/.bashrc
echo "export PYSPARK_SUBMIT_ARGS=\"--packages com.databricks:spark-csv_2.10:1.2.0 --master yarn --deploy-mode client --executor-memory $EXECUTOR_MEMORY --conf spark.yarn.executor.memoryOverhead=$MEMORY_OVERHEAD pyspark-shell\"" >> $HOME/.bashrc

source $HOME/.bashrc

# Setup Jupyter notebook
aws s3 cp $TELEMETRY_CONF_BUCKET/bootstrap/jupyter_notebook_config.py ~/.jupyter/jupyter_notebook_config.py

# Setup IPython
ipython profile create
cat << EOF > $HOME/.ipython/profile_default/startup/00-pyspark-setup.py
import os
spark_home = os.environ.get('SPARK_HOME', None)
execfile(os.path.join(spark_home, 'python/pyspark/shell.py'))
EOF

# Setup plotly
mkdir -p $HOME/.plotly && aws s3 cp $TELEMETRY_CONF_BUCKET/plotly_credentials $HOME/.plotly/.credentials

# Load Parquet datasets after Hive metastore is up
HIVE_CONFIG_SCRIPT=$(cat <<EOF
while ! hive -e 'show tables' > /dev/null; do sleep 1; done
/home/hadoop/anaconda2/bin/parquet2hive s3://telemetry-parquet/longitudinal | bash
/home/hadoop/anaconda2/bin/parquet2hive s3://telemetry-parquet/crash_aggregates | bash
/home/hadoop/anaconda2/bin/parquet2hive s3://telemetry-parquet/client_count | bash
/home/hadoop/anaconda2/bin/parquet2hive s3://telemetry-parquet/main_summary | bash
/home/hadoop/anaconda2/bin/parquet2hive s3://net-mozaws-prod-us-west-2-pipeline-analysis/mobile/android_clients | bash
/home/hadoop/anaconda2/bin/parquet2hive s3://net-mozaws-prod-us-west-2-pipeline-analysis/mobile/android_events  | bash
/home/hadoop/anaconda2/bin/parquet2hive s3://net-mozaws-prod-us-west-2-pipeline-analysis/mobile/android_addons  | bash
/home/hadoop/anaconda2/bin/parquet2hive s3://net-mozaws-prod-us-west-2-pipeline-analysis/mobile/mobile_clients  | bash
exit 0
EOF
)
echo "${HIVE_CONFIG_SCRIPT}" | tee /tmp/hive_config.sh
chmod u+x /tmp/hive_config.sh
bash /tmp/hive_config.sh &

# Configure Jupyter
jupyter nbextension enable --py widgetsnbextension --user

jupyter serverextension enable --py jupyter_notebook_gist --user
jupyter nbextension install --py jupyter_notebook_gist --user
jupyter nbextension enable --py jupyter_notebook_gist --user

jupyter serverextension enable --py jupyter_spark --user
jupyter nbextension install --py jupyter_spark --user
jupyter nbextension enable --py jupyter_spark --user

# Launch Jupyter Notebook
mkdir -p $HOME/analyses && cd $HOME/analyses
wget -nc https://raw.githubusercontent.com/mozilla/emr-bootstrap-spark/master/examples/Telemetry%20Hello%20World.ipynb
wget -nc https://raw.githubusercontent.com/mozilla/emr-bootstrap-spark/master/examples/Longitudinal%20Dataset%20Tutorial.ipynb
jupyter notebook --no-browser &
