--Use this to identify users to disable.
use role securityadmin;
use warehouse wh_xs;
show users;
set v_lqid=(select last_query_id());
select current_account() "SF Account","name",to_date("last_success_login"),"email","owner"
from table(result_Scan($v_lqid))
where  "last_success_login" < dateadd('month',-6,current_date)
and "disabled"=false
and contains("name",'_')=false;

For each user on the list that is NOT an application/automation account:

alter user <USERNAME> set disabled = true;



--Use this to identify disabled users to delete.
show users;
set v_lqid=(select last_query_id());
select current_account() "SF Account","name",to_date("last_success_login"),"email","owner"
from table(result_Scan($v_lqid))
where "last_success_login" < dateadd('month',-9,current_date)
and "disabled"=true
and contains("name",'_')=false;

For each user on the list that is NOT an application/automation account:

drop user <USERNAME>;
