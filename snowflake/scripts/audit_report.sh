#!/bin/bash

. $HOME/.bash_profile
. $HOME/.bashrc


#### Set Directory and Script Name

DIR=${0}
if [[ "$DIR" = /* ]]
then
  echo "absolute"
  export APP_DIR=$(dirname $(dirname ${0}))
else
  echo "relative"
  export APP_DIR=$(dirname $(pwd))
fi


script_name=$(basename $0 .sh)

#### Set up app environment. Create a file for this.

source $APP_DIR/bin/${script_name}.env


#### Set Timestamp

export RUN_TIMESTAMP=$(date '+%Y%m%d_%H%M%S')


#### Log and trigger

export LOG_FILE=$LOG_DIR/${script_name}_${RUN_TIMESTAMP}.log

export LCK_FILE=$LCK_DIR/${script_name}.lck

#### Start logging

exec 1>$LOG_FILE
exec 2>&1

#
#  Print input parameter values
#
echo
echo "##########################################"
echo "Print env variables"
echo "##########################################"
echo
echo "ENV = $ENV"
echo "RUN_TIMESTAMP = $RUN_TIMESTAMP"
echo "ACCOUNT = $ACCOUNT"
echo "REGION = $REGION"
echo "DATABASE = $DATABASE"
echo "USER = $USER"
echo "ROLE = $ROLE"
echo "APPLICATION = $APPLICATION"
echo "SOURCE_DATASET = $SOURCE_DATASET"
echo "OWNER_SCHEMA = $OWNER_SCHEMA"
echo "WORK_SCHEMA = $WORK_SCHEMA"
echo "DOD_SCHEMA = $DOD_SCHEMA"


echo
echo "##########################################"
echo "shell env variables"
echo "##########################################"
env|sort
echo "##########################################"
echo

echo
echo "################################################################################"
echo
echo "Check if already running."
echo
echo "################################################################################"
echo

exec 9>$LCK_FILE
flock -xn 9
return_cd=$?

if [[ $return_cd != 0 ]]
then
    echo "Already Executing - $0 - EXITING"
    exec 1<&-
    exec 2<&-
    exec 9<&-
    exit 1
fi

echo
echo "################################################################################"
echo
echo "Running $0 as process_id $$ - `date`"
echo
echo "################################################################################"
echo

export FUNC_LIB=/common/db_scripts/func_lib
source ${FUNC_LIB}/functions.lib > /dev/null
source ${IBSEC}/functions2.lib
export SNOWSQL_PWD=$(${IBSEC}/get_password.ksh ${ACCOUNT} ${USER})

echo
echo "################################################################################"
echo
echo "STARTED: Check that License is loaded."
echo
echo "################################################################################"
echo

next_release_id=$(snowsql --accountname ${ACCOUNT} --region ${REGION} --dbname ${DATABASE} --username ${USER} --schemaname ${DOD_SCHEMA} --rolename ${ROLE} --warehouse WH_XS --abort-detached-query --query "select next_release_id from ${DATABASE}.${DOD_SCHEMA}.release where dataset = 'LICENSE' and current_date() between start_Date and end_date;" --option header=False --option output_format=plain --option timing=False --option friendly=False)

release_id=$(snowsql --accountname ${ACCOUNT} --region ${REGION} --dbname ${DATABASE} --username ${USER} --schemaname ${WORK_SCHEMA} --rolename ${ROLE} --warehouse WH_XS --abort-detached-query --query "select distinct release_id from ${DATABASE}.${WORK_SCHEMA}.dataset where release_id = $next_release_id;" --option header=False --option output_format=plain --option timing=False --option friendly=False)

	if [[ $release_id = "" ]]
	then
        echo "License to DOD is required before AUDIT_REPORT can be run."
    exec 1<&-
    exec 2<&-
    exec 9<&-
    exit 1
fi   

echo
echo "################################################################################"
echo
echo "Finished: Check that License is loaded."
echo
echo "################################################################################"
echo     

echo
echo "################################################################################"
echo
echo "STARTED: Get CUSTOMER_NAMEs"
echo
echo "################################################################################"
echo

customers=$(snowsql --accountname ${ACCOUNT} --region ${REGION} --dbname ${DATABASE} --username ${USER} --schemaname ${DOD_SCHEMA} --rolename ${ROLE} --warehouse WH_XS --abort-detached-query --query "select customer_name from ${DATABASE}.${DOD_SCHEMA}.AUDIT_CONFIG;" --option header=False --option output_format=plain --option timing=False --option friendly=False)

echo "customers=$customers"

echo
echo "################################################################################"
echo
echo "STARTED: Run totals procedure for each customer"
echo
echo "################################################################################"
echo

for name in $customers;
do

	echo name=$name
	snowsql --accountname ${ACCOUNT} --region ${REGION} --dbname ${DATABASE} --username ${USER} --schemaname ${WORK_SCHEMA} --rolename ${ROLE} --warehouse WH_XS --abort-detached-query --query "call ${DATABASE}.${WORK_SCHEMA}.next_audit_totals('$name');" --option header=False --option output_format=plain --option timing=False --option friendly=False

done

echo
echo "################################################################################"
echo
echo "FINISHED: Run totals for each customer"
echo
echo "################################################################################"
echo

echo
echo "################################################################################"
echo
echo "STARTED: Find records to delete"
echo
echo "################################################################################"
echo

prior_release_id=$(snowsql --accountname ${ACCOUNT} --region ${REGION} --dbname ${DATABASE} --username ${USER} --schemaname ${DOD_SCHEMA} --rolename ${ROLE} --warehouse WH_XS --abort-detached-query --query "select prior_release_id from ${DATABASE}.${DOD_SCHEMA}.release where dataset = 'AUDIT_REPORT' and current_date() between start_Date and end_date;" --option header=False --option output_format=plain --option timing=False --option friendly=False)

echo "prior_release_id=$prior_release_id"


echo
echo "################################################################################"
echo
echo "STARTED: Delete expired records"
echo
echo "################################################################################"
echo

snowsql --accountname ${ACCOUNT} --region ${REGION} --dbname ${DATABASE} --username ${USER} --schemaname ${WORK_SCHEMA} --rolename ${ROLE} --warehouse WH_XS --abort-detached-query --query "delete from ${DATABASE}.${WORK_SCHEMA}.AUDIT_REPORT where release_id < $prior_release_id;" --option header=False --option output_format=plain --option timing=False --option friendly=False

echo
echo "################################################################################"
echo
echo "FINISHED: Delete expired records"
echo
echo "################################################################################"
echo

echo
echo "################################################################################"
echo
echo "STARTED: Generate Final Report and Email - `date`"
echo
echo "################################################################################"
echo


report_role="DOD_SDMP_PROD_OWNER_ROLE"

echo "report_role = $report_role"


echo "v_mart_count = $v_mart_count"


#email_dist="mary.vasek@choreograph.com; stephanie.goracke@choreograph.com; susan.enriquez@choreograph.com; kirk.koby@choreograph.com; dawn.najera@choreograph.com; donovan.mouriz@choreograph.com; CHODENoradbas@choreograph.com"

email_dist="chantal.spurgeon@choreograph.com"

echo "email_dist = $email_dist"

email_replyto="chantal.spurgeon@choreograph.com"

echo "email_replyto = $email_replyto"

email_subj="Verification Needed Audit Report $release_id"

email_body="The Audit Report for Release ID $release_id data has been loaded into the following:

Snowflake Account  : wdp
Snowflake Region   : us-east-1
Snowflake Domain   : snowflakecomputing
Snowflake extension: com

Database: $DATABASE
Schema  : $OWNER_SCHEMA
Tables  : ${DATABASE}.${WORK_SCHEMA}.AUDIT_REPORT - has $v_mart_count records.

Customers: ${customers}


Please use the following context to verify the report:
    use role GLOBAL_SELECT_${ENV}_ROLE;
    use database $DATABASE;
    use schema $WORK_SCHEMA;
    use warehouse wh_xs;

At this time the data needs to be verified by the Dallas Amerilink Staff.
Data HAS NOT been moved to the DataOnDemand Database.
Please let me know when the data may be moved to DataOnDemand Database."



echo "$email_body" | mailx -s "$email_subj" -S replyto="$email_replyto" $email_dist


echo
echo "################################################################################"
echo
echo "FINISHED: Generate Final Report and Email - `date`"
echo
echo "################################################################################"
echo


echo
echo "################################################################################"
echo
echo "Finished $0 in process_id $$ - `date`"
echo
echo "################################################################################"
echo

exec 1<&-
exec 2<&-
exec 9<&-

exit
