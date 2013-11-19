#!/bin/bash

#TODO
#Work out the cluster names in a Composite DS
#determine the individulal services in a replicator so we can print out better output (status on each)
#Remove host logging - stop duplicate emails across multi hosts?

HOST=`hostname`

#Start Configuration Options. - These can be overridden by command line options or from $CONTINUENT_ROOT/share/check_tungsten.cfg
CONNECTOR=0      					#If this host is running a connector set to 1 otherwise 0
CLUSTER=0      						#If this host is running a cluster set to 1 otherwise 0
REPLICATOR=0   						#If this host is running a replicator  set to 1 otherwise 0
REPLICATOR_PORT=10000      			#Replicator Port
REPLICATOR_HOME=/opt/continuent/    #Home dir for Replicator
SERVICES=''                         #Name of the individual clusters in a composite DS
EMAIL=''							#Set email address here or pass via the email= command line option
DISK=0                              #Check Disk space
CHECK_ELB=0                         #Enable check for ELB socket check

SUBJECT="Error : Problems exist with the Tungsten Services on $HOST"
LOCK_TIMEOUT=180       				# Only send a Email every x minutes for a specific 
                      				# problem, stop spamming from the script
LAG=60                				# Slave lag to report on
CONNECTOR_TIMEOUT=10  				# No of seconds to wait for a connector response
DISK_WARNING=80       				# % full to send a warning
SENDMAILBIN=/usr/sbin/sendmail
#End Configuration Options

SENDMAIL=0
DEBUG=0
LOG=/opt/continuent/share/check_tungsten.log
LOCK_DIR=/opt/continuent/share/tungsten_locks

function float_cond()
{
    local cond=0
    if [[ $# -gt 0 ]]; then
        cond=$(echo "$*" | bc -q 2>&1)
        if [[ $? -ne 0 ]]; then
            echo "Error: $cond"
            exit 1
        fi
        if [[ -z "$cond" ]]; then cond=0; fi
        if [[ "$cond" != 0  &&  "$cond" != 1 ]]; then cond=0; fi
    fi
    local stat=$((cond == 0))
    return $stat
}

info ()
{
	if [ $DEBUG == 1 ]; then echo "INFO    : $1"; fi
}
error ()
{
	if [ $DEBUG == 1 ]; then echo "ERROR   : $1"; fi
}
severe ()
{
	echo "SEVERE  : $1"
	exit 1
}
getSetting ()
{
	CFG=$CONTINUENT_ROOT/conf/tungsten.cfg
	if [ ! -f $CFG ]
	then
		severe "Unable to find $CFG"
	fi
	getSettingValue=""
	getSettingValue=$(grep "\"$1\"" $CFG| cut -d ':' -f2 | head -1|sed 's/,//g'|sed 's/"//g'|sed 's/ //g')
	if [ -z $getSettingValue ]
	then
		severe "Unable to find $1 in $CFG"
	fi
	if [ "$getSettingValue" == '' ]
	then
		severe "Unable to find $1 in $CFG"
	fi
	echo "$getSettingValue"
}


# Load any continuent variables 

if [ -z $CONTINUENT_ROOT ]
then
	[ -f "$HOME/.bash_profile" ] && . "$HOME/.bash_profile"
	[ -f "$HOME/.profile" ] && . "$HOME/.profile"
fi

function sOpt()
{
	$1=1
	info "$1 switched on via command line"
}

function mOpt()
{
	
	for i in $(echo $2 | tr "=" "\n")
	do
		if [ $i != '$3' ]
		then
			$1=$i
		fi
	done
}

#Parse the command line options

for arg in "$@"
do
    case "$arg" in
    -v)    				DEBUG=1
      					info "Debug mode set"
            			;;
    -vv)    			DEBUG=1
      					info "INFO   : Extended Debug mode set"
						set -x
        				;;
    cluster)    		CLUSTER=1
            			info "CLUSTER switched on via command line" 
            			;;
    connector)  		CONNECTOR=1
            			info "CONNECTOR switched on via command line" 
            			;;
    replicator)   		REPLICATOR=1
            			info "REPLICATOR switched on via command line"
            			;;
    check_elb)   		CHECK_ELB=1
            			info "CHECK_ELB switched on via command line"
            			;;
    replicator_port*)   for i in $(echo $arg | tr "=" "\n")
						do
							if [ $i != 'replicator_port' ]
							then
				  				REPLICATOR_PORT=$i
							fi
						done

            			info "REPLICATOR_PORT - $REPLICATOR_PORT - switched on via command line" 
            			;;
    replicator_home*)   for i in $(echo $arg | tr "=" "\n")
						do
							if [ $i != 'replicator_home' ]
							then
				  				REPLICATOR_HOME=$i
							fi
						done

            			info "REPLICATOR_HOME - $REPLICATOR_HOME - switched on via command line" 
            			;;
    services*)   		for i in $(echo $arg | tr "=" "\n")
						do
							if [ $i != 'services' ]
							then
				  				SERVICES=$i
							fi
						done
            			info "SERVICES $SERVICES passed via the command line" 
            			;;
    email*)   			for i in $(echo $arg | tr "=" "\n")
						do
							if [ $i != 'email' ]
							then
				  				EMAIL=$i
							fi
						done
            			info "EMAIL $EMAIL passed via the command line" 
            			;;
    config*)   			for i in $(echo $arg | tr "=" "\n")
                		do
                			if [ $i != 'config' ]
                			then
                    			FILE=$i
                			fi
                		done
            			info "Config File $FILE passed via the command line"
            			;;
    disk)   			DISK=1
            			info "DISK switched on via command line"
            			;;
    *)
            			echo "Unknown command line option passed $arg"
            			echo "Valid options are -v,cluster,connector,replicator,replicator_port=??,services=??,email=??,config=??"
            			exit 1
    esac

    
done


if [ $CLUSTER == 1 ] || [ $CONNECTOR == 1 ]
then
	if [ -z $CONTINUENT_ROOT ]
	then
		severe "$CONTINUENT_ROOT is not set - unable to continue"
	fi
	if [ ! -f $CONTINUENT_ROOT/share/env.sh ]
	then
		severe "Unable to find env.sh in $CONTINUENT_ROOT/share"
	fi

. "$CONTINUENT_ROOT/share/env.sh"
	
#Load any default settings from $CONTINUENT_ROOT/share/check_tungsten.cfg
	CFG=$CONTINUENT_ROOT/share/check_tungsten.cfg
	
	if [  -f $CFG ]
	then
	     info "Loading settings from $CFG"
	     . "$CFG"
	fi
	if [ -z "$MYSQL" ]
	then
		MYSQL=`which mysql 2>/dev/null`
	      
		if [ "$MYSQL" == "" ]
	    then
			severe " Unable to the mysql command line program"
	    fi
	fi
fi

#If a file is passed from the command line load any variables from there
if [ ! -z $FILE ]
then
    if [ ! -f $FILE ]
    then
        severe "The file specified in the command line $FILE does not exist"
    fi

    info "Loading settings from $FILE"
    . "$FILE"
fi

#Parameter and host validation

BC=`which bc 2>/dev/null`
      
if [ "$BC" == "" ]
then
   severe " Unable to find the command bc - please install"
fi
      

if [ "$EMAIL" == "" ]
then
	severe " email must be specified"
fi

if [[  "$CONNECTOR" == 0  &&  "$CLUSTER" == 0  &&  "$REPLICATOR" == 0  ]]
then
	severe " No option specified, select either connector, cluster or replicator"
fi

if [ -d $LOCK_DIR ]
then
	if [ ! -w $LOCK_DIR ]
	then
		severe " The locks dir $LOCK_DIR is not writable"
	fi
else
	info "Creating locks dir" 
	mkdir $LOCK_DIR
fi

if [ -z "$MAILPROG" ]
  then
     MAILPROG=`which mail 2>/dev/null`

  	if [ "$MAILPROG" == "" ]
      then
  		severe " Unable to find a mail program"
      fi
  fi

if [ -z "$SENDMAILBIN" ]
  then
     SENDMAILBIN=`which sendmail 2>/dev/null`

  	if [ "$SENDMAILBIN" == "" ]
      then
  		severe " Unable to find a sendmail program"
      fi
fi

if [ -f $LOG ]
then
   rm $LOG
fi

#Expire old Locks
info "Deleting Locks older than $LOCK_TIMEOUT min" 
find $LOCK_DIR/* -type f -mmin +$LOCK_TIMEOUT -delete 2> /dev/null

#Check the connector status
if [ $CONNECTOR == 1 ]
then
	connector_ok_to_allow_elb=0
	info "Running Connector Tests"
	CONN=$($CONTINUENT_ROOT/tungsten/cluster-home/bin/check_tungsten_services -c| grep -v OK | wc -l)
	if [ $CONN -ne  0 ]
	then
	   error " Connector is not running" 
	   echo "Connector is not running on $HOST - Investigate" >> $LOG
	   if [ ! -f $LOCK_DIR/con_running.lck ]
	   then
	      SENDMAIL=1
	      touch $LOCK_DIR/con_running.lck
	   else
	      info "Not sending Email lock file exists" 
	   fi
	else 
		info "Connector is running OK" 

		TIMEOUT=`which timeout 2>/dev/null`
      
		if [ "$TIMEOUT" == "" ]
	    then
			info "timeout command not found - unable to check if the connector is responding"
		else
			info "Checking Connector is responding to queries"
			CON_USER=$(getSetting connector_user)
			CON_PW=$(getSetting connector_password)
			CON_PORT=$(getSetting connector_listen_port)
			CHECK=$(timeout -s HUP $CONNECTOR_TIMEOUT $MYSQL -P$CON_PORT -u $CON_USER -p$CON_PW -h $HOSTNAME --skip-column-names  -Be"select 'ALIVE'")
			if [ "$CHECK" != 'ALIVE' ]
			then
				error 'Unable to connect to connector'
				echo "Connector is not responding on $HOST - Investigate" >> $LOG
				connector_ok=0
				if [ ! -f $LOCK_DIR/con_responding.lck ]
				   then
				    SENDMAIL=1
				    touch $LOCK_DIR/con_responding.lck
				   else
				      info "Not sending Email lock file exists" 
				fi
			else
				info 'Connector is alive'
				connector_ok_to_allow_elb=1
			fi
		fi
	fi
	
	if [ $CHECK_ELB == 1 ]
	then
		if [ -f /etc/xinetd.d/disabled/connectorchk ]  && [ $connector_ok_to_allow_elb == 1 ]
		then

				sudo mv /etc/xinetd.d/disabled/connectorchk /etc/xinetd.d/
				sudo service xinetd reload
		fi
	fi
fi

#Check the cluster Status
if [ $CLUSTER == 1 ]
then
  #Check the processes are running
  info "Running Cluster Tests"
  REPL=$($CONTINUENT_ROOT/tungsten/cluster-home/bin/check_tungsten_services -r| grep -v OK | wc -l)
  if [ $REPL -ne  0 ]
  then
    error " Replicator or Manager in cluster is not running"
      echo "Replicator or Manager in cluster is not running on $HOST - Investigate" >> $LOG
      if [ ! -f $LOCK_DIR/rep_running.lck ]
      then
         SENDMAIL=1
         touch $LOCK_DIR/rep_running.lck
      else
        info "Not sending Email lock file exists" 
      fi
     
  else
    info "Replicator and Manager in cluster are running OK" 
  fi

  #Check the processes are online
	if [ "$SERVICES" == "" ]  
	then
		  ONLINE=$($CONTINUENT_ROOT/tungsten/cluster-home/bin/check_tungsten_online | grep -v OK | wc -l)  
		  if [ $ONLINE -ne  0 ]
		  then
		    error "Services are not online" 
		      echo "Cluster Replicator processes are not online on $HOST - Investigate" >> $LOG
		      if [ ! -f $LOCK_DIR/rep_online.lck ]
		      then
		         SENDMAIL=1
		         touch $LOCK_DIR/rep_online.lck
		      else
		        info "Not sending Email lock file exists" 
		      fi
		
		  else
		    info "Services are online" 
		  fi
	else
		services=$(echo "$SERVICES" | sed 's/,/ /g')
		for s in $services
		do
			ONLINE=$($CONTINUENT_ROOT/tungsten/cluster-home/bin/check_tungsten_online -s $s | grep -v OK | wc -l)  
			if [ $ONLINE -ne  0 ]
			then
		    	error "Services are not online @ $s" 
		      echo "Cluster Replicator processes are not online on $HOST - Investigate" >> $LOG
		      if [ ! -f $LOCK_DIR/rep_online.lck ]
		      then
		         SENDMAIL=1
		         touch $LOCK_DIR/rep_online.lck
		      else
		        info "Not sending Email lock file exists" 
		      fi
		
			else
		    info "Services are online @ $s" 
			fi
		done
	fi

  #Check for replicator latency
  ONLINE=$($CONTINUENT_ROOT/tungsten/cluster-home/bin/check_tungsten_latency -w $LAG -c $LAG | grep -v OK | wc -l)  
  if [ $ONLINE -ne  0 ]
  then
    error "Services are Lagging" 
      echo "Cluster Replicator processes are lagging on $HOST - Investigate" >> $LOG
      if [ ! -f $LOCK_DIR/rep_lag.lck ]
      then
         SENDMAIL=1
         touch $LOCK_DIR/rep_lag.lck
      else
        info "Not sending Email lock file exists" 
      fi

  else
    info "Cluster Replicator is keeping up" 
  fi
fi

#Check the Replicator 
if [ $REPLICATOR == 1 ]
then
	if [ ! -f $REPLICATOR_HOME/tungsten/tungsten-replicator/bin/trepctl ]
	then
		severe "trepctl not found in $REPLICATOR_HOME/tungsten/tungsten-replicator/bin/ "
	fi
	
	AVAILABLE=$($REPLICATOR_HOME/tungsten/tungsten-replicator/bin/trepctl -port $REPLICATOR_PORT services | grep "Connection failed" | wc -l)
	if [ $AVAILABLE -gt 0 ]
	then
		error "Replicator process is not running on $REPLICATOR_PORT"
		echo "Replicator processes is not running  on $HOST:$REPLICATOR_PORT - Investigate" >> $LOG
		    if [ ! -f $LOCK_DIR/tr_rep_running.lck ]
		      then
		         SENDMAIL=1
		        touch $LOCK_DIR/tr_rep_running.lck
		      else
		        info "Not sending Email lock file exists" 
		      fi
		
	 else
		    info "TR Replicator is running" 
	  fi


	ONLINE=$($REPLICATOR_HOME/tungsten/tungsten-replicator/bin/trepctl -port $REPLICATOR_PORT services| grep state | grep -v ONLINE | wc -l)
	if [ $ONLINE -gt 0 ]
	then
		error "Replicator is down" 
	    echo "Replicator processes is not ONLINE  on $HOST - Investigate" >> $LOG
	      if [ ! -f $LOCK_DIR/tr_rep_online.lck ]
	      then
	         SENDMAIL=1
	         touch $LOCK_DIR/tr_rep_online.lck
	      else
	        info "Not sending Email lock file exists" 
	      fi
	
	  else
	    info "TR Replicator is online" 
	  fi
	
	#Check for latency
	LATENCY_LIST=$($REPLICATOR_HOME/tungsten/tungsten-replicator/bin/trepctl -port $REPLICATOR_PORT services|grep appliedLatency|cut -d ':' -f2)
    
    for LATENCY in $LATENCY_LIST
    do
	    if float_cond "$LATENCY > $LAG"; then
	    error "Replicator is lagging" 
		    echo "Replicator processes is behind  on $HOST - Investigate" >> $LOG
		    if [ ! -f $LOCK_DIR/tr_rep_lag.lck ]
		    then
		        SENDMAIL=1
		        touch $LOCK_DIR/tr_rep_lag.lck
		    else
		        info "Not sending Email lock file exists" 
		    fi
		else
			    info "Replicator latency ok"    
	    fi
	done

 
fi

#Check the disk space
if [ $DISK == 1 ]
then
	
	df -HP | grep -vE '^Filesystem|tmpfs|cdrom' | awk '{ print $5 " " $1 }' | while read output;
	do
	usep=$(echo $output | awk '{ print $1}' | cut -d'%' -f1  )
	partition=$(echo $output | awk '{ print $2 }' )
	if [ $usep -ge $DISK_WARNING ]; then
		error "Running out of disk space on $partition"
	    echo "Running out for disk space on $HOST $partition - Investigate" >> $LOG
	    if [ ! -f $LOCK_DIR/disk.lck ]
	    then
	        SENDMAIL=1
	        touch $LOCK_DIR/disk.lck
	    else
	        info "Not sending Email lock file exists" 
	    fi
	  fi
 done
	
fi
		  
if [ $SENDMAIL == 1 ]
then
    if [ $DEBUG == 1 ]
    then 
        info "Sending Email to $EMAIL"
        info "Subject $SUBJECT"
        cat $LOG
    fi

	if [ $CLUSTER == 1 ] || [ $CONNECTOR == 1 ]
	then
		manager_running=$($CONTINUENT_ROOT/tungsten/tungsten-manager/bin/manager status | grep "PID" | wc -l) 
  		if [ $manager_running -eq 1 ]; then
			info "Adding cctrl output to email" 
			echo >> $LOG
			echo "OUTPUT FROM cctrl ls on $HOST" >> $LOG
			echo '--------------------------------------------------' >> $LOG
			echo 'ls' | $CONTINUENT_ROOT/tungsten/tungsten-manager/bin/cctrl -expert >> $LOG
			echo '--------------------------------------------------' >> $LOG
		else
			info 'Manager not running skipping cctrl output'
			echo "Manager not running unable to gather cctrl output" >> $LOG
		fi
		
	fi
	if [ $REPLICATOR == 1 ] 
	then
		if [ -f $REPLICATOR_HOME/tungsten/tungsten-replicator/bin/trepctl ]
		then
				info "Adding trepctl output to email" 
				echo "OUTPUT FROM trepctl -port $REPLICATOR_PORT status on $HOST" >> $LOG
				echo '--------------------------------------------------' >> $LOG

                       
				$REPLICATOR_HOME/tungsten/tungsten-replicator/bin/trepctl -port $REPLICATOR_PORT services >> $LOG
				echo '--------------------------------------------------' >> $LOG
		else
				info 'trepctl not found'
				echo "trepctl not found at $REPLICATOR_HOME/tungsten/tungsten-replicator/bin/trepctl unable to query for output" >> $LOG
		fi
	fi
    $MAILPROG -s "$SUBJECT" "$EMAIL" < $LOG
fi


